from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class DatasetInfo:
    dataset_path: str | None
    synthetic_samples: int
    num_samples: int
    num_classes: int
    layout: str = "unknown"
    class_to_idx_path: str | None = None


def _require_torch() -> Any:
    try:
        import torch

        return torch
    except ImportError as exc:
        raise RuntimeError("PyTorch is required. Install dependencies from requirements.txt.") from exc


def create_dataset(
    *,
    dataset_path: str | None,
    transform: Any,
    synthetic_samples: int = 0,
    max_samples: int | None = None,
    require_1000_classes: bool = True,
) -> tuple[Any, DatasetInfo]:
    torch = _require_torch()

    if synthetic_samples > 0:
        dataset = SyntheticImageNetDataset(num_samples=synthetic_samples)
        if max_samples is not None:
            dataset = torch.utils.data.Subset(dataset, range(min(max_samples, synthetic_samples)))
        return dataset, DatasetInfo(
            dataset_path=None,
            synthetic_samples=synthetic_samples,
            num_samples=len(dataset),
            num_classes=1000,
            layout="synthetic",
        )

    if dataset_path is None:
        raise FileNotFoundError(
            "ImageNet validation data was not provided. Pass --dataset-path pointing to "
            "the ImageFolder-style ImageNet-1k val directory."
        )

    root = Path(dataset_path)
    if not root.exists():
        raise FileNotFoundError(
            f"ImageNet validation path does not exist: {root}. "
            "Pass --dataset-path pointing to the ImageFolder-style ImageNet-1k val directory."
        )
    if not root.is_dir():
        raise NotADirectoryError(f"--dataset-path must be a directory: {root}")

    flat_files = sorted(root.glob("ILSVRC2012_val_*.JPEG"))
    class_dirs = [path for path in root.iterdir() if path.is_dir()]
    if flat_files and not class_dirs:
        dataset = FlatImageNetValDataset(root=root, transform=transform)
        if max_samples is not None:
            dataset = torch.utils.data.Subset(dataset, range(min(max_samples, len(dataset))))
        return dataset, DatasetInfo(
            dataset_path=str(root.resolve()),
            synthetic_samples=0,
            num_samples=len(dataset),
            num_classes=1000,
            layout="flat_imagenet_val_with_devkit_ground_truth",
        )

    try:
        from torchvision.datasets import ImageFolder
    except ImportError as exc:
        raise RuntimeError("torchvision is required for ImageNet ImageFolder loading.") from exc

    dataset = ImageFolder(str(root), transform=transform)
    if require_1000_classes and len(dataset.classes) != 1000:
        raise ValueError(
            f"Expected 1000 ImageNet classes under {root}, found {len(dataset.classes)}. "
            "Use --allow-non-imagenet-class-count only for local smoke tests."
        )

    if max_samples is not None:
        dataset = torch.utils.data.Subset(dataset, range(min(max_samples, len(dataset))))

    return dataset, DatasetInfo(
        dataset_path=str(root.resolve()),
        synthetic_samples=0,
        num_samples=len(dataset),
        num_classes=len(getattr(dataset, "classes", [])) or 1000,
        layout="imagefolder",
    )


def create_loader(
    dataset: Any,
    *,
    batch_size: int,
    num_workers: int,
    device: str,
) -> Any:
    torch = _require_torch()
    pin_memory = str(device).startswith("cuda")
    return torch.utils.data.DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=False,
        num_workers=num_workers,
        pin_memory=pin_memory,
        persistent_workers=num_workers > 0,
    )


class SyntheticImageNetDataset:
    """Deterministic tensor dataset for smoke tests only."""

    def __init__(self, num_samples: int, num_classes: int = 1000) -> None:
        self.num_samples = int(num_samples)
        self.num_classes = int(num_classes)

    def __len__(self) -> int:
        return self.num_samples

    def __getitem__(self, index: int) -> tuple[Any, int]:
        torch = _require_torch()
        generator = torch.Generator()
        generator.manual_seed(index)
        image = torch.rand((3, 224, 224), generator=generator)
        label = int(index % self.num_classes)
        return image, label


class FlatImageNetValDataset:
    """ImageNet val loader for the original flat ILSVRC2012_img_val layout."""

    def __init__(self, root: Path, transform: Any) -> None:
        self.root = Path(root)
        self.transform = transform
        self.samples = sorted(self.root.glob("ILSVRC2012_val_*.JPEG"))
        if len(self.samples) != 50000:
            raise ValueError(
                f"Expected 50000 flat ImageNet val JPEG files in {self.root}, "
                f"found {len(self.samples)}."
            )
        self.targets = _load_flat_imagenet_targets(self.root)
        if len(self.targets) != len(self.samples):
            raise ValueError(
                f"ImageNet ground truth count {len(self.targets)} does not match "
                f"image count {len(self.samples)}."
            )

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, index: int) -> tuple[Any, int]:
        from PIL import Image

        with Image.open(self.samples[index]) as image:
            image = image.convert("RGB")
            if self.transform is not None:
                image = self.transform(image)
        return image, int(self.targets[index])


def _load_flat_imagenet_targets(val_root: Path) -> list[int]:
    devkit_root = _find_imagenet_devkit_root(val_root)
    idx_to_wnid = _parse_imagenet_meta_mat(devkit_root / "data" / "meta.mat")
    ground_truth_path = devkit_root / "data" / "ILSVRC2012_validation_ground_truth.txt"
    if not ground_truth_path.exists():
        raise FileNotFoundError(f"Missing ImageNet validation ground truth: {ground_truth_path}")
    val_idcs = [
        int(line.strip())
        for line in ground_truth_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    val_wnids = [idx_to_wnid[idx] for idx in val_idcs]
    sorted_wnids = sorted(set(idx_to_wnid.values()))
    wnid_to_class_idx = {wnid: idx for idx, wnid in enumerate(sorted_wnids)}
    return [wnid_to_class_idx[wnid] for wnid in val_wnids]


def _find_imagenet_devkit_root(val_root: Path) -> Path:
    candidates = [
        val_root.parent / "ILSVRC2012_devkit_t12",
        val_root.parent.parent / "ILSVRC2012_devkit_t12",
        val_root.parent / "imagenet" / "ILSVRC2012_devkit_t12",
    ]
    for candidate in candidates:
        if (candidate / "data" / "meta.mat").exists():
            return candidate
    raise FileNotFoundError(
        f"Could not find ILSVRC2012_devkit_t12 next to flat val directory {val_root}."
    )


def _parse_imagenet_meta_mat(meta_path: Path) -> dict[int, str]:
    if not meta_path.exists():
        raise FileNotFoundError(f"Missing ImageNet meta.mat: {meta_path}")
    try:
        import scipy.io as sio
    except ImportError as exc:
        raise RuntimeError("scipy is required to parse ImageNet devkit meta.mat.") from exc

    meta = sio.loadmat(str(meta_path), squeeze_me=True)["synsets"]
    nums_children = list(zip(*meta))[4]
    meta = [meta[idx] for idx, num_children in enumerate(nums_children) if num_children == 0]
    idcs, wnids = list(zip(*meta))[:2]
    return {int(idx): str(wnid) for idx, wnid in zip(idcs, wnids)}
