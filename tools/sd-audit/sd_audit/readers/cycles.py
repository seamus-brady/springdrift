"""Cycle log reader."""

from datetime import date
from pathlib import Path

from .base import load_plain_dated_jsonl


def load_cycles(data_dir: Path, from_date: date | None = None,
                to_date: date | None = None) -> list[dict]:
    """Load cycle log entries from .springdrift/memory/cycle-log/."""
    return load_plain_dated_jsonl(data_dir / "memory" / "cycle-log", from_date, to_date)


def group_by_cycle(entries: list[dict]) -> dict[str, list[dict]]:
    """Group cycle log entries by cycle_id."""
    cycles: dict[str, list[dict]] = {}
    for entry in entries:
        cid = entry.get("cycle_id", "")
        if cid:
            cycles.setdefault(cid, []).append(entry)
    return cycles
