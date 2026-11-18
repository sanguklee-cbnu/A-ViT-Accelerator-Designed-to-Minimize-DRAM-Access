from __future__ import annotations

from pathlib import Path
from typing import Any


def _summary_row(record: dict[str, Any]) -> dict[str, Any]:
    metrics = record.get("metrics", {})
    k_assignment = record.get("k_assignment", {})
    return {
        "experiment_name": record.get("experiment_name", ""),
        "mode": record.get("mode", ""),
        "top1": float(metrics.get("top1", 0.0)),
        "top5": float(metrics.get("top5", 0.0)),
        "delta_top1_vs_baseline": float(record.get("delta_top1_vs_baseline") or 0.0),
        "delta_top5_vs_baseline": float(record.get("delta_top5_vs_baseline") or 0.0),
        "runtime_k_count": int(k_assignment.get("runtime_k_count", 0)),
        "estimated_k_storage_bits": int(k_assignment.get("estimated_k_storage_bits", 0)),
        "estimated_k_storage_bytes": int(k_assignment.get("estimated_k_storage_bytes", 0)),
        "output_json_path": record.get("outputs", {}).get("json", ""),
        "output_csv_path": record.get("outputs", {}).get("csv", ""),
    }


def write_scatter_plot(records: list[dict[str, Any]], output_path: str | Path) -> Path:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise RuntimeError("matplotlib is required to generate the scatter plot.") from exc

    rows = [_summary_row(record) for record in records]
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)

    fig, ax = plt.subplots(figsize=(9, 5.5))
    xs = [row["runtime_k_count"] for row in rows]
    ys = [row["top1"] for row in rows]
    ax.scatter(xs, ys, s=64)
    for row in rows:
        ax.annotate(
            row["experiment_name"],
            (row["runtime_k_count"], row["top1"]),
            textcoords="offset points",
            xytext=(6, 6),
            fontsize=8,
        )
    ax.set_xlabel("runtime k count")
    ax.set_ylabel("top-1 accuracy (%)")
    ax.set_title("DeiT-Tiny/16 k-assignment accuracy")
    ax.grid(True, linestyle=":", linewidth=0.7)
    fig.tight_layout()
    fig.savefig(path, dpi=160)
    plt.close(fig)
    return path.resolve()


def pareto_front(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows = [_summary_row(record) for record in records]
    front: list[dict[str, Any]] = []
    for row in rows:
        dominated = False
        for other in rows:
            at_least_as_good = (
                other["runtime_k_count"] <= row["runtime_k_count"]
                and other["top1"] >= row["top1"]
            )
            strictly_better = (
                other["runtime_k_count"] < row["runtime_k_count"]
                or other["top1"] > row["top1"]
            )
            if at_least_as_good and strictly_better:
                dominated = True
                break
        if not dominated:
            front.append(row)
    return sorted(front, key=lambda item: (item["runtime_k_count"], -item["top1"]))


def write_markdown_report(records: list[dict[str, Any]], output_path: str | Path) -> Path:
    rows = [_summary_row(record) for record in records]
    front = pareto_front(records)
    best_accuracy = max(rows, key=lambda item: (item["top1"], item["top5"])) if rows else None
    non_baseline_rows = [row for row in rows if row["runtime_k_count"] > 0]
    low_overhead_pool = non_baseline_rows or rows
    best_low_overhead = (
        min(low_overhead_pool, key=lambda item: (item["runtime_k_count"], -item["top1"]))
        if low_overhead_pool
        else None
    )
    best_pareto = front[0] if front else None
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)

    lines = ["# DeiT-Tiny/16 k-assignment report", "", "## Best schemes", ""]
    if best_accuracy is None:
        lines.append("No completed experiments were available.")
    else:
        lines.append(
            f"- Best accuracy scheme: `{best_accuracy['experiment_name']}` "
            f"(top-1={best_accuracy['top1']:.4f}%, top-5={best_accuracy['top5']:.4f}%)."
        )
        if best_low_overhead is not None:
            lines.append(
                f"- Best low-overhead scheme: `{best_low_overhead['experiment_name']}` "
                f"(runtime_k_count={best_low_overhead['runtime_k_count']}, "
                f"top-1={best_low_overhead['top1']:.4f}%)."
            )
        if best_pareto is not None:
            lines.append(
                f"- Best Pareto point: `{best_pareto['experiment_name']}` "
                f"(runtime_k_count={best_pareto['runtime_k_count']}, "
                f"top-1={best_pareto['top1']:.4f}%)."
            )
        lines.append("")
        lines.append(
            "A point is treated as Pareto-optimal when no other run has both lower or equal "
            "runtime k count and higher or equal top-1 accuracy, with at least one strict improvement."
        )

    lines.extend(
        [
            "",
            "## Results",
            "",
            "| experiment | mode | top-1 | top-5 | delta top-1 | delta top-5 | runtime k count | k storage bits | k storage bytes |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for row in rows:
        lines.append(
            f"| {row['experiment_name']} | `{row['mode']}` | {row['top1']:.4f} | "
            f"{row['top5']:.4f} | {row['delta_top1_vs_baseline']:.4f} | "
            f"{row['delta_top5_vs_baseline']:.4f} | {row['runtime_k_count']} | "
            f"{row['estimated_k_storage_bits']} | "
            f"{row['estimated_k_storage_bytes']} |"
        )

    lines.extend(["", "## Output files", ""])
    for row in rows:
        lines.append(
            f"- `{row['experiment_name']}`: JSON `{row['output_json_path']}`, "
            f"CSV `{row['output_csv_path']}`"
        )

    lines.extend(["", "## Pareto front", ""])
    if front:
        for item in front:
            lines.append(
                f"- `{item['experiment_name']}`: top-1={item['top1']:.4f}%, "
                f"runtime_k_count={item['runtime_k_count']}"
            )
    else:
        lines.append("- No completed experiments.")

    lines.extend(
        [
            "",
            "## Implementation note",
            "",
            "This is a preliminary DeiT-Tiny trend study, not the final evaluation with "
            "the user's actual model weights and production inference code.",
            "",
            "Non-baseline k-assignment modes replace the target Patch Embedding and MLP FC2 "
            "modules with evaluation-time k-aware partial-sum simulation wrappers. The simulation "
            "partitions tiles only along the input-channel / GEMM K dimension, rounds local partial "
            "sums to a 2^-k grid, and then restores them to float for continued accumulation. "
            "Learned/optimized modes use precomputed k values loaded from "
            "`--learned-k-path`; this project does not train or optimize those k values yet.",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path.resolve()
