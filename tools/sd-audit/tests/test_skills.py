"""Tests for the skills reader and the decay-priority recommender."""

from datetime import date, timedelta
from pathlib import Path

import pytest

from sd_audit.readers.skills import (
    decay_priority,
    discover_skills,
    load_skills_log,
)


@pytest.fixture
def data_dir(tmp_path: Path) -> Path:
    """Build a fake .springdrift/ tree with one operator skill, one
    auto-promoted skill, and a per-day skills log."""
    # Operator skill
    op_dir = tmp_path / "skills" / "web-research"
    op_dir.mkdir(parents=True)
    (op_dir / "SKILL.md").write_text(
        "---\nname: web-research\ndescription: Search strategy\nagents: researcher\n---\n\n"
        "Use brave_answer first.\n"
    )
    # No skill.toml — frontmatter-only skill should still parse.
    # Metrics with two reads + one inject.
    (op_dir / "skill.metrics.jsonl").write_text(
        '{"timestamp":"2026-04-18T10:00:00","cycle_id":"c1","event":"read","agent":"researcher"}\n'
        '{"timestamp":"2026-04-18T10:01:00","cycle_id":"c1","event":"inject","agent":"researcher"}\n'
        '{"timestamp":"2026-04-18T11:00:00","cycle_id":"c2","event":"read","agent":"researcher"}\n'
    )

    # Auto-promoted skill with skill.toml
    auto_dir = tmp_path / "skills" / "search-tool-selection"
    auto_dir.mkdir(parents=True)
    (auto_dir / "SKILL.md").write_text(
        "---\nname: search-tool-selection\ndescription: When to use which search tool\n---\n\n"
        "Auto-derived body.\n"
    )
    (auto_dir / "skill.toml").write_text(
        'id = "search-tool-selection"\n'
        'name = "Search Tool Selection"\n'
        'description = "Auto-derived"\n'
        'version = 2\n'
        'status = "active"\n\n'
        "[scoping]\n"
        'agents = ["researcher", "cognitive"]\n'
        'contexts = ["research"]\n\n'
        "[provenance]\n"
        'author = "agent"\n'
        'agent_name = "remembrancer"\n'
        'cycle_id = "abc-123"\n'
    )
    # No metrics file → reads/injects/last_used should be zero/None.

    # Per-day skills log
    log_dir = tmp_path / "memory" / "skills"
    log_dir.mkdir(parents=True)
    today = date.today().isoformat()
    (log_dir / f"{today}-skills.jsonl").write_text(
        '{"event":"proposed","timestamp":"2026-04-18T09:00:00",'
        '"proposal":{"proposal_id":"p1","name":"Test","description":"d",'
        '"body":"b","agents":["researcher"],"contexts":["research"],'
        '"source_cases":["c1"],"confidence":0.85,"proposed_by":"remembrancer",'
        '"proposed_at":"2026-04-18T09:00:00","conflict":{"kind":"unknown"}}}\n'
        '{"event":"created","timestamp":"2026-04-18T09:00:01",'
        '"proposal_id":"p1","skill_id":"p1","skill_path":"/x"}\n'
    )
    return tmp_path


def test_discover_finds_both_skills(data_dir: Path):
    skills = discover_skills(data_dir)
    assert len(skills) == 2
    names = {s["name"] for s in skills}
    assert names == {"web-research", "Search Tool Selection"}


def test_frontmatter_only_skill_parses_metrics(data_dir: Path):
    skills = discover_skills(data_dir)
    web = next(s for s in skills if s["name"] == "web-research")
    assert web["reads"] == 2
    assert web["injects"] == 1
    assert web["last_used"] is not None
    # Body is "Use brave_answer first.\n" → 23 chars / 4 = 5
    assert web["token_cost_estimate"] >= 5


def test_skill_toml_overrides_frontmatter(data_dir: Path):
    skills = discover_skills(data_dir)
    auto = next(s for s in skills if s["id"] == "search-tool-selection")
    assert auto["version"] == 2
    assert auto["status"] == "active"
    assert auto["author"] == "agent:remembrancer"
    assert auto["agents"] == ["researcher", "cognitive"]
    assert auto["contexts"] == ["research"]
    # No metrics file → reads default to 0
    assert auto["reads"] == 0
    assert auto["last_used"] is None


def test_load_skills_log_returns_today_events(data_dir: Path):
    events = load_skills_log(data_dir)
    assert len(events) == 2
    kinds = [e.get("event") for e in events]
    assert kinds == ["proposed", "created"]


def test_decay_priority_higher_for_unused_stale_skill():
    # An old, untouched skill should score higher than a freshly-used one.
    today = date.today()
    fresh = {
        "reads": 50,
        "token_cost_estimate": 200,
        "last_used": today.isoformat() + "T10:00:00",
    }
    stale = {
        "reads": 0,
        "token_cost_estimate": 800,
        "last_used": (today - timedelta(days=60)).isoformat() + "T10:00:00",
    }
    assert decay_priority(stale) > decay_priority(fresh)


def test_decay_priority_handles_missing_last_used():
    skill = {"reads": 0, "token_cost_estimate": 100, "last_used": None}
    score = decay_priority(skill)
    # Never-used skills get the maximum staleness penalty (365 days).
    assert score > 0.5
