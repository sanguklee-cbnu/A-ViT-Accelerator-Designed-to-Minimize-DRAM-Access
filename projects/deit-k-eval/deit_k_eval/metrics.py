from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class EvaluationMetrics:
    top1: float
    top5: float
    num_samples: int
    elapsed_seconds: float
    images_per_second: float


class AverageMeter:
    def __init__(self) -> None:
        self.sum = 0.0
        self.count = 0

    @property
    def avg(self) -> float:
        return self.sum / max(1, self.count)

    def update(self, value: float, n: int) -> None:
        self.sum += float(value) * int(n)
        self.count += int(n)


def _extract_logits(output: Any) -> Any:
    if hasattr(output, "logits"):
        return output.logits
    if isinstance(output, (tuple, list)):
        return output[0]
    return output


def accuracy(output: Any, target: Any, topk: tuple[int, ...] = (1, 5)) -> list[float]:
    maxk = min(max(topk), output.size(1))
    batch_size = target.size(0)

    _, pred = output.topk(maxk, 1, True, True)
    pred = pred.t()
    correct = pred.eq(target.reshape(1, -1).expand_as(pred))

    results = []
    for k in topk:
        effective_k = min(k, output.size(1))
        correct_k = correct[:effective_k].reshape(-1).float().sum(0)
        results.append(float(correct_k.mul_(100.0 / batch_size).item()))
    return results


def evaluate_model(
    model: Any,
    loader: Any,
    *,
    device: str,
    use_amp: bool = False,
) -> EvaluationMetrics:
    try:
        import torch
        from tqdm.auto import tqdm
    except ImportError as exc:
        raise RuntimeError("PyTorch and tqdm are required for evaluation.") from exc

    model.eval()
    top1_meter = AverageMeter()
    top5_meter = AverageMeter()
    num_samples = 0
    started = time.perf_counter()

    amp_enabled = use_amp and str(device).startswith("cuda")
    autocast_device = "cuda" if str(device).startswith("cuda") else "cpu"

    with torch.no_grad():
        for images, target in tqdm(loader, desc="eval", leave=False):
            images = images.to(device, non_blocking=True)
            target = target.to(device, non_blocking=True)

            with torch.autocast(device_type=autocast_device, enabled=amp_enabled):
                logits = _extract_logits(model(images))

            acc1, acc5 = accuracy(logits, target, topk=(1, 5))
            batch_size = int(images.size(0))
            top1_meter.update(acc1, batch_size)
            top5_meter.update(acc5, batch_size)
            num_samples += batch_size

    elapsed = time.perf_counter() - started
    return EvaluationMetrics(
        top1=top1_meter.avg,
        top5=top5_meter.avg,
        num_samples=num_samples,
        elapsed_seconds=elapsed,
        images_per_second=num_samples / elapsed if elapsed > 0 else 0.0,
    )
