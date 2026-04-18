"""Skills reader — discovers skills on disk, loads metrics + proposal log."""

from __future__ import annotations

import re
import tomllib
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional

from .base import load_dated_jsonl, load_jsonl


def discover_skills(data_dir: Path) -> list[dict]:
    """Walk `.springdrift/skills/<id>/` directories, returning a dict per
    skill. Each dict carries the merged frontmatter+sidecar metadata plus
    derived metrics from `skill.metrics.jsonl`.
    """
    skills_root = data_dir / "skills"
    if not skills_root.exists() or not skills_root.is_dir():
        return []

    skills: list[dict] = []
    for entry in sorted(skills_root.iterdir()):
        if not entry.is_dir():
            continue
        skill_md = entry / "SKILL.md"
        if not skill_md.exists():
            continue

        meta = _parse_frontmatter(skill_md.read_text(encoding="utf-8", errors="replace"))
        toml_path = entry / "skill.toml"
        if toml_path.exists():
            try:
                meta.update(_load_skill_toml(toml_path))
            except (tomllib.TOMLDecodeError, OSError):
                # Frontmatter still applies; just log nothing extra.
                pass

        body = _strip_frontmatter(skill_md.read_text(encoding="utf-8", errors="replace"))
        meta.setdefault("id", entry.name)
        meta["dir"] = str(entry)
        meta["body_length"] = len(body)
        meta["token_cost_estimate"] = meta.get("token_cost_estimate") or _estimate_tokens(body)
        meta["status"] = (meta.get("status") or "active").lower()

        metrics = _read_metrics(entry / "skill.metrics.jsonl")
        meta.update(metrics)
        skills.append(meta)
    return skills


def load_skills_log(data_dir: Path, from_date: Optional[date] = None,
                    to_date: Optional[date] = None) -> list[dict]:
    """Load skills proposal-log events from
    `.springdrift/memory/skills/YYYY-MM-DD-skills.jsonl` files.
    """
    return load_dated_jsonl(data_dir / "memory" / "skills", "skills",
                            from_date=from_date, to_date=to_date)


def decay_priority(skill: dict, today: Optional[date] = None) -> float:
    """Score a skill on archival priority. Higher = better candidate for
    archival. Combines low usage, high token cost, and staleness.

    Per the spec:
        decay_priority =
            (1.0 - normalised_usage) * 0.5
          + (token_cost / 1000.0) * 0.3
          + days_since_last_used * 0.2

    `normalised_usage` is `min(reads / 10, 1.0)` — caps so a skill with
    100 reads doesn't dominate the score.
    """
    reads = skill.get("reads", 0) or 0
    tokens = skill.get("token_cost_estimate", 0) or 0
    last_used = skill.get("last_used")
    today = today or date.today()

    normalised_usage = min(reads / 10.0, 1.0)
    days_since = _days_since(last_used, today)

    return (
        (1.0 - normalised_usage) * 0.5
        + (tokens / 1000.0) * 0.3
        + (days_since / 30.0) * 0.2
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


_FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---", re.DOTALL)


def _parse_frontmatter(content: str) -> dict:
    """Lenient YAML-frontmatter parse: name/description/agents only.
    Mirrors the Gleam parser's behaviour."""
    match = _FRONTMATTER_RE.match(content)
    if not match:
        return {}
    out: dict = {}
    for line in match.group(1).splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if key == "agents":
            out["agents"] = [a.strip() for a in value.split(",") if a.strip()]
        else:
            out[key] = value
    return out


def _strip_frontmatter(content: str) -> str:
    return _FRONTMATTER_RE.sub("", content, count=1).lstrip()


def _load_skill_toml(path: Path) -> dict:
    with open(path, "rb") as f:
        toml = tomllib.load(f)
    out: dict = {}
    for key in ("id", "name", "description", "version", "status"):
        if key in toml:
            out[key] = toml[key]
    scoping = toml.get("scoping", {})
    if "agents" in scoping:
        out["agents"] = scoping["agents"]
    if "contexts" in scoping:
        out["contexts"] = scoping["contexts"]
    provenance = toml.get("provenance", {})
    if "author" in provenance:
        if provenance["author"] == "agent":
            out["author"] = f"agent:{provenance.get('agent_name', 'unknown')}"
        else:
            out["author"] = provenance["author"]
    if "created_at" in provenance:
        out["created_at"] = provenance["created_at"]
    if "updated_at" in provenance:
        out["updated_at"] = provenance["updated_at"]
    if "derived_from" in provenance:
        out["derived_from"] = provenance["derived_from"]
    return out


def _read_metrics(path: Path) -> dict:
    events = load_jsonl(path)
    reads = 0
    injects = 0
    last_event_ts: Optional[str] = None
    for entry in events:
        kind = entry.get("event")
        if kind == "read":
            reads += 1
        elif kind == "inject":
            injects += 1
        ts = entry.get("timestamp")
        if ts:
            last_event_ts = ts
    return {"reads": reads, "injects": injects, "last_used": last_event_ts}


def _estimate_tokens(body: str) -> int:
    """Rough chars/token approximation matching the Gleam side."""
    return len(body) // 4


def _days_since(ts: Optional[str], today: date) -> int:
    if not ts:
        return 365  # never used → very stale
    try:
        # Accept either "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM:SS..." or with Z
        ts_clean = ts.rstrip("Z").split(".")[0]
        last = datetime.fromisoformat(ts_clean).date()
    except ValueError:
        return 365
    delta: timedelta = today - last
    return max(delta.days, 0)
