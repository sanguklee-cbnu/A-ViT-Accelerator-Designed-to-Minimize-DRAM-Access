from __future__ import annotations

import argparse

from .models import ModelLoadError, format_model_inspection, load_deit_tiny, save_model_inspection


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inspect the required non-distilled DeiT-Tiny/16 checkpoint.")
    parser.add_argument("--backend", default="auto", choices=["auto", "timm", "hf", "huggingface"])
    parser.add_argument("--device", default="cpu", help="Device used to instantiate the model, e.g. cpu, cuda, cuda:0.")
    parser.add_argument("--output-path", default=None, help="Optional JSON path for inspection metadata.")
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    try:
        bundle = load_deit_tiny(backend=args.backend, pretrained=True, device=args.device)
    except ModelLoadError as exc:
        raise SystemExit(
            f"ERROR: {exc}\nInstall dependencies with: python -m pip install -r requirements.txt"
        ) from exc
    print(format_model_inspection(bundle.inspection))
    if args.output_path:
        path = save_model_inspection(bundle.inspection, args.output_path)
        print(f"inspection json: {path}")


if __name__ == "__main__":
    main()
