"""SD Audit CLI — launch the dashboard or run analysis commands."""

import json
from datetime import date, timedelta
from pathlib import Path

import click

from .analysis.summary import compute_summary


@click.group()
@click.option("--data-dir", default=".springdrift", help="Path to .springdrift/ directory")
@click.pass_context
def main(ctx, data_dir):
    """SD Audit — Springdrift log analysis dashboard and CLI."""
    ctx.ensure_object(dict)
    ctx.obj["data_dir"] = Path(data_dir)


@main.command()
@click.option("--port", default=5001, help="Port to serve on")
@click.option("--host", default="127.0.0.1", help="Host to bind to")
@click.pass_context
def serve(ctx, port, host):
    """Launch the web dashboard."""
    from .app import create_app

    app = create_app(str(ctx.obj["data_dir"]))
    click.echo(f"SD Audit dashboard: http://{host}:{port}")
    click.echo(f"Data directory: {ctx.obj['data_dir']}")
    app.run(host=host, port=port, debug=False)


@main.command()
@click.option("--from", "from_date", default=None, help="Start date (YYYY-MM-DD)")
@click.option("--to", "to_date", default=None, help="End date (YYYY-MM-DD)")
@click.option("--json-output", is_flag=True, help="Output as JSON")
@click.pass_context
def summary(ctx, from_date, to_date, json_output):
    """Print summary statistics."""
    fd = date.fromisoformat(from_date) if from_date else date.today() - timedelta(days=30)
    td = date.fromisoformat(to_date) if to_date else date.today()

    result = compute_summary(ctx.obj["data_dir"], fd, td)

    if json_output:
        click.echo(json.dumps(result, indent=2, default=str))
        return

    dr = result["date_range"]
    click.echo(f"\nSD Audit Summary: {dr['from'] or 'no data'} to {dr['to'] or 'no data'} ({dr['days']} days)")
    click.echo("=" * 60)

    c = result["cycles"]
    click.echo(f"\nCycles:        {c['total']} ({c['user_inputs']} user inputs)")

    t = result["tokens"]
    click.echo(f"Tokens:        {t['total']:,} (in: {t['input']:,} / out: {t['output']:,})")

    tl = result["tools"]
    click.echo(f"Tool calls:    {tl['total_calls']} ({tl['failures']} failures, {tl['failure_rate']:.1%})")

    s = result["safety"]
    click.echo(f"D' evals:      {s['dprime_evaluations']} ({s['accepts']} accept / {s['modifies']} modify / {s['rejects']} reject)")

    n = result["narrative"]
    outcomes = ", ".join(f"{k}: {v}" for k, v in n["outcomes"].items())
    click.echo(f"Narrative:     {n['total_entries']} entries ({outcomes})")

    m = result["memory"]
    click.echo(f"Memory:        {m['facts']} facts, {m['cbr_cases']} CBR cases")

    cm = result["comms"]
    click.echo(f"Comms:         {cm['total_messages']} messages ({cm['outbound']} out / {cm['inbound']} in)")

    models = result["models"]
    if models:
        click.echo(f"\nModels:")
        for model, count in sorted(models.items(), key=lambda x: -x[1]):
            click.echo(f"  {model}: {count}")
    click.echo()


@main.group()
@click.pass_context
def skills(ctx):
    """Audit skills: list, decay candidates, token spend."""
    pass


@skills.command("list")
@click.option("--status", default=None, type=click.Choice(["active", "archived"]),
              help="Filter by status (default: all)")
@click.option("--json-output", is_flag=True, help="Output as JSON")
@click.pass_context
def skills_list(ctx, status, json_output):
    """List every discovered skill with usage and cost metadata."""
    from .readers.skills import discover_skills

    items = discover_skills(ctx.obj["data_dir"])
    if status:
        items = [s for s in items if s.get("status") == status]

    if json_output:
        click.echo(json.dumps(items, indent=2, default=str))
        return

    if not items:
        click.echo("No skills found.")
        return

    click.echo(f"\n{len(items)} skill(s):")
    click.echo("=" * 78)
    click.echo(f"{'NAME':<30} {'STATUS':<10} {'V':<3} {'READS':<6} {'TOKENS':<8} LAST USED")
    click.echo("-" * 78)
    for s in items:
        name = (s.get("name") or s.get("id") or "?")[:29]
        st = s.get("status", "active")[:9]
        ver = str(s.get("version", 1))[:2]
        reads = s.get("reads", 0)
        tokens = s.get("token_cost_estimate", 0)
        last = (s.get("last_used") or "—")[:19].replace("T", " ")
        click.echo(f"{name:<30} {st:<10} {ver:<3} {reads:<6} {tokens:<8} {last}")
    click.echo()


@skills.command("decay-candidates")
@click.option("--top", default=10, help="Show top N candidates")
@click.option("--json-output", is_flag=True, help="Output as JSON")
@click.pass_context
def skills_decay(ctx, top, json_output):
    """Recommend skills for archival, scored by usage + cost + staleness."""
    from .readers.skills import decay_priority, discover_skills

    items = [s for s in discover_skills(ctx.obj["data_dir"])
             if s.get("status") == "active"]
    scored = sorted(
        ((decay_priority(s), s) for s in items),
        key=lambda pair: pair[0],
        reverse=True,
    )[:top]

    if json_output:
        click.echo(json.dumps(
            [{"score": round(score, 3), "skill": skill} for score, skill in scored],
            indent=2,
            default=str,
        ))
        return

    if not scored:
        click.echo("No active skills to evaluate.")
        return

    click.echo(f"\nTop {len(scored)} archival candidates (higher score = more decayed):")
    click.echo("=" * 78)
    click.echo(f"{'SCORE':<7} {'NAME':<30} {'READS':<6} {'TOKENS':<8} LAST USED")
    click.echo("-" * 78)
    for score, s in scored:
        name = (s.get("name") or s.get("id") or "?")[:29]
        reads = s.get("reads", 0)
        tokens = s.get("token_cost_estimate", 0)
        last = (s.get("last_used") or "never")[:19].replace("T", " ")
        click.echo(f"{score:<7.3f} {name:<30} {reads:<6} {tokens:<8} {last}")
    click.echo()


@skills.command("tokens")
@click.option("--json-output", is_flag=True, help="Output as JSON")
@click.pass_context
def skills_tokens(ctx, json_output):
    """Show total token spend across all active skills."""
    from .readers.skills import discover_skills

    items = [s for s in discover_skills(ctx.obj["data_dir"])
             if s.get("status") == "active"]
    total_tokens = sum(s.get("token_cost_estimate", 0) for s in items)
    total_injects = sum(s.get("injects", 0) for s in items)
    total_burned = total_tokens * total_injects if total_injects else 0

    result = {
        "active_skill_count": len(items),
        "total_tokens_per_inject": total_tokens,
        "total_injects": total_injects,
        "total_tokens_burned": total_burned,
    }

    if json_output:
        click.echo(json.dumps(result, indent=2))
        return

    click.echo(f"\nActive skills:        {result['active_skill_count']}")
    click.echo(f"Tokens per inject:    {result['total_tokens_per_inject']:,}")
    click.echo(f"Total injects:        {result['total_injects']:,}")
    click.echo(f"Total tokens burned:  {result['total_tokens_burned']:,}")
    click.echo()


if __name__ == "__main__":
    main()
