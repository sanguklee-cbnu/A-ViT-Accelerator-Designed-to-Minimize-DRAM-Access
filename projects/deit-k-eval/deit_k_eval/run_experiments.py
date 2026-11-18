from __future__ import annotations

import argparse
from pathlib import Path

from .constants import EXPERIMENT_PRESETS, MODE_BASELINE
from .evaluate import add_common_eval_args, add_k_args, k_config_from_args, run_evaluation_once
from .models import ModelLoadError
from .plots import write_markdown_report, write_scatter_plot
from .results import write_run_result, write_summary


def _scheme_aliases() -> dict[str, tuple[str, str]]:
    aliases: dict[str, tuple[str, str]] = {}
    for experiment_name, mode in EXPERIMENT_PRESETS:
        aliases[experiment_name] = (experiment_name, mode)
        aliases[mode] = (experiment_name, mode)
    aliases["baseline_fp"] = ("baseline", MODE_BASELINE)
    aliases["baseline_reference"] = ("baseline", MODE_BASELINE)
    return aliases


def _parse_schemes(raw_schemes: list[str] | None) -> list[tuple[str, str]]:
    if not raw_schemes:
        return list(EXPERIMENT_PRESETS)

    aliases = _scheme_aliases()
    requested: list[str] = []
    for raw in raw_schemes:
        requested.extend(item.strip() for item in raw.split(",") if item.strip())

    selected: list[tuple[str, str]] = []
    seen_modes: set[str] = set()
    for item in requested:
        if item not in aliases:
            valid = ", ".join(sorted(aliases))
            raise SystemExit(f"ERROR: Unknown scheme {item!r}. Valid schemes: {valid}")
        experiment_name, mode = aliases[item]
        if mode not in seen_modes:
            selected.append((experiment_name, mode))
            seen_modes.add(mode)

    if MODE_BASELINE not in seen_modes:
        selected.insert(0, ("baseline", MODE_BASELINE))
        print("baseline auto-included so deltas and sanity checks are valid")
    return selected


def _check_baseline_accuracy(
    record: dict,
    *,
    synthetic_samples: int,
    min_top1: float,
    min_top5: float,
    skip: bool,
) -> None:
    if skip or synthetic_samples > 0:
        return

    top1 = float(record["metrics"]["top1"])
    top5 = float(record["metrics"]["top5"])
    if top1 < min_top1 or top5 < min_top5:
        output = record.get("outputs", {}).get("json", "not written yet")
        raise SystemExit(
            "ERROR: Baseline accuracy looks abnormal. "
            f"top1={top1:.4f}, top5={top5:.4f}, "
            f"minimums are top1>={min_top1:.4f}, top5>={min_top5:.4f}. "
            f"Baseline output: {output}. "
            "Stop and check ImageNet class folder mapping, preprocessing, model checkpoint, and labels."
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the DeiT-Tiny/16 k-assignment experiment suite.")
    add_common_eval_args(parser)
    add_k_args(parser, include_mode=False)
    parser.set_defaults(mode=None)
    parser.add_argument(
        "--schemes",
        nargs="+",
        default=None,
        help=(
            "Optional scheme names or modes to run. Accepts space-separated or comma-separated values. "
            "Examples: --schemes baseline fixed_global_k,heuristic_tilewise_k"
        ),
    )
    parser.add_argument("--baseline-min-top1", type=float, default=60.0)
    parser.add_argument("--baseline-min-top5", type=float, default=80.0)
    parser.add_argument("--skip-baseline-sanity-check", action="store_true")
    parser.add_argument("--output-dir", required=True, help="Suite output directory.")
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    selected_presets = _parse_schemes(args.schemes)

    records = []
    baseline_record = None
    for index, (experiment_name, mode) in enumerate(selected_presets):
        print(f"running experiment: {experiment_name} ({mode})")
        config = k_config_from_args(args, mode=mode)
        try:
            record = run_evaluation_once(
                experiment_name=experiment_name,
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
                print_inspection=index == 0,
            )
        except ModelLoadError as exc:
            raise SystemExit(
                f"ERROR: {exc}\nInstall dependencies with: python -m pip install -r requirements.txt"
            ) from exc
        except (FileNotFoundError, NotADirectoryError, ValueError) as exc:
            raise SystemExit(f"ERROR: {exc}") from exc
        experiment_dir = output_dir / str(record["experiment_name"])
        write_run_result(experiment_dir, record)

        if mode == MODE_BASELINE:
            baseline_record = record
            _check_baseline_accuracy(
                baseline_record,
                synthetic_samples=args.synthetic_samples,
                min_top1=args.baseline_min_top1,
                min_top5=args.baseline_min_top5,
                skip=args.skip_baseline_sanity_check,
            )
        records.append(record)

    if baseline_record is None:
        raise SystemExit("ERROR: Baseline was not run, so deltas cannot be computed.")

    baseline = baseline_record
    baseline_top1 = float(baseline["metrics"]["top1"])
    baseline_top5 = float(baseline["metrics"]["top5"])
    for record in records:
        record["delta_top1_vs_baseline"] = float(record["metrics"]["top1"]) - baseline_top1
        record["delta_top5_vs_baseline"] = float(record["metrics"]["top5"]) - baseline_top5
        experiment_dir = output_dir / str(record["experiment_name"])
        write_run_result(experiment_dir, record)

    summary_paths = write_summary(output_dir, records)
    scatter_path = write_scatter_plot(records, output_dir / "accuracy_vs_k_count.png")
    report_path = write_markdown_report(records, output_dir / "report.md")

    print(f"summary json: {summary_paths['json']}")
    print(f"summary csv: {summary_paths['csv']}")
    print(f"scatter plot: {scatter_path}")
    print(f"markdown report: {report_path}")


if __name__ == "__main__":
    main()
