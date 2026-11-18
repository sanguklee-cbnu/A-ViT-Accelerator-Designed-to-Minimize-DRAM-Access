from __future__ import annotations

import argparse
import datetime as dt
import json
import math
from dataclasses import asdict
from pathlib import Path
from typing import Any

from .data import create_dataset, create_loader
from .determinism import set_deterministic
from .evaluate import add_common_eval_args, add_k_args, k_config_from_args, resolve_device
from .k_assignment.base import KAssignmentConfig, LinearSite, discover_linear_sites
from .k_assignment.simulation import column_count, k_tile_count, k_tile_size
from .models import format_model_inspection, load_deit_tiny

try:
    import torch as _torch

    _TorchModule = _torch.nn.Module
except ImportError:
    _TorchModule = object


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Build ImageNet calibration-based k assignments.")
    add_common_eval_args(parser)
    add_k_args(parser, include_mode=False)
    parser.add_argument("--output-path", required=True, help="Path to write calibrated k JSON.")
    parser.add_argument("--heuristic-nmse", type=float, default=1e-4)
    parser.add_argument("--optimized-nmse", type=float, default=1e-5)
    parser.add_argument("--min-k", type=int, default=0)
    parser.add_argument("--max-k", type=int, default=12)
    return parser


class RunningStat:
    def __init__(self) -> None:
        self.sumsq = 0.0
        self.count = 0
        self.max_abs = 0.0

    def update(self, tensor: Any) -> None:
        import torch

        t = tensor.detach().float()
        self.sumsq += float(torch.sum(t * t).item())
        self.count += int(t.numel())
        if t.numel():
            self.max_abs = max(self.max_abs, float(torch.max(torch.abs(t)).item()))

    @property
    def rms(self) -> float:
        if self.count <= 0:
            return 0.0
        return math.sqrt(self.sumsq / self.count)

    def to_dict(self) -> dict[str, Any]:
        return {"sumsq": self.sumsq, "count": self.count, "rms": self.rms, "max_abs": self.max_abs}


class SiteCalibrationStats:
    def __init__(self, site: LinearSite, config: KAssignmentConfig) -> None:
        self.site = site
        self.k_tile_size = k_tile_size(site, config)
        self.tile_count = k_tile_count(site, config)
        self.column_count = column_count(site, config)
        self.tile_stats = [RunningStat() for _ in range(self.tile_count)]
        self.column_stats = [RunningStat() for _ in range(self.column_count)]
        self.site_stat = RunningStat()

    def update_tile(self, tile_index: int, tensor: Any) -> None:
        self.tile_stats[tile_index].update(tensor)
        self.site_stat.update(tensor)

    def update_columns(self, tile_index: int, tensor: Any) -> None:
        import torch

        del tile_index
        t = tensor.detach().float()
        if t.numel() == 0:
            return
        sumsq = torch.sum(t * t, dim=0).cpu().tolist()
        max_abs = torch.max(torch.abs(t), dim=0).values.cpu().tolist()
        count = int(t.shape[0])
        for out_col, stat in enumerate(self.column_stats):
            stat.sumsq += float(sumsq[out_col])
            stat.count += count
            stat.max_abs = max(stat.max_abs, float(max_abs[out_col]))


class CalibrationCollector:
    def __init__(self, model: Any, config: KAssignmentConfig) -> None:
        self.model = model
        self.config = config
        self.sites = discover_linear_sites(
            model,
            include_regex=config.include_regex,
            exclude_regex=config.exclude_regex,
        )
        if not self.sites:
            raise ValueError("No target layers found for calibration.")
        self.stats = {site.name: SiteCalibrationStats(site, config) for site in self.sites}
        self.global_stat = RunningStat()
        self.layer_stats: dict[str, RunningStat] = {}

    def attach(self) -> None:
        import torch

        for site in self.sites:
            parent, attr_name, module = _resolve_parent(self.model, site.name)
            if site.kind == "patch_embed_conv2d":
                if not isinstance(module, torch.nn.Conv2d):
                    raise ValueError(f"Expected Conv2d at {site.name}, found {type(module)!r}")
                wrapped = CalibrationPatchEmbedConv2d(module, site, self)
            else:
                if not isinstance(module, torch.nn.Linear):
                    raise ValueError(f"Expected Linear at {site.name}, found {type(module)!r}")
                wrapped = CalibrationLinear(module, site, self)
            setattr(parent, attr_name, wrapped)

    def collect_linear(self, site: LinearSite, x_2d: Any, weight_2d: Any) -> None:
        import torch

        x_f = x_2d.detach().float()
        w_f = weight_2d.detach().float()
        stats = self.stats[site.name]
        layer_key = _layer_key(site)
        layer_stat = self.layer_stats.setdefault(layer_key, RunningStat())

        for tile_index in range(stats.tile_count):
            i0 = tile_index * stats.k_tile_size
            i1 = min(site.in_features, i0 + stats.k_tile_size)
            tile_partial = x_f[:, i0:i1] @ w_f[:, i0:i1].t()
            stats.update_tile(tile_index, tile_partial)
            stats.update_columns(tile_index, tile_partial)
            self.global_stat.update(tile_partial)
            layer_stat.update(tile_partial)

    def to_k_json(
        self,
        *,
        args: argparse.Namespace,
        model_info: dict[str, Any],
        dataset_info: dict[str, Any],
    ) -> dict[str, Any]:
        global_k = _k_from_stat(
            self.global_stat,
            nmse=args.heuristic_nmse,
            min_k=args.min_k,
            max_k=args.max_k,
        )
        layer_k = {
            key: _k_from_stat(stat, nmse=args.heuristic_nmse, min_k=args.min_k, max_k=args.max_k)
            for key, stat in sorted(self.layer_stats.items())
        }
        sites: dict[str, Any] = {}
        for site in self.sites:
            site_stats = self.stats[site.name]
            heuristic_tile_k = [
                _k_from_stat(stat, nmse=args.heuristic_nmse, min_k=args.min_k, max_k=args.max_k)
                for stat in site_stats.tile_stats
            ]
            optimized_tile_k = [
                _k_from_stat(stat, nmse=args.optimized_nmse, min_k=args.min_k, max_k=args.max_k)
                for stat in site_stats.tile_stats
            ]
            column_k = [
                _k_from_stat(stat, nmse=args.optimized_nmse, min_k=args.min_k, max_k=args.max_k)
                for stat in site_stats.column_stats
            ]
            sites[site.name] = {
                "kind": site.kind,
                "layer_index": site.layer_index,
                "layer_key": _layer_key(site),
                "in_features": site.in_features,
                "out_features": site.out_features,
                "tile_definition": "K/input-channel dimension partition only",
                "k_dimension": site.in_features,
                "k_tile_size": site_stats.k_tile_size,
                "k_tile_count": site_stats.tile_count,
                "columnwise_definition": "per logical weight/output column for the full logical weight block",
                "column_count": site_stats.column_count,
                "columnwise_k_count": site_stats.column_count,
                "heuristic_tile_k": heuristic_tile_k,
                "tile_k": optimized_tile_k,
                "column_k": column_k,
                "stats": {
                    "site": site_stats.site_stat.to_dict(),
                    "tile_rms": [stat.rms for stat in site_stats.tile_stats],
                    "column_rms": [stat.rms for stat in site_stats.column_stats],
                },
            }
        return {
            "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "calibration_type": "imagenet_partial_sum_rms_nmse",
            "model": model_info,
            "dataset": dataset_info,
            "config": {
                "heuristic_nmse": args.heuristic_nmse,
                "optimized_nmse": args.optimized_nmse,
                "min_k": args.min_k,
                "max_k": args.max_k,
                "tile_definition": "K/input-channel dimension partition only",
                "columnwise_definition": "per logical weight/output column for the full logical weight block",
                "patch_k_tile_size": self.config.patch_k_tile_size,
                "fc2_k_tile_size": self.config.fc2_k_tile_size,
                "max_samples": args.max_samples,
                "batch_size": args.batch_size,
                "seed": args.seed,
            },
            "global_k": global_k,
            "layer_k": layer_k,
            "sites": sites,
            "note": (
                "This file is calibrated from ImageNet partial-sum RMS statistics. "
                "It is not produced by end-to-end learned accuracy optimization."
            ),
        }


class CalibrationLinear(_TorchModule):
    def __init__(self, base: Any, site: LinearSite, collector: CalibrationCollector) -> None:
        import torch

        super().__init__()
        self.base = base
        self.site = site
        self.collector = collector
        self.in_features = base.in_features
        self.out_features = base.out_features
        self.weight = base.weight
        self.bias = base.bias

    def __call__(self, x: Any) -> Any:
        return self.forward(x)

    def forward(self, x: Any) -> Any:
        out = self.base(x)
        self.collector.collect_linear(self.site, x.reshape(-1, self.in_features), self.weight)
        return out


class CalibrationPatchEmbedConv2d(_TorchModule):
    def __init__(self, base: Any, site: LinearSite, collector: CalibrationCollector) -> None:
        import torch

        super().__init__()
        self.base = base
        self.site = site
        self.collector = collector
        self.in_channels = base.in_channels
        self.out_channels = base.out_channels
        self.kernel_size = base.kernel_size
        self.stride = base.stride
        self.padding = base.padding
        self.dilation = base.dilation
        self.groups = base.groups
        self.weight = base.weight
        self.bias = base.bias

    def __call__(self, x: Any) -> Any:
        return self.forward(x)

    def forward(self, x: Any) -> Any:
        import torch.nn.functional as F

        out = self.base(x)
        patches = F.unfold(
            x,
            kernel_size=self.kernel_size,
            dilation=self.dilation,
            padding=self.padding,
            stride=self.stride,
        )
        batch, _, patch_count = patches.shape
        x_2d = patches.transpose(1, 2).reshape(batch * patch_count, self.site.in_features)
        weight_2d = self.weight.reshape(self.out_channels, -1)
        self.collector.collect_linear(self.site, x_2d, weight_2d)
        return out


def _k_from_stat(stat: RunningStat, *, nmse: float, min_k: int, max_k: int) -> int:
    if stat.count <= 0 or stat.rms <= 0:
        return max_k
    step = math.sqrt(max(1e-30, 12.0 * nmse * stat.rms * stat.rms))
    k = int(math.ceil(-math.log2(step)))
    return max(min_k, min(max_k, k))


def _layer_key(site: LinearSite) -> str:
    return "patch_embed" if site.layer_index == -1 else str(site.layer_index)


def _resolve_parent(model: Any, name: str) -> tuple[Any, str, Any]:
    parts = name.split(".")
    parent = model
    for part in parts[:-1]:
        parent = getattr(parent, part)
    attr_name = parts[-1]
    return parent, attr_name, getattr(parent, attr_name)


def main(argv: list[str] | None = None) -> None:
    import torch
    from tqdm.auto import tqdm

    args = build_parser().parse_args(argv)
    set_deterministic(args.seed)
    device = resolve_device(args.device)
    k_config = k_config_from_args(args, mode="learned_or_optimized_tilewise_k")

    bundle = load_deit_tiny(backend=args.model_backend, pretrained=True, device=device)
    print(format_model_inspection(bundle.inspection))
    dataset, dataset_info = create_dataset(
        dataset_path=args.dataset_path,
        transform=bundle.preprocess,
        synthetic_samples=args.synthetic_samples,
        max_samples=args.max_samples,
        require_1000_classes=not args.allow_non_imagenet_class_count,
    )
    loader = create_loader(dataset, batch_size=args.batch_size, num_workers=args.num_workers, device=device)

    collector = CalibrationCollector(bundle.model, k_config)
    collector.attach()
    bundle.model.eval()
    with torch.no_grad():
        for images, _target in tqdm(loader, desc="calibrate", leave=False):
            images = images.to(device, non_blocking=True)
            bundle.model(images)

    output = collector.to_k_json(
        args=args,
        model_info=asdict(bundle.inspection),
        dataset_info=asdict(dataset_info),
    )
    path = Path(args.output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(f"calibrated k json: {path.resolve()}")


if __name__ == "__main__":
    main()
