"""Base JSONL reader — lenient parsing, date-range filtering."""

import json
from datetime import date, datetime
from pathlib import Path


def load_jsonl(path: Path) -> list[dict]:
    """Load a JSONL file, skipping malformed lines."""
    if not path.exists():
        return []
    entries = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return entries


def load_dated_jsonl(directory: Path, suffix: str, from_date: date | None = None,
                     to_date: date | None = None) -> list[dict]:
    """Load all YYYY-MM-DD-{suffix}.jsonl files in a directory within a date range."""
    if not directory.exists():
        return []
    entries = []
    for path in sorted(directory.glob(f"*-{suffix}.jsonl")):
        file_date = extract_date_from_filename(path.name)
        if file_date:
            if from_date and file_date < from_date:
                continue
            if to_date and file_date > to_date:
                continue
        entries.extend(load_jsonl(path))
    return entries


def load_plain_dated_jsonl(directory: Path, from_date: date | None = None,
                           to_date: date | None = None) -> list[dict]:
    """Load all YYYY-MM-DD.jsonl files (no suffix) in a directory within a date range."""
    if not directory.exists():
        return []
    entries = []
    for path in sorted(directory.glob("????-??-??.jsonl")):
        file_date = extract_date_from_filename(path.name)
        if file_date:
            if from_date and file_date < from_date:
                continue
            if to_date and file_date > to_date:
                continue
        entries.extend(load_jsonl(path))
    return entries


def extract_date_from_filename(name: str) -> date | None:
    """Extract YYYY-MM-DD from a filename like '2026-03-28-narrative.jsonl' or '2026-03-28.jsonl'."""
    parts = name.split("-")
    if len(parts) >= 3:
        try:
            return date(int(parts[0]), int(parts[1]), int(parts[2]))
        except (ValueError, IndexError):
            return None
    return None


def parse_timestamp(ts: str | None) -> datetime | None:
    """Parse an ISO timestamp, lenient."""
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
