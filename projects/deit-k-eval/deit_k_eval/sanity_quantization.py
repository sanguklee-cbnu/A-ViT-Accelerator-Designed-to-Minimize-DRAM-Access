from __future__ import annotations

import argparse
import json
from dataclasses import asdict
from pathlib import Path
from typing import Any

from .constants import (
    MODE_BASELINE,
    MODE_FIXED_GLOBAL,
    MODE_FIXED_LAYERWISE,
    MODE_HEURISTIC_TILEWISE,
    MODE_LEARNED_TILEWISE,
    MODE_LEARNED_TILEWISE_COLUMNWISE,
    MODE_LEARNED_TILEWISE_PRE_ADJUSTED,
)
from .determinism import set_deterministic
from .evaluate import resolve_device
from .k_assignment import KAssignmentConfig, build_strategy
from .k_assignment.base import discover_linear_sites
from .k_assignment.simulation import column_count, k_tile_count
from .models import load_deit_tiny


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Check that k-aware wrappers change DeiT logits.")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--seed", type=int, default=123)
    parser.add_argument("--output-dir", default="artifacts/quantization_sanity")
    parser.add_argument("--global-k", type=int, default=0)
    parser.add_argument("--patch-k-tile-size", type=int, default=192)
    parser.add_argument("--fc2-k-tile-size", type=int, default=32)
    parser.add_argument("--column-group-size", type=int, default=16)
    return parser


def _k_config(args: argparse.Namespace, mode: str, learned_k_path: str | None = None) -> KAssignmentConfig:
    return KAssignmentConfig(
        mode=mode,
        global_k=args.global_k,
        patch_k_tile_size=args.patch_k_tile_size,
        fc2_k_tile_size=args.fc2_k_tile_size,
        column_group_size=args.column_group_size,
        learned_k_path=learned_k_path,
    )


def _write_learned_fixture(args: argparse.Namespace, output_dir: Path) -> Path:
    bundle = load_deit_tiny(device="cpu")
    config = _k_config(args, MODE_LEARNED_TILEWISE)
    sites = discover_linear_sites(
        bundle.model,
        include_regex=config.include_regex,
        exclude_regex=config.exclude_regex,
    )
    learned: dict[str, Any] = {"sites": {}}
    for site in sites:
        tiles = k_tile_count(site, config)
        columns = column_count(site, config)
        tile_k = [int(1 + ((tile + site.layer_index + 1) % 5)) for tile in range(tiles)]
        column_k = [int(1 + ((col + site.layer_index + 1) % 4)) for col in range(columns)]
        learned["sites"][site.name] = {
            "tile_k": tile_k,
            "column_k": column_k,
        }

    path = output_dir / "learned_k_fixture.json"
    path.write_text(json.dumps(learned, indent=2) + "\n", encoding="utf-8")
    return path


def _logits_for(args: argparse.Namespace, mode: str, x: Any, learned_k_path: str | None = None) -> tuple[Any, dict[str, Any]]:
    import torch

    bundle = load_deit_tiny(device=resolve_device(args.device))
    config = _k_config(args, mode, learned_k_path=learned_k_path)
    strategy = build_strategy(mode)
    summary = strategy.build_summary(bundle.model, config)
    bundle.model, summary = strategy.apply_to_model(bundle.model, config, summary)
    bundle.model.eval()
    with torch.no_grad():
        logits = bundle.model(x.to(resolve_device(args.device))).detach().cpu()
    return logits, {
        "model": asdict(bundle.inspection),
        "k_assignment": summary.to_dict(),
    }


def main(argv: list[str] | None = None) -> None:
    import torch

    args = build_parser().parse_args(argv)
    set_deterministic(args.seed)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    learned_path = _write_learned_fixture(args, output_dir)
    device = resolve_device(args.device)
    generator = torch.Generator(device="cpu")
    generator.manual_seed(args.seed)
    x = torch.rand((1, 3, 224, 224), generator=generator).to(device)

    modes = [
        MODE_BASELINE,
        MODE_FIXED_GLOBAL,
        MODE_FIXED_LAYERWISE,
        MODE_HEURISTIC_TILEWISE,
        MODE_LEARNED_TILEWISE,
        MODE_LEARNED_TILEWISE_COLUMNWISE,
        MODE_LEARNED_TILEWISE_PRE_ADJUSTED,
    ]
    outputs: dict[str, Any] = {}
    metadata: dict[str, Any] = {}
    for mode in modes:
        logits, info = _logits_for(
            args,
            mode,
            x,
            learned_k_path=str(learned_path) if mode.startswith("learned_or_optimized") else None,
        )
        outputs[mode] = logits
        metadata[mode] = info
        if mode == MODE_BASELINE:
            model_info = info["model"]
            print("\n".join([
                f"model name: {model_info['model_name']}",
                f"backend: {model_info['backend']}",
                f"distilled: {model_info['distilled']}",
                f"patch size: {model_info['patch_size']}",
                f"embedding dimension: {model_info['embedding_dimension']}",
                f"number of heads: {model_info['number_of_heads']}",
                f"number of layers: {model_info['number_of_layers']}",
                f"classifier output dimension: {model_info['classifier_output_dimension']}",
            ]))

    baseline = outputs[MODE_BASELINE]
    comparisons = []
    for mode in modes[1:]:
        diff = (outputs[mode] - baseline).abs()
        comparisons.append(
            {
                "mode": mode,
                "max_abs_diff_vs_baseline": float(diff.max().item()),
                "mean_abs_diff_vs_baseline": float(diff.mean().item()),
                "different_from_baseline": bool(float(diff.max().item()) > 0.0),
                "runtime_k_count": metadata[mode]["k_assignment"]["runtime_k_count"],
                "implemented_behavior": metadata[mode]["k_assignment"]["implemented_behavior"],
            }
        )

    pairwise = []
    pairs = [
        (MODE_FIXED_GLOBAL, MODE_FIXED_LAYERWISE),
        (MODE_FIXED_LAYERWISE, MODE_HEURISTIC_TILEWISE),
        (MODE_LEARNED_TILEWISE, MODE_LEARNED_TILEWISE_COLUMNWISE),
        (MODE_LEARNED_TILEWISE, MODE_LEARNED_TILEWISE_PRE_ADJUSTED),
    ]
    for left, right in pairs:
        diff = (outputs[left] - outputs[right]).abs()
        pairwise.append(
            {
                "left": left,
                "right": right,
                "max_abs_diff": float(diff.max().item()),
                "mean_abs_diff": float(diff.mean().item()),
                "different": bool(float(diff.max().item()) > 0.0),
            }
        )

    result = {
        "input_shape": list(x.shape),
        "learned_k_fixture": str(learned_path.resolve()),
        "comparisons_vs_baseline": comparisons,
        "pairwise_comparisons": pairwise,
        "metadata": metadata,
    }
    output_path = output_dir / "sanity_result.json"
    output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"sanity_result": str(output_path.resolve()), "comparisons": comparisons, "pairwise": pairwise}, indent=2))


if __name__ == "__main__":
    main()
