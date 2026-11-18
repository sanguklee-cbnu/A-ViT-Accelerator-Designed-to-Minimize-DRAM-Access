from __future__ import annotations

import csv
import json
from dataclasses import asdict, is_dataclass
from pathlib import Path
from typing import Any


SUMMARY_FIELDS = [
    "experiment_name",
    "mode",
    "top1",
    "top5",
    "delta_top1_vs_baseline",
    "delta_top5_vs_baseline",
    "runtime_k_count",
    "estimated_k_storage_bits",
    "estimated_k_storage_bytes",
    "pre_adjusted_weight_column_count",
    "offline_pre_adjustment_k_bits",
    "target_linear_site_count",
    "target_layer_count",
    "elapsed_seconds",
    "images_per_second",
    "num_samples",
    "config_json",
    "output_json_path",
    "output_csv_path",
]


def to_jsonable(value: Any) -> Any:
    if is_dataclass(value):
        return to_jsonable(asdict(value))
    if isinstance(value, dict):
        return {str(k): to_jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_jsonable(v) for v in value]
    if isinstance(value, Path):
        return str(value)
    return value


def flatten_result(record: dict[str, Any]) -> dict[str, Any]:
    metrics = record.get("metrics", {})
    k_assignment = record.get("k_assignment", {})
    outputs = record.get("outputs", {})
    config = record.get("config", {})
    return {
        "experiment_name": record.get("experiment_name"),
        "mode": record.get("mode"),
        "top1": metrics.get("top1"),
        "top5": metrics.get("top5"),
        "delta_top1_vs_baseline": record.get("delta_top1_vs_baseline"),
        "delta_top5_vs_baseline": record.get("delta_top5_vs_baseline"),
        "runtime_k_count": k_assignment.get("runtime_k_count"),
        "estimated_k_storage_bits": k_assignment.get("estimated_k_storage_bits"),
        "estimated_k_storage_bytes": k_assignment.get("estimated_k_storage_bytes"),
        "pre_adjusted_weight_column_count": k_assignment.get("pre_adjusted_weight_column_count"),
        "offline_pre_adjustment_k_bits": k_assignment.get("offline_pre_adjustment_k_bits"),
        "target_linear_site_count": k_assignment.get("target_linear_site_count"),
        "target_layer_count": k_assignment.get("target_layer_count"),
        "elapsed_seconds": metrics.get("elapsed_seconds"),
        "images_per_second": metrics.get("images_per_second"),
        "num_samples": metrics.get("num_samples"),
        "config_json": json.dumps(config, sort_keys=True),
        "output_json_path": outputs.get("json"),
        "output_csv_path": outputs.get("csv"),
    }


def write_run_result(output_path: str | Path, record: dict[str, Any]) -> dict[str, str]:
    output_dir = Path(output_path)
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "result.json"
    csv_path = output_dir / "result.csv"
    record.setdefault("outputs", {})
    record["outputs"].update({"json": str(json_path.resolve()), "csv": str(csv_path.resolve())})

    json_path.write_text(json.dumps(to_jsonable(record), indent=2) + "\n", encoding="utf-8")

    flat = flatten_result(record)
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(flat.keys()))
        writer.writeheader()
        writer.writerow(flat)

    return {"json": str(json_path.resolve()), "csv": str(csv_path.resolve())}


def write_summary(output_dir: str | Path, records: list[dict[str, Any]]) -> dict[str, str]:
    root = Path(output_dir)
    root.mkdir(parents=True, exist_ok=True)
    json_path = root / "result_summary.json"
    csv_path = root / "result_summary.csv"

    json_path.write_text(json.dumps(to_jsonable(records), indent=2) + "\n", encoding="utf-8")
    rows = [flatten_result(record) for record in records]
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=SUMMARY_FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field) for field in SUMMARY_FIELDS})

    return {"json": str(json_path.resolve()), "csv": str(csv_path.resolve())}
