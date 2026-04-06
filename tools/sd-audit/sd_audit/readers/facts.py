"""Facts reader."""

from datetime import date
from pathlib import Path

from .base import load_dated_jsonl


def load_facts(data_dir: Path, from_date: date | None = None,
               to_date: date | None = None) -> list[dict]:
    """Load fact operations from .springdrift/memory/facts/."""
    return load_dated_jsonl(data_dir / "memory" / "facts", "facts", from_date, to_date)
