TIMM_MODEL_NAME = "deit_tiny_patch16_224.fb_in1k"
HF_MODEL_NAME = "facebook/deit-tiny-patch16-224"

MODE_BASELINE = "baseline_fp_or_reference"
MODE_FIXED_GLOBAL = "fixed_global_k"
MODE_FIXED_LAYERWISE = "fixed_layerwise_k"
MODE_HEURISTIC_TILEWISE = "heuristic_tilewise_k"
MODE_LEARNED_TILEWISE = "learned_or_optimized_tilewise_k"
MODE_LEARNED_TILEWISE_COLUMNWISE = "learned_or_optimized_tilewise_plus_columnwise_k"
MODE_LEARNED_TILEWISE_PRE_ADJUSTED = (
    "learned_or_optimized_tilewise_k_plus_columnwise_pre_adjusted_weight"
)

ALL_MODES = (
    MODE_BASELINE,
    MODE_FIXED_GLOBAL,
    MODE_FIXED_LAYERWISE,
    MODE_HEURISTIC_TILEWISE,
    MODE_LEARNED_TILEWISE,
    MODE_LEARNED_TILEWISE_COLUMNWISE,
    MODE_LEARNED_TILEWISE_PRE_ADJUSTED,
)

EXPERIMENT_PRESETS = (
    ("baseline", MODE_BASELINE),
    ("fixed_global_k", MODE_FIXED_GLOBAL),
    ("fixed_layerwise_k", MODE_FIXED_LAYERWISE),
    ("heuristic_tilewise_k", MODE_HEURISTIC_TILEWISE),
    ("tilewise_k", MODE_LEARNED_TILEWISE),
    ("tilewise_plus_columnwise_k", MODE_LEARNED_TILEWISE_COLUMNWISE),
    ("tilewise_k_plus_columnwise_pre_adjusted_weight", MODE_LEARNED_TILEWISE_PRE_ADJUSTED),
)
