from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .base import KAssignmentConfig, LinearSite, discover_linear_sites
from ..constants import (
    MODE_FIXED_GLOBAL,
    MODE_FIXED_LAYERWISE,
    MODE_HEURISTIC_TILEWISE,
    MODE_LEARNED_TILEWISE,
    MODE_LEARNED_TILEWISE_COLUMNWISE,
    MODE_LEARNED_TILEWISE_PRE_ADJUSTED,
)

try:
    import torch as _torch

    _TorchModule = _torch.nn.Module
except ImportError:
    _TorchModule = object


@dataclass(frozen=True)
class SitePlan:
    name: str
    kind: str
    layer_index: int
    in_features: int
    out_features: int
    k_tile_size: int
    k_tile_count: int
    column_count: int
    mode: str
    runtime_k_count: int
    global_k: int | None = None
    layer_k: int | None = None
    tile_k: list[int] | None = None
    column_k: list[int] | None = None
    pre_adjusted_column_k: list[int] | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "kind": self.kind,
            "layer_index": self.layer_index,
            "in_features": self.in_features,
            "out_features": self.out_features,
            "k_dimension_tile_size": self.k_tile_size,
            "k_dimension_tile_count": self.k_tile_count,
            "columnwise_definition": "per logical weight/output column for the full logical weight block",
            "column_count": self.column_count,
            "mode": self.mode,
            "runtime_k_count": self.runtime_k_count,
            "global_k": self.global_k,
            "layer_k": self.layer_k,
            "tile_k": self.tile_k,
            "column_k": self.column_k,
            "pre_adjusted_column_k": self.pre_adjusted_column_k,
        }


@dataclass(frozen=True)
class QuantizationPlan:
    mode: str
    sites: list[SitePlan]
    approximation: str

    @property
    def runtime_k_count(self) -> int:
        return sum(site.runtime_k_count for site in self.sites)

    @property
    def target_layer_count(self) -> int:
        return len({site.layer_index for site in self.sites})

    def per_layer_runtime_k_count(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for site in self.sites:
            key = "patch_embed" if site.layer_index == -1 else str(site.layer_index)
            counts[key] = counts.get(key, 0) + site.runtime_k_count
        return counts

    def to_effective_config(self) -> dict[str, Any]:
        return {
            "mode": self.mode,
            "runtime_k_count": self.runtime_k_count,
            "target_layers": ["patch_embed", "blocks.*.mlp.fc2"],
            "partial_sum_simulation": (
                "Each K-dimension input-channel tile produces a local partial "
                "sum. Tile-wise k rounds that tile partial sum to a 2^-k grid; "
                "column-wise k uses one k per logical weight/output column."
            ),
            "approximation": self.approximation,
            "sites": {site.name: site.to_dict() for site in self.sites},
        }


def k_tile_size(site: LinearSite, config: KAssignmentConfig) -> int:
    size = config.patch_k_tile_size if site.kind == "patch_embed_conv2d" else config.fc2_k_tile_size
    if size <= 0:
        raise ValueError("K-dimension tile size must be positive.")
    return int(size)


def k_tile_count(site: LinearSite, config: KAssignmentConfig) -> int:
    return int(math.ceil(site.in_features / k_tile_size(site, config)))


def column_count(site: LinearSite, config: KAssignmentConfig) -> int:
    del config
    return int(site.out_features)


def columnwise_count(site: LinearSite, config: KAssignmentConfig) -> int:
    return column_count(site, config)


def _weight_2d_for_site(model: Any, site: LinearSite) -> Any:
    module = _get_submodule(model, site.name)
    try:
        import torch
    except ImportError as exc:
        raise RuntimeError("PyTorch is required for k-aware inference simulation.") from exc

    if site.kind == "patch_embed_conv2d":
        if not isinstance(module, torch.nn.Conv2d):
            raise ValueError(f"Expected Conv2d at {site.name}, found {type(module)!r}.")
        return module.weight.detach().reshape(module.out_channels, -1)

    if not isinstance(module, torch.nn.Linear):
        raise ValueError(f"Expected Linear at {site.name}, found {type(module)!r}.")
    return module.weight.detach()


def _estimate_k_from_tensor(tensor: Any, *, low: int = 0, high: int = 12) -> int:
    try:
        import torch
    except ImportError as exc:
        raise RuntimeError("PyTorch is required for heuristic k estimation.") from exc

    if tensor.numel() == 0:
        return low
    max_abs = float(torch.max(torch.abs(tensor)).item())
    if max_abs <= 0:
        return high
    estimated = int(round(4.0 - math.log2(max_abs)))
    return max(low, min(high, estimated))


def _tile_k_from_weight(weight: Any, site: LinearSite, config: KAssignmentConfig) -> list[int]:
    tiles = k_tile_count(site, config)
    tile_size = k_tile_size(site, config)
    values: list[int] = []
    for tile_index in range(tiles):
        i0 = tile_index * tile_size
        i1 = min(site.in_features, i0 + tile_size)
        values.append(_estimate_k_from_tensor(weight[:, i0:i1]))
    return values


def _column_k_from_weight(weight: Any, site: LinearSite, config: KAssignmentConfig) -> list[int]:
    del config
    values: list[int] = []
    for out_col in range(site.out_features):
        values.append(_estimate_k_from_tensor(weight[out_col, :]))
    return values


def _layer_k_by_weight(model: Any, sites: list[LinearSite]) -> dict[int, int]:
    by_layer: dict[int, list[Any]] = {}
    for site in sites:
        by_layer.setdefault(site.layer_index, []).append(_weight_2d_for_site(model, site))

    result: dict[int, int] = {}
    try:
        import torch
    except ImportError as exc:
        raise RuntimeError("PyTorch is required for heuristic k estimation.") from exc
    for layer_index, weights in by_layer.items():
        result[layer_index] = _estimate_k_from_tensor(torch.cat([w.reshape(-1) for w in weights]))
    return result


def _load_k_config(path: str | None, *, required: bool) -> dict[str, Any] | None:
    if path is None:
        if not required:
            return None
        raise ValueError(
            "learned_or_optimized k schemes require --learned-k-path. "
            "Provide a JSON file with per-site tile_k and, when needed, column_k values."
        )
    config_path = Path(path)
    if not config_path.exists():
        raise FileNotFoundError(f"learned k file does not exist: {config_path}")
    return json.loads(config_path.read_text(encoding="utf-8"))


def _site_learned_entry(learned: dict[str, Any], site: LinearSite) -> dict[str, Any]:
    sites = learned.get("sites", learned)
    if site.name not in sites:
        raise ValueError(f"learned k file is missing site {site.name!r}")
    entry = sites[site.name]
    if not isinstance(entry, dict):
        raise ValueError(f"learned k entry for {site.name!r} must be an object")
    return entry


def _layer_key(site: LinearSite) -> str:
    return "patch_embed" if site.layer_index == -1 else str(site.layer_index)


def _learned_layer_k(learned: dict[str, Any], site: LinearSite) -> int:
    layer_map = learned.get("layer_k")
    if not isinstance(layer_map, dict):
        raise ValueError("calibrated k file is missing layer_k for fixed_layerwise_k")
    key = _layer_key(site)
    if key not in layer_map:
        raise ValueError(f"calibrated k file is missing layer_k for {key!r}")
    return int(layer_map[key])


def _validate_tile_k(tile_k: Any, site: LinearSite, config: KAssignmentConfig) -> list[int]:
    tiles = k_tile_count(site, config)
    if not isinstance(tile_k, list) or len(tile_k) != tiles:
        raise ValueError(
            f"tile_k for {site.name!r} must contain {tiles} K-dimension tile values "
            f"(K={site.in_features}, tile_size={k_tile_size(site, config)})."
        )
    if any(isinstance(value, list) for value in tile_k):
        raise ValueError(
            f"tile_k for {site.name!r} must be a 1D K-dimension list, not an output-by-input tile grid."
        )
    return [int(value) for value in tile_k]


def _validate_column_k(column_k: Any, site: LinearSite, config: KAssignmentConfig) -> list[int]:
    cols = column_count(site, config)
    if not isinstance(column_k, list) or len(column_k) != cols:
        raise ValueError(
            f"column_k for {site.name!r} must contain {cols} logical weight/output-column values."
        )
    if any(isinstance(value, list) for value in column_k):
        raise ValueError(
            f"column_k for {site.name!r} must be a 1D output-column list, not a K-tile-by-column grid."
        )
    return [int(value) for value in column_k]


def build_quantization_plan(model: Any, config: KAssignmentConfig) -> QuantizationPlan:
    sites = discover_linear_sites(
        model,
        include_regex=config.include_regex,
        exclude_regex=config.exclude_regex,
    )
    if not sites:
        raise ValueError("No target layers were found for k-aware simulation.")

    mode = config.mode
    learned_required = mode in {
        MODE_LEARNED_TILEWISE,
        MODE_LEARNED_TILEWISE_COLUMNWISE,
        MODE_LEARNED_TILEWISE_PRE_ADJUSTED,
    }
    learned = _load_k_config(config.learned_k_path, required=learned_required)

    layer_k = (
        {}
        if (mode != MODE_FIXED_LAYERWISE or learned is not None)
        else _layer_k_by_weight(model, sites)
    )
    site_plans: list[SitePlan] = []
    for site in sites:
        weight = _weight_2d_for_site(model, site)
        tile_size = k_tile_size(site, config)
        tile_count = k_tile_count(site, config)
        columns = column_count(site, config)

        if mode == MODE_FIXED_GLOBAL:
            global_k = int(learned["global_k"]) if learned and "global_k" in learned else config.global_k
            site_plans.append(
                SitePlan(
                    name=site.name,
                    kind=site.kind,
                    layer_index=site.layer_index,
                    in_features=site.in_features,
                    out_features=site.out_features,
                    k_tile_size=tile_size,
                    k_tile_count=tile_count,
                    column_count=columns,
                    mode=mode,
                    runtime_k_count=1 if site == sites[0] else 0,
                    global_k=global_k,
                )
            )
            continue

        if mode == MODE_FIXED_LAYERWISE:
            site_layer_k = _learned_layer_k(learned, site) if learned is not None else layer_k[site.layer_index]
            site_plans.append(
                SitePlan(
                    name=site.name,
                    kind=site.kind,
                    layer_index=site.layer_index,
                    in_features=site.in_features,
                    out_features=site.out_features,
                    k_tile_size=tile_size,
                    k_tile_count=tile_count,
                    column_count=columns,
                    mode=mode,
                    runtime_k_count=1,
                    layer_k=site_layer_k,
                )
            )
            continue

        if mode == MODE_HEURISTIC_TILEWISE:
            if learned is not None:
                entry = _site_learned_entry(learned, site)
                tile_k = _validate_tile_k(entry.get("heuristic_tile_k", entry.get("tile_k")), site, config)
            else:
                tile_k = _tile_k_from_weight(weight, site, config)
            site_plans.append(
                SitePlan(
                    name=site.name,
                    kind=site.kind,
                    layer_index=site.layer_index,
                    in_features=site.in_features,
                    out_features=site.out_features,
                    k_tile_size=tile_size,
                    k_tile_count=tile_count,
                    column_count=columns,
                    mode=mode,
                    runtime_k_count=tile_count,
                    tile_k=tile_k,
                )
            )
            continue

        assert learned is not None
        entry = _site_learned_entry(learned, site)
        tile_k = _validate_tile_k(entry.get("tile_k"), site, config)

        if mode == MODE_LEARNED_TILEWISE:
            site_plans.append(
                SitePlan(
                    name=site.name,
                    kind=site.kind,
                    layer_index=site.layer_index,
                    in_features=site.in_features,
                    out_features=site.out_features,
                    k_tile_size=tile_size,
                    k_tile_count=tile_count,
                    column_count=columns,
                    mode=mode,
                    runtime_k_count=tile_count,
                    tile_k=tile_k,
                )
            )
            continue

        column_k = _validate_column_k(entry.get("column_k"), site, config)
        if mode == MODE_LEARNED_TILEWISE_COLUMNWISE:
            site_plans.append(
                SitePlan(
                    name=site.name,
                    kind=site.kind,
                    layer_index=site.layer_index,
                    in_features=site.in_features,
                    out_features=site.out_features,
                    k_tile_size=tile_size,
                    k_tile_count=tile_count,
                    column_count=columns,
                    mode=mode,
                    runtime_k_count=tile_count + len(column_k),
                    tile_k=tile_k,
                    column_k=column_k,
                )
            )
            continue

        site_plans.append(
            SitePlan(
                name=site.name,
                kind=site.kind,
                layer_index=site.layer_index,
                in_features=site.in_features,
                out_features=site.out_features,
                k_tile_size=tile_size,
                k_tile_count=tile_count,
                column_count=columns,
                mode=mode,
                runtime_k_count=tile_count,
                tile_k=tile_k,
                pre_adjusted_column_k=column_k,
            )
        )

    approximation = (
        "Evaluation-time float simulation: local partial sums are quantized by "
        "rounding to a 2^-k grid. This models k-dependent shifted partial-sum "
        "storage but does not implement an integer hardware accumulator."
    )
    return QuantizationPlan(mode=mode, sites=site_plans, approximation=approximation)


def apply_quantization_plan(model: Any, plan: QuantizationPlan) -> Any:
    try:
        import torch
    except ImportError as exc:
        raise RuntimeError("PyTorch is required for k-aware inference simulation.") from exc

    for site in plan.sites:
        parent, attr_name, module = _resolve_parent(model, site.name)
        if site.kind == "patch_embed_conv2d":
            if not isinstance(module, torch.nn.Conv2d):
                raise ValueError(f"Expected Conv2d at {site.name}, found {type(module)!r}.")
            wrapped = ShiftQuantizedPatchEmbedConv2d(module, site)
        else:
            if not isinstance(module, torch.nn.Linear):
                raise ValueError(f"Expected Linear at {site.name}, found {type(module)!r}.")
            wrapped = ShiftQuantizedLinear(module, site)
        setattr(parent, attr_name, wrapped)
    return model


def _get_submodule(model: Any, name: str) -> Any:
    module = model
    for part in name.split("."):
        module = getattr(module, part)
    return module


def _resolve_parent(model: Any, name: str) -> tuple[Any, str, Any]:
    parts = name.split(".")
    parent = model
    for part in parts[:-1]:
        parent = getattr(parent, part)
    attr_name = parts[-1]
    return parent, attr_name, getattr(parent, attr_name)


def _quantize_shift(x: Any, k: int) -> Any:
    step = 2.0 ** (-int(k))
    return torch_round(x / step) * step


def _quantize_shift_columns(x: Any, k_values: list[int]) -> Any:
    import torch

    k = torch.tensor(k_values, device=x.device, dtype=torch.float32).reshape(1, -1)
    step = torch.pow(torch.full_like(k, 2.0), -k).to(dtype=x.dtype)
    return torch.round(x / step) * step


def torch_round(x: Any) -> Any:
    import torch

    return torch.round(x)


def _k_for_tile(site: SitePlan, tile_index: int) -> int:
    if site.global_k is not None:
        return int(site.global_k)
    if site.layer_k is not None:
        return int(site.layer_k)
    if site.tile_k is None:
        raise ValueError(f"site {site.name!r} has no tile k values")
    return int(site.tile_k[tile_index])


def _partial_sum_linear(x: Any, weight: Any, bias: Any, site: SitePlan) -> Any:
    import torch

    original_dtype = x.dtype
    x_f = x.float()
    w_f = weight.float()
    acc = torch.zeros(
        (x_f.shape[0], site.out_features),
        device=x_f.device,
        dtype=torch.float32,
    )

    for tile_index in range(site.k_tile_count):
        i0 = tile_index * site.k_tile_size
        i1 = min(site.in_features, i0 + site.k_tile_size)

        if site.column_k is not None:
            tile_partial = x_f[:, i0:i1] @ w_f[:, i0:i1].t()
            tile_partial = _quantize_shift_columns(tile_partial, site.column_k)
        else:
            tile_partial = x_f[:, i0:i1] @ w_f[:, i0:i1].t()

        k = _k_for_tile(site, tile_index)
        acc = acc + _quantize_shift(tile_partial, k)

    if bias is not None:
        acc = acc + bias.float()
    return acc.to(original_dtype)


def _pre_adjusted_weight(weight: Any, site: SitePlan) -> Any:
    import torch

    if site.pre_adjusted_column_k is None:
        return weight

    adjusted = weight.detach().clone().float()
    k = torch.tensor(site.pre_adjusted_column_k, device=adjusted.device, dtype=torch.float32).reshape(-1, 1)
    step = torch.pow(torch.full_like(k, 2.0), -k).to(dtype=adjusted.dtype)
    adjusted = torch.round(adjusted / step) * step
    return adjusted.to(weight.dtype)


class ShiftQuantizedLinear(_TorchModule):
    def __init__(self, base: Any, site: SitePlan) -> None:
        import torch

        super().__init__()
        self.base = base
        self.site = site
        self.in_features = base.in_features
        self.out_features = base.out_features
        self.bias = base.bias
        if site.pre_adjusted_column_k is not None:
            self.weight = torch.nn.Parameter(_pre_adjusted_weight(base.weight, site), requires_grad=False)
        else:
            self.weight = base.weight

    def __call__(self, x: Any) -> Any:
        return self.forward(x)

    def forward(self, x: Any) -> Any:
        shape = x.shape[:-1]
        x_2d = x.reshape(-1, self.in_features)
        out = _partial_sum_linear(x_2d, self.weight, self.bias, self.site)
        return out.reshape(*shape, self.out_features)


class ShiftQuantizedPatchEmbedConv2d(_TorchModule):
    def __init__(self, base: Any, site: SitePlan) -> None:
        import torch

        super().__init__()
        self.base = base
        self.site = site
        self.in_channels = base.in_channels
        self.out_channels = base.out_channels
        self.kernel_size = base.kernel_size
        self.stride = base.stride
        self.padding = base.padding
        self.dilation = base.dilation
        self.groups = base.groups
        self.bias = base.bias
        weight_2d = base.weight.reshape(base.out_channels, -1)
        if site.pre_adjusted_column_k is not None:
            adjusted = _pre_adjusted_weight(weight_2d, site)
            self.weight_2d = torch.nn.Parameter(adjusted, requires_grad=False)
        else:
            self.weight_2d = weight_2d

    def __call__(self, x: Any) -> Any:
        return self.forward(x)

    def forward(self, x: Any) -> Any:
        import torch.nn.functional as F

        patches = F.unfold(
            x,
            kernel_size=self.kernel_size,
            dilation=self.dilation,
            padding=self.padding,
            stride=self.stride,
        )
        batch, _, patch_count = patches.shape
        patches_2d = patches.transpose(1, 2).reshape(batch * patch_count, self.site.in_features)
        out_2d = _partial_sum_linear(patches_2d, self.weight_2d, self.bias, self.site)
        out_h = _conv_out_dim(x.shape[-2], self.kernel_size[0], self.padding[0], self.dilation[0], self.stride[0])
        out_w = _conv_out_dim(x.shape[-1], self.kernel_size[1], self.padding[1], self.dilation[1], self.stride[1])
        return out_2d.reshape(batch, patch_count, self.out_channels).transpose(1, 2).reshape(
            batch,
            self.out_channels,
            out_h,
            out_w,
        )


def _conv_out_dim(size: int, kernel: int, padding: int, dilation: int, stride: int) -> int:
    return int(math.floor((size + 2 * padding - dilation * (kernel - 1) - 1) / stride + 1))
