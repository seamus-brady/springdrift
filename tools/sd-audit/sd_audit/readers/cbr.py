"""CBR cases reader."""

from pathlib import Path

from .base import load_jsonl


def load_cbr_cases(data_dir: Path) -> list[dict]:
    """Load CBR cases from .springdrift/memory/cbr/cases.jsonl."""
    path = data_dir / "memory" / "cbr" / "cases.jsonl"
    return load_jsonl(path)
