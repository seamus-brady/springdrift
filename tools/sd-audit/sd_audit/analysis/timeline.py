"""Timeline analysis — chronological event reconstruction for charts."""

from datetime import date
from pathlib import Path

from ..readers.narrative import load_narrative
from ..readers.cycles import load_cycles


def daily_activity(data_dir: Path, from_date: date | None = None,
                   to_date: date | None = None) -> list[dict]:
    """Compute daily activity metrics for chart display."""
    narrative = load_narrative(data_dir, from_date, to_date)

    # Group by date
    by_date: dict[str, dict] = {}
    for entry in narrative:
        ts = entry.get("timestamp", "")[:10]
        if not ts:
            continue
        if ts not in by_date:
            by_date[ts] = {
                "date": ts,
                "total": 0,
                "success": 0,
                "partial": 0,
                "failure": 0,
                "tokens_in": 0,
                "tokens_out": 0,
            }
        day = by_date[ts]
        day["total"] += 1
        status = entry.get("outcome", {}).get("status", "unknown")
        if status in day:
            day[status] += 1
        metrics = entry.get("metrics", {})
        day["tokens_in"] += metrics.get("input_tokens", 0)
        day["tokens_out"] += metrics.get("output_tokens", 0)

    return sorted(by_date.values(), key=lambda d: d["date"])


def dprime_timeline(data_dir: Path, from_date: date | None = None,
                    to_date: date | None = None) -> list[dict]:
    """Extract D' gate decisions with timestamps for chart display."""
    cycle_entries = load_cycles(data_dir, from_date, to_date)
    events = []
    for entry in cycle_entries:
        if entry.get("type") == "dprime_layer":
            events.append({
                "timestamp": entry.get("timestamp", ""),
                "cycle_id": entry.get("cycle_id", "")[:8],
                "layer": entry.get("layer", ""),
                "decision": entry.get("decision", ""),
                "score": entry.get("score", 0),
            })
    return events


def token_timeline(data_dir: Path, from_date: date | None = None,
                   to_date: date | None = None) -> list[dict]:
    """Daily token usage for cost trend chart."""
    activity = daily_activity(data_dir, from_date, to_date)
    return [
        {
            "date": day["date"],
            "tokens": day["tokens_in"] + day["tokens_out"],
            "input": day["tokens_in"],
            "output": day["tokens_out"],
        }
        for day in activity
    ]
