from __future__ import annotations

import math
import re
from dataclasses import asdict, dataclass, field
from typing import Any, Protocol


DEFAULT_INCLUDE_REGEX = (
    r"(^blocks\.\d+\.mlp\.fc2$)|"
    r"(^encoder\.layer\.\d+\.output\.dense$)"
)
DEFAULT_EXCLUDE_REGEX = r"(head|head_dist|classifier|pooler)"


@dataclass(frozen=True)
class LinearSite:
    name: str
    layer_index: int
    in_features: int
    out_features: int
    kind: str = "linear"

    @property
    def weight_shape(self) -> tuple[int, int]:
        return (self.out_features, self.in_features)


@dataclass(frozen=True)
class KAssignmentConfig:
    mode: str
    k_bits: int = 8
    global_k: int = 0
    tile_shape: tuple[int, int] = (16, 16)
    patch_k_tile_size: int = 192
    fc2_k_tile_size: int = 32
    column_group_size: int = 16
    include_regex: str = DEFAULT_INCLUDE_REGEX
    exclude_regex: str = DEFAULT_EXCLUDE_REGEX
    learned_k_path: str | None = None
    pre_adjusted_weight_path: str | None = None
    notes: str | None = None

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["legacy_unused_output_input_tile_shape"] = list(data.pop("tile_shape"))
        return data


@dataclass(frozen=True)
class KAssignmentSummary:
    mode: str
    runtime_k_count: int
    estimated_k_storage_bits: int
    estimated_k_storage_bytes: int
    target_linear_site_count: int
    target_layer_count: int
    per_layer_runtime_k_count: dict[str, int] = field(default_factory=dict)
    pre_adjusted_weight_column_count: int = 0
    offline_pre_adjustment_k_bits: int = 0
    mutates_model_weights: bool = False
    description: str = ""
    effective_k_config: dict[str, Any] = field(default_factory=dict)
    implemented_behavior: str = "metadata_only"
    approximation: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class RuntimeKProvider(Protocol):
    """Interface for learned/optimized runtime k artifacts."""

    def k_count_for_site(self, site: LinearSite, config: KAssignmentConfig) -> int:
        """Return the number of runtime k values used for one linear site."""


class PreAdjustedWeightProvider(Protocol):
    """Interface for offline columnwise pre-adjusted weights."""

    def apply_to_model(self, model: Any, config: KAssignmentConfig) -> Any:
        """Apply or attach pre-adjusted weights and return the model."""


class KAssignmentStrategy:
    """Base interface for k assignment plans.

    Strategies build metadata and can later be extended to attach kernels or
    apply pre-adjusted weights. The default project keeps the DeiT model fixed.
    """

    mode: str
    description: str

    def build_summary(self, model: Any, config: KAssignmentConfig) -> KAssignmentSummary:
        sites = discover_linear_sites(
            model,
            include_regex=config.include_regex,
            exclude_regex=config.exclude_regex,
        )
        return self.summarize_sites(sites, config)

    def apply_to_model(
        self,
        model: Any,
        config: KAssignmentConfig,
        summary: KAssignmentSummary,
    ) -> tuple[Any, KAssignmentSummary]:
        """Attach quantized kernels or pre-adjusted weights.

        The default implementation is intentionally a no-op so the reference
        backbone remains fixed until a concrete partial-sum implementation is
        injected by a strategy/provider.
        """

        return model, summary

    def summarize_sites(
        self,
        sites: list[LinearSite],
        config: KAssignmentConfig,
    ) -> KAssignmentSummary:
        raise NotImplementedError


def parse_layer_index(module_name: str) -> int | None:
    patterns = (
        r"(?:^|\.)blocks\.(\d+)(?:\.|$)",
        r"(?:^|\.)encoder\.layer\.(\d+)(?:\.|$)",
        r"(?:^|\.)layers\.(\d+)(?:\.|$)",
    )
    for pattern in patterns:
        match = re.search(pattern, module_name)
        if match:
            return int(match.group(1))
    return None


def discover_linear_sites(
    model: Any,
    *,
    include_regex: str = DEFAULT_INCLUDE_REGEX,
    exclude_regex: str = DEFAULT_EXCLUDE_REGEX,
) -> list[LinearSite]:
    try:
        import torch
    except ImportError as exc:
        raise RuntimeError("PyTorch is required to inspect model linear layers.") from exc

    include_pattern = re.compile(include_regex)
    exclude_pattern = re.compile(exclude_regex) if exclude_regex else None
    sites: list[LinearSite] = []

    for name, module in model.named_modules():
        if isinstance(module, torch.nn.Conv2d) and name == "patch_embed.proj":
            if module.groups != 1:
                raise ValueError("Patch embedding quantization only supports groups=1 Conv2d.")
            kernel_h, kernel_w = module.kernel_size
            sites.append(
                LinearSite(
                    name=name,
                    layer_index=-1,
                    in_features=int(module.in_channels * kernel_h * kernel_w),
                    out_features=int(module.out_channels),
                    kind="patch_embed_conv2d",
                )
            )
            continue

        if not isinstance(module, torch.nn.Linear):
            continue
        if exclude_pattern and exclude_pattern.search(name):
            continue
        if not include_pattern.search(name):
            continue
        layer_index = parse_layer_index(name)
        if layer_index is None:
            continue
        sites.append(
            LinearSite(
                name=name,
                layer_index=layer_index,
                in_features=int(module.in_features),
                out_features=int(module.out_features),
            )
        )

    return sites


def storage_bytes(bits: int) -> int:
    return int(math.ceil(bits / 8.0))


def per_layer_sum(sites: list[LinearSite], values: dict[str, int]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for site in sites:
        key = "patch_embed" if site.layer_index == -1 else str(site.layer_index)
        counts[key] = counts.get(key, 0) + int(values.get(site.name, 0))
    return counts


def unique_layer_count(sites: list[LinearSite]) -> int:
    return len({site.layer_index for site in sites})
