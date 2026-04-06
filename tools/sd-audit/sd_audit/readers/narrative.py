"""Narrative entry reader."""

from datetime import date
from pathlib import Path

from .base import load_plain_dated_jsonl


def load_narrative(data_dir: Path, from_date: date | None = None,
                   to_date: date | None = None) -> list[dict]:
    """Load narrative entries from .springdrift/memory/narrative/."""
    return load_plain_dated_jsonl(data_dir / "memory" / "narrative", from_date, to_date)
