#!/usr/bin/env python3
"""Redact Springdrift operational logs for publication.

Reads from .springdrift/memory/ and produces redacted versions
in evals/operational-logs/ suitable for inclusion in a public repo.

Preserves: timestamps, cycle IDs, outcome status, metrics, tool names,
D' decisions/scores, model names, domains, keywords, intent classification.

Redacts: human input text, LLM response text, summary text, entity names,
email addresses, fact values, CBR solution details.
"""

import json
import re
import sys
from pathlib import Path

# Patterns to redact
EMAIL_RE = re.compile(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')
NAME_RE = re.compile(r'\b(Seamus|Brady|Curragh)\b', re.IGNORECASE)


def redact_text(text: str) -> str:
    """Replace personal content with [REDACTED]."""
    if not text:
        return text
    text = EMAIL_RE.sub('[EMAIL]', text)
    text = NAME_RE.sub('[NAME]', text)
    # Truncate to first 50 chars + indicator
    if len(text) > 80:
        return text[:50] + '... [TRUNCATED]'
    return text


def redact_narrative_entry(entry: dict) -> dict:
    """Redact a narrative entry, preserving structure and metrics."""
    return {
        'schema_version': entry.get('schema_version'),
        'cycle_id': entry.get('cycle_id'),
        'parent_cycle_id': entry.get('parent_cycle_id'),
        'timestamp': entry.get('timestamp'),
        'entry_type': entry.get('entry_type'),
        'summary': '[REDACTED]',
        'intent': {
            'classification': entry.get('intent', {}).get('classification'),
            'description': '[REDACTED]',
            'domain': entry.get('intent', {}).get('domain'),
        },
        'outcome': {
            'status': entry.get('outcome', {}).get('status'),
            'confidence': entry.get('outcome', {}).get('confidence'),
            'assessment': redact_text(entry.get('outcome', {}).get('assessment', '')),
        },
        'delegation_chain': [
            {
                'agent': d.get('agent'),
                'tools_used': d.get('tools_used'),
                'outcome': d.get('outcome'),
            }
            for d in entry.get('delegation_chain', [])
        ],
        'keywords': [redact_text(k) for k in entry.get('keywords', [])],
        'topics': entry.get('topics', []),
        'entities': {
            'locations': entry.get('entities', {}).get('locations', []),
            'organisations': ['[REDACTED]' for _ in entry.get('entities', {}).get('organisations', [])],
            'data_points': [
                {
                    'label': dp.get('label', ''),
                    'value': '[REDACTED]' if any(
                        pat.search(str(dp.get('value', '')))
                        for pat in [EMAIL_RE, NAME_RE]
                    ) else dp.get('value', ''),
                    'unit': dp.get('unit', ''),
                }
                for dp in entry.get('entities', {}).get('data_points', [])
            ],
            'temporal_references': entry.get('entities', {}).get('temporal_references', []),
        },
        'sources': [
            {'type': s.get('type'), 'url': '[REDACTED]'}
            for s in entry.get('sources', [])
        ],
        'thread': entry.get('thread'),
        'metrics': entry.get('metrics'),  # tokens, tool_calls, agent_delegations — all kept
        'redacted': True,
    }


def redact_cycle_entry(entry: dict) -> dict | None:
    """Redact a cycle log entry, preserving telemetry."""
    entry_type = entry.get('type', '')

    if entry_type == 'human_input':
        return {
            'type': 'human_input',
            'cycle_id': entry.get('cycle_id'),
            'parent_cycle_id': entry.get('parent_cycle_id'),
            'timestamp': entry.get('timestamp'),
            'text': '[REDACTED]',
            'text_length': len(entry.get('text', '')),
        }

    if entry_type == 'llm_request':
        return {
            'type': 'llm_request',
            'cycle_id': entry.get('cycle_id'),
            'timestamp': entry.get('timestamp'),
            'model': entry.get('model'),
            'max_tokens': entry.get('max_tokens'),
            'system_hash': entry.get('system_hash', '[NOT RECORDED]'),
            'tool_count': len(entry.get('tools', [])),
            'message_count': len(entry.get('messages', [])),
        }

    if entry_type == 'llm_response':
        return {
            'type': 'llm_response',
            'cycle_id': entry.get('cycle_id'),
            'timestamp': entry.get('timestamp'),
            'model': entry.get('model'),
            'stop_reason': entry.get('stop_reason'),
            'input_tokens': entry.get('input_tokens', entry.get('tokens', {}).get('input', 0)),
            'output_tokens': entry.get('output_tokens', entry.get('tokens', {}).get('output', 0)),
            'content': '[REDACTED]',
        }

    if entry_type == 'llm_error':
        return {
            'type': 'llm_error',
            'cycle_id': entry.get('cycle_id'),
            'timestamp': entry.get('timestamp'),
            'error': redact_text(entry.get('error', '')),
        }

    if entry_type == 'tool_call':
        return {
            'type': 'tool_call',
            'cycle_id': entry.get('cycle_id'),
            'timestamp': entry.get('timestamp'),
            'tool_use_id': entry.get('tool_use_id'),
            'name': entry.get('name'),
            'input': '[REDACTED]',
        }

    if entry_type == 'tool_result':
        return {
            'type': 'tool_result',
            'cycle_id': entry.get('cycle_id'),
            'timestamp': entry.get('timestamp'),
            'tool_use_id': entry.get('tool_use_id'),
            'success': entry.get('success'),
            'content': '[REDACTED]',
            'content_length': len(entry.get('content', '')),
        }

    if entry_type == 'classification':
        return entry  # no personal data

    if entry_type in ('dprime_layer', 'dprime_canary', 'dprime_evaluation',
                       'dprime_input_evaluation', 'dprime_audit',
                       'dprime_scorer_fallback', 'dprime_meta_stall'):
        # D' entries — keep scores and decisions, redact text fields
        result = dict(entry)
        if 'explanation' in result:
            result['explanation'] = redact_text(result['explanation'])
        # Forecasts may contain personal data in rationale
        if 'forecasts' in result and isinstance(result['forecasts'], list):
            result['forecasts'] = [
                {
                    'feature': f.get('feature'),
                    'magnitude': f.get('magnitude'),
                    'rationale': '[REDACTED]',
                }
                for f in result['forecasts']
            ]
        return result

    # Unknown type — include type and cycle_id only
    return {
        'type': entry_type,
        'cycle_id': entry.get('cycle_id'),
        'timestamp': entry.get('timestamp'),
        'redacted': True,
    }


def process_directory(src_dir: Path, dst_dir: Path, processor, suffix: str = None):
    """Process all JSONL files in a directory."""
    if not src_dir.exists():
        print(f"  Skipping {src_dir} (not found)")
        return

    dst_dir.mkdir(parents=True, exist_ok=True)
    count = 0

    for path in sorted(src_dir.glob('*.jsonl')):
        entries = []
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    result = processor(entry)
                    if result is not None:
                        entries.append(result)
                        count += 1
                except json.JSONDecodeError:
                    continue

        if entries:
            dst_path = dst_dir / path.name
            with open(dst_path, 'w') as f:
                for entry in entries:
                    f.write(json.dumps(entry, separators=(',', ':')) + '\n')

    print(f"  {src_dir.name}: {count} entries")


def main():
    data_dir = Path('.springdrift')
    output_dir = Path('evals/operational-logs')

    if not data_dir.exists():
        print("Error: .springdrift/ not found. Run from repo root.")
        sys.exit(1)

    print("Redacting operational logs...")
    print(f"  Source: {data_dir}")
    print(f"  Output: {output_dir}")
    print()

    # Narrative
    process_directory(
        data_dir / 'memory' / 'narrative',
        output_dir / 'narrative',
        redact_narrative_entry,
    )

    # Cycle logs
    process_directory(
        data_dir / 'memory' / 'cycle-log',
        output_dir / 'cycle-log',
        redact_cycle_entry,
    )

    # Write manifest
    manifest = {
        'description': 'Redacted operational logs from Springdrift instance "Curragh"',
        'period': '2026-03-07 to 2026-03-29',
        'redaction_policy': {
            'preserved': [
                'timestamps', 'cycle_ids', 'outcome status and confidence',
                'intent classification and domain', 'keywords and topics',
                'tool names and success/failure', 'D\' decisions, scores, and feature names',
                'model names', 'token counts', 'delegation chains (agent + tools + outcome)',
                'metrics (duration, tokens, tool_calls, agent_delegations)',
            ],
            'redacted': [
                'human input text', 'LLM response text', 'narrative summaries',
                'tool call inputs and outputs', 'entity names (organisations)',
                'source URLs', 'email addresses', 'personal names',
                'D\' explanation text (may contain input content)',
            ],
            'excluded_entirely': [
                'facts store', 'CBR cases', 'comms messages', 'artifacts',
                'planner tasks', 'scheduler state',
            ],
        },
        'note': 'These logs support the claims in the Springdrift paper series. '
                'They are sufficient to verify: entry counts, date ranges, outcome distributions, '
                'D\' decision patterns, model usage, tool call patterns, and delegation chains. '
                'They are NOT sufficient to reconstruct conversation content.',
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    with open(output_dir / 'MANIFEST.json', 'w') as f:
        json.dump(manifest, f, indent=2)

    print()
    print(f"Done. Redacted logs written to {output_dir}/")
    print("Review before committing — verify no personal data leaked.")


if __name__ == '__main__':
    main()
