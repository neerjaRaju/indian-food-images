from __future__ import annotations

import logging
import os
import sys

_CONFIGURED = False


def setup(level: str | None = None) -> None:
    global _CONFIGURED
    if _CONFIGURED:
        return
    lvl = (level or os.environ.get("IFCA_LOG_LEVEL", "INFO")).upper()
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        logging.Formatter("%(asctime)s  %(levelname)-7s %(name)-22s %(message)s", "%H:%M:%S")
    )
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(lvl)
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("requests").setLevel(logging.WARNING)
    _CONFIGURED = True


def get(name: str) -> logging.Logger:
    setup()
    return logging.getLogger(name)
