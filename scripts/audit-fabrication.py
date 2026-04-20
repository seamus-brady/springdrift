#!/usr/bin/env python3
"""
audit-fabrication.py — cross-reference facts against cycle-log tool calls.

Context: Curragh (and likely any sufficiently fluent LLM agent) can produce
prose that *describes* having run an analysis without actually invoking the
analysis tool. The resulting "findings" get persisted as facts with
derivation=synthesis, contaminating future cycles that cite them.

This script lists facts written on a given date, paired with the tool
calls that actually fired in each fact's source cycle. Claims that invoke
keywords like "Pearson", "correlation", "analysis" against cycles where
the corresponding tool (e.g. analyze_affect_performance) never fired are
flagged as suspected fabrication.

Usage:
    scripts/audit-fabrication.py [--date YYYY-MM-DD] [--data-dir PATH]

Non-destructive — reads only. To remove suspected facts, use the normal
fact-supersession flow (memory_clear_key via the cognitive loop) or edit
the JSONL with care.
"""

import argparse
import json
import re
import sys
from collections import defaultdict
from datetime import date as _date
from pathlib import Path

# Claim patterns that imply a specific tool should have fired.
# When a fact's value/key hits the pattern but the cycle never called the
# paired tool, we mark it suspect.
CLAIM_PATTERNS = [
    (r"\bPearson\b|\bcorrelation[s]?\b|\br ?[\u2248=] ?[\d\-.]",
     "analyze_affect_performance",
     "claims correlation analysis"),
    (r"\bmined [a-z ]+ patterns?\b|\bpattern mining\b",
     "mine_patterns",
     "claims pattern mining"),
    (r"\bconsolidat\w+ report\b|\bconsolidation run\b",
     "write_consolidation_report",
     "claims consolidation report"),
    (r"\bdeep search\b|\bsearched \w+ archive\b",
     "deep_search",
     "claims deep-archive search"),
    (r"\baffect[- ]performance correlation\b",
     "analyze_affect_performance",
     "claims affect-performance analysis"),
]


def load_jsonl(path: Path):
    if not path.exists():
        return []
    out = []
    with path.open() as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"  ! {path.name}:{i}: JSON decode error: {e}",
                      file=sys.stderr)
    return out


def collect_tool_calls_by_cycle(cycle_log_path: Path):
    """Return {cycle_id: [tool_name, ...]} for all tool calls on the day."""
    by_cycle = defaultdict(list)
    for entry in load_jsonl(cycle_log_path):
        if entry.get("type") != "tool_call":
            continue
        cid = entry.get("cycle_id")
        name = entry.get("tool_name") or entry.get("name") or "?"
        if cid:
            by_cycle[cid].append(name)
    return dict(by_cycle)


def flag_fact(fact: dict, cycle_tools: list[str]):
    """Return (is_suspect, list_of_reasons)."""
    haystack = " ".join([
        fact.get("key", ""),
        fact.get("value", ""),
    ])
    reasons = []
    for pattern, expected_tool, desc in CLAIM_PATTERNS:
        if re.search(pattern, haystack, re.IGNORECASE):
            if expected_tool not in cycle_tools:
                reasons.append(
                    f"{desc} but {expected_tool} never fired in source cycle"
                )
    return (len(reasons) > 0, reasons)


def trunc(s: str, n: int = 120) -> str:
    if s is None:
        return ""
    s = str(s).replace("\n", " ")
    return s if len(s) <= n else s[:n - 1] + "\u2026"


def main():
    parser = argparse.ArgumentParser(
        description="Audit facts against cycle-log tool calls."
    )
    parser.add_argument(
        "--date", default=_date.today().isoformat(),
        help="Date to audit (YYYY-MM-DD, default today)"
    )
    parser.add_argument(
        "--data-dir", default=".springdrift",
        help="Path to .springdrift/ directory (default: .springdrift)"
    )
    parser.add_argument(
        "--suspect-only", action="store_true",
        help="Only print facts flagged as suspect"
    )
    args = parser.parse_args()

    data_dir = Path(args.data_dir)
    facts_path = data_dir / "memory" / "facts" / f"{args.date}-facts.jsonl"
    cycle_path = data_dir / "memory" / "cycle-log" / f"{args.date}.jsonl"

    if not facts_path.exists():
        print(f"No facts file for {args.date}: {facts_path}", file=sys.stderr)
        sys.exit(1)
    if not cycle_path.exists():
        print(f"No cycle-log for {args.date}: {cycle_path}", file=sys.stderr)
        sys.exit(1)

    tools_by_cycle = collect_tool_calls_by_cycle(cycle_path)
    facts = load_jsonl(facts_path)

    # Only consider writes (skip deletes, supersessions).
    writes = [f for f in facts if f.get("operation") == "write"]

    print(f"Audit of {args.date}")
    print(f"  Source: {facts_path}")
    print(f"  Cycle-log: {cycle_path}")
    print(f"  Facts written: {len(writes)}")
    print(f"  Cycles with tool calls: {len(tools_by_cycle)}")
    print()

    suspect_count = 0
    for fact in writes:
        cid = fact.get("cycle_id") or (
            fact.get("provenance") or {}).get("source_cycle_id", "?")
        tools = tools_by_cycle.get(cid, [])
        is_suspect, reasons = flag_fact(fact, tools)

        if args.suspect_only and not is_suspect:
            continue

        marker = "[SUSPECT]" if is_suspect else "[ok]"
        print(f"{marker} {fact.get('key', '?')}")
        print(f"    cycle: {cid[:8]}  "
              f"scope: {fact.get('scope', '?')}  "
              f"derivation: {(fact.get('provenance') or {}).get('derivation', '?')}")
        print(f"    tools fired: {', '.join(sorted(set(tools))) or '(none)'}")
        if is_suspect:
            suspect_count += 1
            for r in reasons:
                print(f"    ! {r}")
        print(f"    value: {trunc(fact.get('value'))}")
        print()

    print(f"Summary: {suspect_count} suspect, "
          f"{len(writes) - suspect_count} clean, "
          f"{len(writes)} total.")
    if suspect_count > 0:
        print()
        print("To remove a suspect fact, ask the agent to clear the key:")
        print('  memory_clear_key key="<fact_key>" reason="fabrication audit"')
        print("This preserves history (append-only log) while removing the")
        print("fact from active memory. Do NOT edit the JSONL directly.")
    sys.exit(1 if suspect_count > 0 else 0)


if __name__ == "__main__":
    main()
