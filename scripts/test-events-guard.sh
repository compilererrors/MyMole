#!/bin/bash
# A zero-exit test process is insufficient when every test was skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I - <<'PY'
import json
import subprocess
import tempfile
from pathlib import Path

checker = Path('scripts/check-test-events.py').resolve()
def test(identifier='synthetic', kind='function', **values):
    return {'kind': 'test', 'payload': {'id': identifier, 'kind': kind, **values}}
def event(kind, **values):
    return {'kind': 'event', 'payload': {'kind': kind, **values}}
start, end = event('runStarted'), event('runEnded')
ran = [event('testStarted', testID='synthetic'), event('testEnded', testID='synthetic')]
failures = []
with tempfile.TemporaryDirectory(prefix='mymole-test-events-') as folder:
    path = Path(folder) / 'events.jsonl'
    def check(label, records, expected, *options):
        path.write_text(''.join(json.dumps(r) + '\n' for r in records))
        result = subprocess.run(['python3', '-I', str(checker), str(path), *options], capture_output=True)
        if result.returncode != expected:
            failures.append(label)
            print(f'Failed: {label} (exit {result.returncode}, expected {expected})')
        else:
            print(f'Verified: {label}')
    check('one completed function', [test(), start, *ran, end], 0)
    check('empty stream', [], 2)
    check('no tests', [start, end], 69)
    check('suite events cannot count as tests', [test(kind='suite'), start, *ran, end], 69)
    skipped = event('testSkipped', testID='synthetic')
    check('all skipped', [test(), start, skipped, end], 69)
    check('an unfinished function', [test(), start, ran[0], end], 2)
    check('a missing run end', [test(), start, *ran], 2)
    check('an unknown function', [start, *ran, end], 2)
    check('an empty parameterized test', [test(isParameterized=True), start, *ran, end], 69)
    check('a completed parameterized case', [test(isParameterized=True), start, *ran,
        event('testCaseEnded', testID='synthetic'), end], 0)
    mixed = [test(), test('skipped'), start, *ran, event('testSkipped', testID='skipped'), end]
    check('ordinary runs permit optional skipped suites', mixed, 0)
    check('E2E refuses partial skips', mixed, 2, '--no-skips')
    path.write_text('{broken')
    assert subprocess.run(['python3', '-I', str(checker), str(path)], capture_output=True).returncode == 2
    path.unlink()
    assert subprocess.run(['python3', '-I', str(checker), str(path)], capture_output=True).returncode == 2
if failures:
    raise SystemExit(1)
PY
