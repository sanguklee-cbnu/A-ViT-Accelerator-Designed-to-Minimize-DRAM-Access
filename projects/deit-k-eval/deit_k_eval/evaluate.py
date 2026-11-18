from __future__ import annotations

import argparse
import datetime as dt
import uuid
from dataclasses import asdict
from pathlib import Path
from typing import Any

from .constants import ALL_MODES, MODE_BASELINE
from .data import create_dataset, create_loader
from .determinism import set_deterministic
from .k_assignment import KAssignmentConfig, build_strategy
from .metrics import evaluate_model
from .models import ModelLoadError, format_model_inspection, load_deit_tiny
from .results import write_run_result


def resolve_device(device: str) -> str:
    if device != "auto":
        return device
    try:
        import torch

        return "cuda" if torch.cuda.is_available() else "cpu"
    except ImportError:
        return "cpu"


def add_common_eval_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--dataset-path", default=None, help="ImageFolder-style ImageNet-1k validation directory.")
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--device", default="auto", help="cpu, cuda, cuda:0, or auto.")
    parser.add_argument("--num-workers", type=int, default=8)
    parser.add_argument("--seed", type=int, default=123)
    parser.add_argument("--model-backend", default="auto", choices=["auto", "timm", "hf", "huggingface"])
    parser.add_argument("--max-samples", type=int, default=None, help="Optional sample limit for debugging.")
    parser.add_argument("--synthetic-samples", type=int, default=0, help="Smoke-test sample count. Does not use ImageNet.")
    parser.add_argument(
        "--allow-non-imagenet-class-count",
        action="store_true",
        help="Allow ImageFolder datasets with class count other than 1000 for smoke tests.",
    )
    parser.add_argument("--amp", action="store_true", help="Use CUDA autocast during inference.")


def add_k_args(parser: argparse.ArgumentParser, *, include_mode: bool = True) -> None:
    if include_mode:
        parser.add_argument("--mode", default=MODE_BASELINE, choices=list(ALL_MODES))
    parser.add_argument("--k-bits", type=int, default=8)
    parser.add_argument("--global-k", type=int, default=0)
    parser.add_argument("--tile-out", type=int, default=16, help="Deprecated; K tiles do not partition outputs.")
    parser.add_argument("--tile-in", type=int, default=16, help="Deprecated; use --patch-k-tile-size/--fc2-k-tile-size.")
    parser.add_argument("--patch-k-tile-size", type=int, default=192, help="K-dimension tile size for patch embedding.")
    parser.add_argument("--fc2-k-tile-size", type=int, default=32, help="K-dimension tile size for MLP FC2 layers.")
    parser.add_argument("--column-group-size", type=int, default=16, help="Deprecated; column-wise k now uses each logical weight/output column inside a K tile.")
    parser.add_argument("--include-regex", default=None)
    parser.add_argument("--exclude-regex", default=None)
    parser.add_argument("--learned-k-path", default=None)
    parser.add_argument("--pre-adjusted-weight-path", default=None)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Evaluate DeiT-Tiny/16 on ImageNet-1k val.")
    add_common_eval_args(parser)
    add_k_args(parser, include_mode=True)
    parser.add_argument("--output-path", required=True, help="Output directory for result.json and result.csv.")
    return parser


def k_config_from_args(args: argparse.Namespace, mode: str | None = None) -> KAssignmentConfig:
    defaults = KAssignmentConfig(mode=mode or args.mode)
    return KAssignmentConfig(
        mode=mode or args.mode,
        k_bits=args.k_bits,
        global_k=args.global_k,
        tile_shape=(args.tile_out, args.tile_in),
        patch_k_tile_size=args.patch_k_tile_size,
        fc2_k_tile_size=args.fc2_k_tile_size,
        column_group_size=args.column_group_size,
        include_regex=args.include_regex or defaults.include_regex,
        exclude_regex=args.exclude_regex if args.exclude_regex is not None else defaults.exclude_regex,
        learned_k_path=args.learned_k_path,
        pre_adjusted_weight_path=args.pre_adjusted_weight_path,
    )


def run_evaluation_once(
    *,
    experiment_name: str,
    config: KAssignmentConfig,
    dataset_path: str | None,
    batch_size: int,
    device: str,
    num_workers: int,
    seed: int,
    model_backend: str,
    max_samples: int | None = None,
    synthetic_samples: int = 0,
    allow_non_imagenet_class_count: bool = False,
    amp: bool = False,
    print_inspection: bool = True,
) -> dict[str, Any]:
    set_deterministic(seed)
    resolved_device = resolve_device(device)
    bundle = load_deit_tiny(backend=model_backend, pretrained=True, device=resolved_device)
    if print_inspection:
        print(format_model_inspection(bundle.inspection))

    strategy = build_strategy(config.mode)
    k_summary = strategy.build_summary(bundle.model, config)
    bundle.model, k_summary = strategy.apply_to_model(bundle.model, config, k_summary)

    dataset, dataset_info = create_dataset(
        dataset_path=dataset_path,
        transform=bundle.preprocess,
        synthetic_samples=synthetic_samples,
        max_samples=max_samples,
        require_1000_classes=not allow_non_imagenet_class_count,
    )
    loader = create_loader(
        dataset,
        batch_size=batch_size,
        num_workers=num_workers,
        device=resolved_device,
    )
    metrics = evaluate_model(bundle.model, loader, device=resolved_device, use_amp=amp)

    return {
        "run_id": str(uuid.uuid4()),
        "timestamp_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "experiment_name": experiment_name,
        "mode": config.mode,
        "model": asdict(bundle.inspection),
        "dataset": asdict(dataset_info),
        "metrics": asdict(metrics),
        "k_assignment": k_summary.to_dict(),
        "config": {
            "dataset_path": str(Path(dataset_path).resolve()) if dataset_path else None,
            "batch_size": batch_size,
            "device": resolved_device,
            "requested_device": device,
            "num_workers": num_workers,
            "seed": seed,
            "model_backend": model_backend,
            "max_samples": max_samples,
            "synthetic_samples": synthetic_samples,
            "allow_non_imagenet_class_count": allow_non_imagenet_class_count,
            "amp": amp,
            "k_assignment": config.to_dict(),
        },
        "delta_top1_vs_baseline": None,
        "delta_top5_vs_baseline": None,
    }


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    config = k_config_from_args(args)
    try:
        record = run_evaluation_once(
            experiment_name=args.mode,
            config=config,
            dataset_path=args.dataset_path,
            batch_size=args.batch_size,
            device=args.device,
            num_workers=args.num_workers,
            seed=args.seed,
            model_backend=args.model_backend,
            max_samples=args.max_samples,
            synthetic_samples=args.synthetic_samples,
            allow_non_imagenet_class_count=args.allow_non_imagenet_class_count,
            amp=args.amp,
            print_inspection=True,
        )
    except ModelLoadError as exc:
        raise SystemExit(
            f"ERROR: {exc}\nInstall dependencies with: python -m pip install -r requirements.txt"
        ) from exc
    except (FileNotFoundError, NotADirectoryError, ValueError) as exc:
        raise SystemExit(f"ERROR: {exc}") from exc
    record["delta_top1_vs_baseline"] = 0.0 if args.mode == MODE_BASELINE else None
    record["delta_top5_vs_baseline"] = 0.0 if args.mode == MODE_BASELINE else None
    outputs = write_run_result(args.output_path, record)
    print(f"result json: {outputs['json']}")
    print(f"result csv: {outputs['csv']}")


if __name__ == "__main__":
    main()
