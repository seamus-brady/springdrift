"""Comms log reader."""

from datetime import date
from pathlib import Path

from .base import load_dated_jsonl


def load_comms(data_dir: Path, from_date: date | None = None,
               to_date: date | None = None) -> list[dict]:
    """Load comms messages from .springdrift/memory/comms/."""
    return load_dated_jsonl(data_dir / "memory" / "comms", "comms", from_date, to_date)
