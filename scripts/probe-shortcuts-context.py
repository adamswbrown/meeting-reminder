#!/usr/bin/env python3
"""Probe a generation-only shortcut with synthetic evidence, never live meeting data.

Shortcut: Use Model(prompt=Shortcut Input, Follow Up off, Broad World Knowledge
off) -> Stop and Output(Response). Select Cloud or Cloud Pro in the editor.
Input sizes are characters, NOT a claim about the selected model's token count.
"""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time


def make_prompt(size):
    instruction = (
        'Read the synthetic records and return only a JSON object with keys '
        '"start_code", "middle_owner", "end_deadline", "total_units". '
        'Use the three TARGET records. total_units is the sum of their unit counts. '
        'All other records are unrelated. Do not infer missing values.\n\n'
    )
    start = 'TARGET START: start_code = CEDAR-482; units = 17.\n'
    middle = 'TARGET MIDDLE: middle_owner = Mira Vale; units = 23.\n'
    end = 'TARGET END: end_deadline = 2026-11-19; units = 31.\n'
    filler_size = size - sum(map(len, (instruction, start, middle, end)))
    if filler_size < 0:
        raise ValueError('Size is too small for the instructions and target records')

    def filler(count, offset):
        lines = []
        length = 0
        i = offset
        while length < count:
            line = (f'Archive record {i}: routine catalog review completed; '
                    'no target decision, owner or deadline is recorded here.\n')
            lines.append(line)
            length += len(line)
            i += 1
        return ''.join(lines)[:count]

    left = filler_size // 2
    return instruction + start + filler(left, 1) + middle + filler(filler_size - left, 10000) + end


def decode_response(raw):
    text = raw.strip()
    if text.startswith('```'):
        lines = text.splitlines()
        if lines[-1].strip() == '```':
            text = '\n'.join(lines[1:-1])
    return json.loads(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shortcut', default='Meeting Briefing PCC Probe')
    parser.add_argument('--model-label', required=True,
                        help='Record the model selected in Shortcuts; this does not change it')
    parser.add_argument('--chars', type=int, default=32000)
    parser.add_argument('--timeout', type=int, default=90)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    prompt = make_prompt(args.chars)
    expected = {'start_code': 'CEDAR-482', 'middle_owner': 'Mira Vale',
                'end_deadline': '2026-11-19', 'total_units': 71}
    report = {
        'shortcut': args.shortcut, 'configured_model_label': args.model_label,
        'os': subprocess.check_output(['sw_vers'], text=True).strip(),
        'input_characters': len(prompt), 'input_utf8_bytes': len(prompt.encode()),
        'cloud_token_count': None, 'expected': expected,
        'limitation': 'Synthetic recall/synthesis probe; not a maximum-context or briefing-quality benchmark.',
    }
    with tempfile.TemporaryDirectory(prefix='briefing-context-probe-') as folder:
        source = Path(folder) / 'input.txt'
        output = Path(folder) / 'output.txt'
        source.write_text(prompt)
        began = time.monotonic()
        try:
            run = subprocess.run(
                ['/usr/bin/shortcuts', 'run', args.shortcut,
                 '--input-path', str(source), '--output-path', str(output)],
                capture_output=True, text=True, timeout=args.timeout,
            )
            report['exit_code'] = run.returncode
            report['stderr'] = run.stderr[-2000:]
            raw = output.read_text() if output.exists() else ''
            report['response'] = raw
            try:
                decoded = decode_response(raw)
                report['checks'] = {k: isinstance(decoded, dict) and decoded.get(k) == v
                                    for k, v in expected.items()}
                report['passed'] = run.returncode == 0 and all(report['checks'].values())
            except (ValueError, TypeError):
                report['passed'] = False
                report['error'] = 'Missing or invalid JSON output'
        except subprocess.TimeoutExpired:
            report['passed'] = False
            report['error'] = 'Shortcut process timed out; verify Shortcuts has stopped before another run'
        report['elapsed_seconds'] = round(time.monotonic() - began, 2)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
