"""SD Audit — Flask web dashboard for Springdrift log analysis."""

import json
from datetime import date, timedelta
from pathlib import Path

from flask import Flask, render_template, request, jsonify

from .analysis.summary import compute_summary
from .analysis.timeline import daily_activity, dprime_timeline, token_timeline
from .readers.narrative import load_narrative
from .readers.comms import load_comms

app = Flask(__name__)
app.config["DATA_DIR"] = Path(".springdrift")


def get_data_dir() -> Path:
    return Path(app.config["DATA_DIR"])


def get_date_range():
    """Parse from/to query params, defaulting to last 30 days."""
    to_str = request.args.get("to")
    from_str = request.args.get("from")
    to_date = date.fromisoformat(to_str) if to_str else date.today()
    from_date = date.fromisoformat(from_str) if from_str else to_date - timedelta(days=30)
    return from_date, to_date


@app.route("/")
def index():
    from_date, to_date = get_date_range()
    summary = compute_summary(get_data_dir(), from_date, to_date)
    return render_template("index.html", summary=summary, from_date=from_date, to_date=to_date)


@app.route("/api/summary")
def api_summary():
    from_date, to_date = get_date_range()
    return jsonify(compute_summary(get_data_dir(), from_date, to_date))


@app.route("/api/daily-activity")
def api_daily_activity():
    from_date, to_date = get_date_range()
    return jsonify(daily_activity(get_data_dir(), from_date, to_date))


@app.route("/api/dprime-timeline")
def api_dprime_timeline():
    from_date, to_date = get_date_range()
    return jsonify(dprime_timeline(get_data_dir(), from_date, to_date))


@app.route("/api/token-timeline")
def api_token_timeline():
    from_date, to_date = get_date_range()
    return jsonify(token_timeline(get_data_dir(), from_date, to_date))


@app.route("/api/narrative")
def api_narrative():
    from_date, to_date = get_date_range()
    entries = load_narrative(get_data_dir(), from_date, to_date)
    # Return summary view, not full entries
    return jsonify([
        {
            "cycle_id": e.get("cycle_id", "")[:8],
            "timestamp": e.get("timestamp", ""),
            "summary": (e.get("summary", "") or "")[:200],
            "outcome": e.get("outcome", {}).get("status", "unknown"),
            "domain": e.get("intent", {}).get("domain", ""),
            "tokens_in": e.get("metrics", {}).get("input_tokens", 0),
            "tokens_out": e.get("metrics", {}).get("output_tokens", 0),
        }
        for e in entries
    ])


@app.route("/api/comms")
def api_comms():
    from_date, to_date = get_date_range()
    messages = load_comms(get_data_dir(), from_date, to_date)
    # Deduplicate by message_id
    seen = set()
    deduped = []
    for m in messages:
        mid = m.get("message_id", "")
        if mid not in seen:
            seen.add(mid)
            deduped.append(m)
    return jsonify(deduped)


def create_app(data_dir: str = ".springdrift") -> Flask:
    """Factory function for creating the Flask app."""
    app.config["DATA_DIR"] = Path(data_dir)
    return app
