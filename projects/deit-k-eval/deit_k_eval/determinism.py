from __future__ import annotations

import os
import random


def set_deterministic(seed: int) -> None:
    """Set deterministic seeds where the local backend allows it."""

    os.environ.setdefault("PYTHONHASHSEED", str(seed))
    random.seed(seed)

    try:
        import numpy as np

        np.random.seed(seed)
    except Exception:
        pass

    try:
        import torch

        torch.manual_seed(seed)
        torch.cuda.manual_seed_all(seed)
        torch.backends.cudnn.benchmark = False
        torch.backends.cudnn.deterministic = True
        torch.use_deterministic_algorithms(True, warn_only=True)
    except Exception:
        pass
