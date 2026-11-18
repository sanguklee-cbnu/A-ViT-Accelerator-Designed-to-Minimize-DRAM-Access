from __future__ import annotations

from dataclasses import replace
from typing import Any

from .base import (
    KAssignmentConfig,
    KAssignmentStrategy,
    KAssignmentSummary,
    LinearSite,
    per_layer_sum,
    storage_bytes,
    unique_layer_count,
)
from .simulation import apply_quantization_plan, build_quantization_plan, columnwise_count, k_tile_count
from ..constants import (
    MODE_BASELINE,
    MODE_FIXED_GLOBAL,
    MODE_FIXED_LAYERWISE,
    MODE_HEURISTIC_TILEWISE,
    MODE_LEARNED_TILEWISE,
    MODE_LEARNED_TILEWISE_COLUMNWISE,
    MODE_LEARNED_TILEWISE_PRE_ADJUSTED,
)


def _tile_count(site: LinearSite, config: KAssignmentConfig) -> int:
    return k_tile_count(site, config)


def _columnwise_count(site: LinearSite, config: KAssignmentConfig) -> int:
    return columnwise_count(site, config)


def _summary(
    *,
    mode: str,
    sites: list[LinearSite],
    runtime_k_count: int,
    k_bits: int,
    per_site_counts: dict[str, int],
    description: str,
    pre_adjusted_weight_column_count: int = 0,
    offline_pre_adjustment_k_bits: int = 0,
    mutates_model_weights: bool = False,
) -> KAssignmentSummary:
    estimated_bits = int(runtime_k_count * k_bits)
    return KAssignmentSummary(
        mode=mode,
        runtime_k_count=int(runtime_k_count),
        estimated_k_storage_bits=estimated_bits,
        estimated_k_storage_bytes=storage_bytes(estimated_bits),
        target_linear_site_count=len(sites),
        target_layer_count=unique_layer_count(sites),
        per_layer_runtime_k_count=per_layer_sum(sites, per_site_counts),
        pre_adjusted_weight_column_count=int(pre_adjusted_weight_column_count),
        offline_pre_adjustment_k_bits=int(offline_pre_adjustment_k_bits),
        mutates_model_weights=mutates_model_weights,
        description=description,
        implemented_behavior="reference" if runtime_k_count == 0 else "metadata_only",
    )


def _summary_from_plan(summary: KAssignmentSummary, plan: Any, config: KAssignmentConfig) -> KAssignmentSummary:
    estimated_bits = int(plan.runtime_k_count * config.k_bits)
    pre_adjusted_columns = 0
    if config.mode == MODE_LEARNED_TILEWISE_PRE_ADJUSTED:
        pre_adjusted_columns = sum(
            len(site.pre_adjusted_column_k or [])
            for site in plan.sites
        )
    return replace(
        summary,
        runtime_k_count=plan.runtime_k_count,
        estimated_k_storage_bits=estimated_bits,
        estimated_k_storage_bytes=storage_bytes(estimated_bits),
        target_linear_site_count=len(plan.sites),
        target_layer_count=plan.target_layer_count,
        per_layer_runtime_k_count=plan.per_layer_runtime_k_count(),
        pre_adjusted_weight_column_count=pre_adjusted_columns,
        offline_pre_adjustment_k_bits=pre_adjusted_columns * config.k_bits,
        mutates_model_weights=config.mode == MODE_LEARNED_TILEWISE_PRE_ADJUSTED,
        effective_k_config=plan.to_effective_config(),
        implemented_behavior="k_aware_partial_sum_simulation",
        approximation=plan.approximation,
    )


class QuantizedSimulationMixin:
    def apply_to_model(
        self,
        model: Any,
        config: KAssignmentConfig,
        summary: KAssignmentSummary,
    ) -> tuple[Any, KAssignmentSummary]:
        plan = build_quantization_plan(model, config)
        model = apply_quantization_plan(model, plan)
        return model, _summary_from_plan(summary, plan, config)


class BaselineReferenceStrategy(KAssignmentStrategy):
    mode = MODE_BASELINE
    description = "No k assignment. Full-precision/reference DeiT evaluation."

    def summarize_sites(
        self,
        sites: list[LinearSite],
        config: KAssignmentConfig,
    ) -> KAssignmentSummary:
        return _summary(
            mode=self.mode,
            sites=sites,
            runtime_k_count=0,
            k_bits=config.k_bits,
            per_site_counts={site.name: 0 for site in sites},
            description=self.description,
        )


class FixedGlobalKStrategy(QuantizedSimulationMixin, KAssignmentStrategy):
    mode = MODE_FIXED_GLOBAL
    description = "One shared runtime k for all selected transformer linear sites."

    def summarize_sites(
        self,
        sites: list[LinearSite],
        config: KAssignmentConfig,
    ) -> KAssignmentSummary:
        count = 1 if sites else 0
        return _summary(
            mode=self.mode,
            sites=sites,
            runtime_k_count=count,
            k_bits=config.k_bits,
            per_site_counts={site.name: 0 for site in sites},
            description=f"{self.description} global_k={config.global_k}.",
        )


class FixedLayerwiseKStrategy(QuantizedSimulationMixin, KAssignmentStrategy):
    mode = MODE_FIXED_LAYERWISE
    description = "One runtime k per transformer block/layer."

    def summarize_sites(
        self,
        sites: list[LinearSite],
        config: KAssignmentConfig,
    ) -> KAssignmentSummary:
        layer_count = unique_layer_count(sites)
        layers = sorted({site.layer_index for site in sites})
        per_layer = {"patch_embed" if layer == -1 else str(layer): 1 for layer in layers}
        estimated_bits = int(layer_count * config.k_bits)
        return KAssignmentSummary(
            mode=self.mode,
            runtime_k_count=layer_count,
            estimated_k_storage_bits=estimated_bits,
            estimated_k_storage_bytes=storage_bytes(estimated_bits),
            target_linear_site_count=len(sites),
            target_layer_count=layer_count,
            per_layer_runtime_k_count=per_layer,
            pre_adjusted_weight_column_count=0,
            offline_pre_adjustment_k_bits=0,
            mutates_model_weights=False,
            description=self.description,
        )


class HeuristicTilewiseKStrategy(QuantizedSimulationMixin, KAssignmentStrategy):
    mode = MODE_HEURISTIC_TILEWISE
    description = (
        "One runtime k per K-dimension input-channel tile. k values are "
        "deterministically derived from target-layer weight-tile magnitudes "
        "and used in forward simulation."
    )

    def summarize_sites(
        self,
        sites: list[LinearSite],
        config: KAssignmentConfig,
    ) -> KAssignmentSummary:
        per_site = {site.name: _tile_count(site, config) for site in sites}
        return _summary(
            mode=self.mode,
            sites=sites,
            runtime_k_count=sum(per_site.values()),
            k_bits=config.k_bits,
            per_site_counts=per_site,
            description=(
                f"{self.description} patch_k_tile_size={config.patch_k_tile_size}, "
                f"fc2_k_tile_size={config.fc2_k_tile_size}."
            ),
        )


class LearnedTilewiseKStrategy(QuantizedSimulationMixin, KAssignmentStrategy):
    mode = MODE_LEARNED_TILEWISE
    description = (
        "One runtime k per K-dimension input-channel tile loaded from "
        "--learned-k-path and used in forward partial-sum simulation."
    )

    def summarize_sites(
        self,
        sites: list[LinearSite],
        config: KAssignmentConfig,
    ) -> KAssignmentSummary:
        per_site = {site.name: _tile_count(site, config) for site in sites}
        suffix = f" learned_k_path={config.learned_k_path}." if config.learned_k_path else ""
        return _summary(
            mode=self.mode,
            sites=sites,
            runtime_k_count=sum(per_site.values()),
            k_bits=config.k_bits,
            per_site_counts=per_site,
            description=(
                f"{self.description} patch_k_tile_size={config.patch_k_tile_size}, "
                f"fc2_k_tile_size={config.fc2_k_tile_size}.{suffix}"
            ),
        )


class LearnedTilewisePlusColumnwiseKStrategy(QuantizedSimulationMixin, KAssignmentStrategy):
    mode = MODE_LEARNED_TILEWISE_COLUMNWISE
    description = (
        "Runtime k includes K-dimension tilewise terms plus finer K-dimension "
        "columnwise terms, where each column is a logical weight/output column."
    )

    def summarize_sites(
        self,
        sites: list[LinearSite],
        config: KAssignmentConfig,
    ) -> KAssignmentSummary:
        tile_counts = {site.name: _tile_count(site, config) for site in sites}
        column_counts = {site.name: _columnwise_count(site, config) for site in sites}
        per_site = {site.name: tile_counts[site.name] + column_counts[site.name] for site in sites}
        return _summary(
            mode=self.mode,
            sites=sites,
            runtime_k_count=sum(per_site.values()),
            k_bits=config.k_bits,
            per_site_counts=per_site,
            description=(
                f"{self.description} patch_k_tile_size={config.patch_k_tile_size}, "
                f"fc2_k_tile_size={config.fc2_k_tile_size}."
            ),
        )


class LearnedTilewiseKPlusColumnwisePreAdjustedWeightStrategy(QuantizedSimulationMixin, KAssignmentStrategy):
    mode = MODE_LEARNED_TILEWISE_PRE_ADJUSTED
    description = (
        "Runtime k includes K-dimension tilewise terms. Columnwise factors are "
        "defined per logical weight/output column and absorbed by pre-adjusting "
        "target-layer weights before inference simulation."
    )

    def summarize_sites(
        self,
        sites: list[LinearSite],
        config: KAssignmentConfig,
    ) -> KAssignmentSummary:
        tile_counts = {site.name: _tile_count(site, config) for site in sites}
        pre_adjusted_columns = sum(_columnwise_count(site, config) for site in sites)
        offline_bits = int(pre_adjusted_columns * config.k_bits)
        suffix = (
            f" pre_adjusted_weight_path={config.pre_adjusted_weight_path}."
            if config.pre_adjusted_weight_path
            else ""
        )
        return _summary(
            mode=self.mode,
            sites=sites,
            runtime_k_count=sum(tile_counts.values()),
            k_bits=config.k_bits,
            per_site_counts=tile_counts,
            pre_adjusted_weight_column_count=pre_adjusted_columns,
            offline_pre_adjustment_k_bits=offline_bits,
            mutates_model_weights=False,
            description=(
                f"{self.description} patch_k_tile_size={config.patch_k_tile_size}, "
                f"fc2_k_tile_size={config.fc2_k_tile_size}.{suffix}"
            ),
        )
