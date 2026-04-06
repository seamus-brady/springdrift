"""Summary analysis — aggregate statistics from all log sources."""

from datetime import date
from pathlib import Path

from ..readers.narrative import load_narrative
from ..readers.cycles import load_cycles, group_by_cycle
from ..readers.facts import load_facts
from ..readers.cbr import load_cbr_cases
from ..readers.comms import load_comms


def compute_summary(data_dir: Path, from_date: date | None = None,
                    to_date: date | None = None) -> dict:
    """Compute aggregate summary statistics."""
    narrative = load_narrative(data_dir, from_date, to_date)
    cycle_entries = load_cycles(data_dir, from_date, to_date)
    facts = load_facts(data_dir, from_date, to_date)
    cbr_cases = load_cbr_cases(data_dir)
    comms = load_comms(data_dir, from_date, to_date)

    # Cycle analysis
    cycles_by_id = group_by_cycle(cycle_entries)
    human_inputs = [e for e in cycle_entries if e.get("type") == "human_input"]
    tool_calls = [e for e in cycle_entries if e.get("type") == "tool_call"]
    tool_results = [e for e in cycle_entries if e.get("type") == "tool_result"]
    llm_responses = [e for e in cycle_entries if e.get("type") == "llm_response"]

    tool_failures = [r for r in tool_results if not r.get("success", True)]

    # Token totals
    total_in = sum(r.get("input_tokens", 0) or r.get("tokens", {}).get("input", 0)
                   for r in llm_responses)
    total_out = sum(r.get("output_tokens", 0) or r.get("tokens", {}).get("output", 0)
                    for r in llm_responses)

    # D' events
    dprime_layers = [e for e in cycle_entries if e.get("type") == "dprime_layer"]
    dprime_accepts = [e for e in dprime_layers if e.get("decision") == "accept"]
    dprime_modifies = [e for e in dprime_layers if e.get("decision") == "modify"]
    dprime_rejects = [e for e in dprime_layers if e.get("decision") == "reject"]

    # Narrative outcomes
    outcomes = {}
    for entry in narrative:
        status = entry.get("outcome", {}).get("status", "unknown")
        outcomes[status] = outcomes.get(status, 0) + 1

    # Model usage
    models = {}
    for r in llm_responses:
        model = r.get("model", "unknown")
        models[model] = models.get(model, 0) + 1

    # Date range
    dates = set()
    for entry in narrative:
        ts = entry.get("timestamp", "")[:10]
        if ts:
            dates.add(ts)

    return {
        "date_range": {
            "from": min(dates) if dates else None,
            "to": max(dates) if dates else None,
            "days": len(dates),
        },
        "cycles": {
            "total": len(cycles_by_id),
            "user_inputs": len(human_inputs),
        },
        "tokens": {
            "total": total_in + total_out,
            "input": total_in,
            "output": total_out,
        },
        "tools": {
            "total_calls": len(tool_calls),
            "failures": len(tool_failures),
            "failure_rate": len(tool_failures) / max(len(tool_calls), 1),
        },
        "safety": {
            "dprime_evaluations": len(dprime_layers),
            "accepts": len(dprime_accepts),
            "modifies": len(dprime_modifies),
            "rejects": len(dprime_rejects),
        },
        "narrative": {
            "total_entries": len(narrative),
            "outcomes": outcomes,
        },
        "memory": {
            "facts": len(facts),
            "cbr_cases": len(cbr_cases),
        },
        "comms": {
            "total_messages": len(comms),
            "outbound": len([m for m in comms if m.get("direction") == "outbound"]),
            "inbound": len([m for m in comms if m.get("direction") == "inbound"]),
        },
        "models": models,
    }
