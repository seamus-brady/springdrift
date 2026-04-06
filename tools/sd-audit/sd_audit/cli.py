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


if __name__ == "__main__":
    main()
