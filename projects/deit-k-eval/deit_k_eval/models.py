from __future__ import annotations

import importlib.util
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable

from .constants import HF_MODEL_NAME, TIMM_MODEL_NAME


class ModelLoadError(RuntimeError):
    """Raised when the required non-distilled DeiT model cannot be loaded."""


@dataclass(frozen=True)
class ModelInspection:
    model_name: str
    backend: str
    distilled: bool
    patch_size: list[int]
    embedding_dimension: int
    number_of_heads: int
    number_of_layers: int
    classifier_output_dimension: int


@dataclass
class ModelBundle:
    model: Any
    preprocess: Callable[[Any], Any]
    inspection: ModelInspection


def _module_available(module_name: str) -> bool:
    return importlib.util.find_spec(module_name) is not None


def _as_2d_patch_size(value: Any) -> list[int]:
    if isinstance(value, int):
        return [int(value), int(value)]
    if isinstance(value, (tuple, list)):
        if len(value) == 1:
            return [int(value[0]), int(value[0])]
        return [int(value[0]), int(value[1])]
    return [0, 0]


def _classifier_out_features_timm(model: Any) -> int:
    classifier = model.get_classifier() if hasattr(model, "get_classifier") else None
    if hasattr(classifier, "out_features"):
        return int(classifier.out_features)
    head = getattr(model, "head", None)
    if hasattr(head, "out_features"):
        return int(head.out_features)
    return int(getattr(model, "num_classes", 0))


def _is_timm_distilled(model: Any) -> bool:
    default_cfg = getattr(model, "default_cfg", {}) or {}
    architecture = str(default_cfg.get("architecture", "")).lower()
    return (
        hasattr(model, "dist_token")
        or hasattr(model, "head_dist")
        or "distilled" in architecture
        or "distilled" in TIMM_MODEL_NAME
    )


def _load_timm_deit_tiny(pretrained: bool) -> ModelBundle:
    try:
        import timm
        from timm.data import create_transform

        try:
            from timm.data import resolve_model_data_config

            data_config_resolver = lambda model: resolve_model_data_config(model)
        except ImportError:
            from timm.data import resolve_data_config

            data_config_resolver = lambda model: resolve_data_config({}, model=model)
    except ImportError as exc:
        raise ModelLoadError("timm is not installed.") from exc

    try:
        model = timm.create_model(TIMM_MODEL_NAME, pretrained=pretrained)
    except Exception as exc:
        raise ModelLoadError(
            f"Could not load required timm model {TIMM_MODEL_NAME!r}. "
            "The code does not switch to a different timm architecture."
        ) from exc

    model.eval()
    distilled = _is_timm_distilled(model)
    if distilled:
        raise ModelLoadError(f"Refusing distilled checkpoint for {TIMM_MODEL_NAME!r}.")

    data_config = data_config_resolver(model)
    input_size = tuple(data_config.get("input_size", (3, 224, 224)))
    if input_size[-2:] != (224, 224):
        raise ModelLoadError(
            f"Expected 224x224 DeiT preprocessing, got input_size={input_size}."
        )
    preprocess = create_transform(**data_config, is_training=False)

    blocks = getattr(model, "blocks", [])
    first_block = blocks[0] if len(blocks) else None
    first_attn = getattr(first_block, "attn", None)

    inspection = ModelInspection(
        model_name=TIMM_MODEL_NAME,
        backend="timm",
        distilled=False,
        patch_size=_as_2d_patch_size(getattr(model.patch_embed, "patch_size", [16, 16])),
        embedding_dimension=int(getattr(model, "embed_dim", getattr(model, "num_features", 0))),
        number_of_heads=int(getattr(first_attn, "num_heads", 0)),
        number_of_layers=int(len(blocks)),
        classifier_output_dimension=_classifier_out_features_timm(model),
    )
    return ModelBundle(model=model, preprocess=preprocess, inspection=inspection)


class _HFImageProcessorTransform:
    def __init__(self, processor: Any) -> None:
        self.processor = processor

    def __call__(self, image: Any) -> Any:
        if hasattr(image, "convert"):
            image = image.convert("RGB")
        batch = self.processor(images=image, return_tensors="pt")
        return batch["pixel_values"][0]


def _load_hf_deit_tiny(pretrained: bool) -> ModelBundle:
    if not pretrained:
        raise ModelLoadError("Hugging Face fallback is only supported for pretrained=True.")

    try:
        from transformers import AutoImageProcessor, AutoModelForImageClassification
    except ImportError as exc:
        raise ModelLoadError("transformers is not installed for Hugging Face fallback.") from exc

    try:
        processor = AutoImageProcessor.from_pretrained(HF_MODEL_NAME)
        model = AutoModelForImageClassification.from_pretrained(HF_MODEL_NAME)
    except Exception as exc:
        raise ModelLoadError(f"Could not load Hugging Face model {HF_MODEL_NAME!r}.") from exc

    model.eval()
    class_name = model.__class__.__name__.lower()
    if "withteacher" in class_name or "distilled" in HF_MODEL_NAME:
        raise ModelLoadError(f"Refusing distilled checkpoint for {HF_MODEL_NAME!r}.")

    cfg = model.config
    inspection = ModelInspection(
        model_name=HF_MODEL_NAME,
        backend="huggingface",
        distilled=False,
        patch_size=_as_2d_patch_size(getattr(cfg, "patch_size", 16)),
        embedding_dimension=int(getattr(cfg, "hidden_size", 0)),
        number_of_heads=int(getattr(cfg, "num_attention_heads", 0)),
        number_of_layers=int(getattr(cfg, "num_hidden_layers", 0)),
        classifier_output_dimension=int(getattr(cfg, "num_labels", 0)),
    )
    return ModelBundle(model=model, preprocess=_HFImageProcessorTransform(processor), inspection=inspection)


def load_deit_tiny(
    *,
    backend: str = "auto",
    pretrained: bool = True,
    device: str | None = None,
) -> ModelBundle:
    """Load the required non-distilled DeiT-Tiny/16 checkpoint."""

    normalized = backend.lower()
    if normalized not in {"auto", "timm", "hf", "huggingface"}:
        raise ValueError("backend must be one of: auto, timm, hf, huggingface")

    if normalized in {"auto", "timm"}:
        if normalized == "timm" or _module_available("timm"):
            bundle = _load_timm_deit_tiny(pretrained=pretrained)
            if device is not None:
                bundle.model.to(device)
            return bundle

    if normalized in {"auto", "hf", "huggingface"}:
        bundle = _load_hf_deit_tiny(pretrained=pretrained)
        if device is not None:
            bundle.model.to(device)
        return bundle

    raise ModelLoadError(
        "Neither timm nor transformers is available. Install requirements.txt and retry."
    )


def format_model_inspection(inspection: ModelInspection) -> str:
    return "\n".join(
        [
            f"model name: {inspection.model_name}",
            f"backend: {inspection.backend}",
            f"distilled: {inspection.distilled}",
            f"patch size: {inspection.patch_size}",
            f"embedding dimension: {inspection.embedding_dimension}",
            f"number of heads: {inspection.number_of_heads}",
            f"number of layers: {inspection.number_of_layers}",
            f"classifier output dimension: {inspection.classifier_output_dimension}",
        ]
    )


def save_model_inspection(inspection: ModelInspection, output_path: str | Path) -> Path:
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(inspection), indent=2) + "\n", encoding="utf-8")
    return path
