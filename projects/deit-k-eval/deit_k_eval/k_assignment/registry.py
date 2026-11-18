from __future__ import annotations

from .base import KAssignmentStrategy
from .schemes import (
    BaselineReferenceStrategy,
    FixedGlobalKStrategy,
    FixedLayerwiseKStrategy,
    HeuristicTilewiseKStrategy,
    LearnedTilewiseKPlusColumnwisePreAdjustedWeightStrategy,
    LearnedTilewiseKStrategy,
    LearnedTilewisePlusColumnwiseKStrategy,
)
from ..constants import (
    ALL_MODES,
    MODE_BASELINE,
    MODE_FIXED_GLOBAL,
    MODE_FIXED_LAYERWISE,
    MODE_HEURISTIC_TILEWISE,
    MODE_LEARNED_TILEWISE,
    MODE_LEARNED_TILEWISE_COLUMNWISE,
    MODE_LEARNED_TILEWISE_PRE_ADJUSTED,
)


_STRATEGIES = {
    MODE_BASELINE: BaselineReferenceStrategy,
    MODE_FIXED_GLOBAL: FixedGlobalKStrategy,
    MODE_FIXED_LAYERWISE: FixedLayerwiseKStrategy,
    MODE_HEURISTIC_TILEWISE: HeuristicTilewiseKStrategy,
    MODE_LEARNED_TILEWISE: LearnedTilewiseKStrategy,
    MODE_LEARNED_TILEWISE_COLUMNWISE: LearnedTilewisePlusColumnwiseKStrategy,
    MODE_LEARNED_TILEWISE_PRE_ADJUSTED: LearnedTilewiseKPlusColumnwisePreAdjustedWeightStrategy,
}


def build_strategy(mode: str) -> KAssignmentStrategy:
    try:
        return _STRATEGIES[mode]()
    except KeyError as exc:
        raise ValueError(f"Unknown k-assignment mode {mode!r}. Valid modes: {', '.join(ALL_MODES)}") from exc
