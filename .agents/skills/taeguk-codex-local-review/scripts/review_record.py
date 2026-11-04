#!/usr/bin/env python3
"""Run one local Codex review and record it, or render the records as a PR-ready block.

`run` executes the pinned `codex exec review` command and writes a JSON record computed from the
run itself: CLI version, resolved target SHAs, prompt sha256, exit code, times and the working-tree
state before and after. `render` turns cross and security records plus the reviewer's adjudication
file into a fixed Korean block for the PR body or worker run report. Nothing missing is filled in:
an absent record, version or adjudication is rendered as NOT_RUN or UNKNOWN. A completed run means
Codex finished and wrote output; it is not PASS for correctness or security.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

KINDS = {'cross': '교차', 'security': '보안'}
ASSESSMENTS = {'reproduced': '재현', 'plausible': '타당', 'rejected': '기각',
               'needs-reproduction': '재현 필요', 'repeat': '이전 판정 반복'}
# Model and effort land inside a TOML string passed with -c; keep them to plain identifiers.
NAME = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
EXIT = {'COMPLETED': 0, 'FAIL': 1, 'UNKNOWN': 2, 'NOT_RUN': 2}
# The target lines of references/review-prompts.md; the prompt's first line must be one of them.
TARGET_LINES = {
    'range': 'Review only the changes shown by `git diff {target}`.',
    'commit': 'Review only the changes introduced by commit {target} (`git show {target}`).',
    'uncommitted': 'Review only the uncommitted changes: `git diff HEAD` and the untracked files '
                   'listed by `git status --short`.',
}


def now():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git(repo, *args, binary=False):
    result = subprocess.run(['git', *args], cwd=repo, capture_output=True, check=True)
    return result.stdout if binary else result.stdout.decode('utf-8', 'surrogateescape').strip()


def entry_digest(path):
    """Hash an untracked entry; a directory (an untracked nested repository) by every file below it."""
    if path.is_symlink():
        return b'link:' + os.fsencode(os.readlink(path))
    if path.is_file():
        # The executable bit too, as git records it for a tracked file.
        return (b'x:' if path.stat().st_mode & 0o111 else b'f:') + sha256_file(path).encode()
    if not path.is_dir():
        return b'other:' + str(path.lstat().st_mode).encode()
    digest = hashlib.sha256()
    for root, dirs, files in os.walk(path):
        dirs.sort()
        # os.walk lists a symlink to a directory under dirs and does not follow it; hash it as a link.
        for name in sorted(files + [d for d in dirs if (Path(root)/d).is_symlink()]):
            child = Path(root)/name
            digest.update(os.fsencode(child.relative_to(path)) + b'\0' + entry_digest(child) + b'\n')
    return b'dir:' + digest.hexdigest().encode()


def tree_state(repo):
    """HEAD, short status and the SKILL.md content fingerprint (diff against HEAD plus untracked files)."""
    digest = hashlib.sha256(git(repo, 'diff', 'HEAD', '--binary', binary=True))
    for name in git(repo, 'ls-files', '-o', '--exclude-standard', '-z', binary=True).split(b'\0'):
        if not name:
            continue
        digest.update(entry_digest(Path(repo)/name.decode('utf-8', 'surrogateescape')) + b'  ' + name + b'\n')
    return {'head': git(repo, 'rev-parse', 'HEAD'), 'status': git(repo, 'status', '--short'),
            'fingerprint': digest.hexdigest()}


def resolve_target(repo, target):
    if target == 'uncommitted':
        return {'kind': 'uncommitted', 'base': None, 'head': git(repo, 'rev-parse', 'HEAD')}
    if '...' in target:
        base, head = target.split('...', 1)
        return {'kind': 'range', 'base': git(repo, 'rev-parse', '--verify', f'{base}^{{commit}}'),
                'head': git(repo, 'rev-parse', '--verify', f'{head}^{{commit}}')}
    return {'kind': 'commit', 'base': None, 'head': git(repo, 'rev-parse', '--verify', f'{target}^{{commit}}')}


def codex_version(codex):
    try:
        result = subprocess.run([codex, '--version'], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    first = result.stdout.strip().splitlines()[:1]
    return first[0].strip() if result.returncode == 0 and first else None


def last_line(stderr):
    lines = [line.strip() for line in (stderr or b'').decode('utf-8', 'replace').splitlines() if line.strip()]
    return f': {lines[-1][:300]}' if lines else ''


def run(args):
    repo = Path(git(args.repo, 'rev-parse', '--show-toplevel'))
    for label, path in (('--prompt', args.prompt), ('--output', args.output), ('--record', args.record)):
        if Path(path).resolve().is_relative_to(repo.resolve()):
            raise ValueError(f'{label} must be outside the reviewed tree {repo}')
    for label, path in (('--output', args.output), ('--record', args.record)):
        # A leftover output would let a run that wrote nothing look completed.
        if os.path.lexists(path):
            raise ValueError(f'{label} {path} already exists; use a new path for each run')
        if not Path(path).resolve().parent.is_dir():
            raise ValueError(f'{label} directory does not exist')
    if Path(args.output).resolve() == Path(args.record).resolve():
        raise ValueError('--output and --record must be different files')
    for label, value in (('--model', args.model), ('--effort', args.effort)):
        if not NAME.fullmatch(value):
            raise ValueError(f'{label} must be a plain identifier')
    target = resolve_target(repo, args.target)
    # Read once so the hash, the target check and what Codex receives are the same bytes.
    prompt_bytes = Path(args.prompt).read_bytes()
    lines = [line.strip() for line in prompt_bytes.decode('utf-8').splitlines() if line.strip()]
    record = {
        # Unique per run, so an adjudication names exactly the run it assessed.
        'run_id': uuid.uuid4().hex,
        'kind': args.kind, 'target': args.target, **{f'target_{k}': v for k, v in target.items()},
        'model': args.model, 'effort': args.effort, 'codex_version': None, 'exit_code': None,
        'prompt': str(Path(args.prompt).resolve()), 'prompt_sha256': hashlib.sha256(prompt_bytes).hexdigest(),
        # The prompt's target line should name what the record claims was reviewed.
        'prompt_names_target': bool(lines) and lines[0] == TARGET_LINES[target['kind']].format(target=args.target),
        'output': str(Path(args.output).resolve()), 'output_sha256': None, 'output_bytes': None,
        'started_at': None, 'ended_at': None, 'before': tree_state(repo), 'after': None,
        'status': None, 'reason': None,
    }
    codex = shutil.which(args.codex)
    # Absolute, so the version check and the review (run with cwd=repo) use the same executable.
    codex = os.path.abspath(codex) if codex else None
    record['codex_version'] = codex_version(codex) if codex else None
    if not codex:
        record.update(status='NOT_RUN', reason=f'{os.path.basename(args.codex)} not found')
    else:
        command = [codex, 'exec', 'review', '-c', f'model="{args.model}"',
                   '-c', f'model_reasoning_effort="{args.effort}"', '-c', 'sandbox_mode="read-only"',
                   '--ephemeral', '-o', record['output'], '-']
        record['command'] = command
        record['started_at'] = now()
        started = True
        try:
            # Codex's own stdout goes to stderr so this script's stdout stays one JSON summary. Its
            # stderr is kept so a refusal or failed login leaves the CLI's reason in the record.
            result = subprocess.run(command, cwd=repo, input=prompt_bytes, stdout=sys.stderr,
                                    stderr=subprocess.PIPE, timeout=args.timeout)
            sys.stderr.buffer.write(result.stderr)
            record['exit_code'] = result.returncode
            if result.returncode:
                record['reason'] = f'exit {result.returncode}' + last_line(result.stderr)
        except subprocess.TimeoutExpired as error:
            sys.stderr.buffer.write(error.stderr or b'')
            record['reason'] = f'timeout after {args.timeout}s'
        except OSError as error:  # found but could not start, for example a missing interpreter
            record['reason'] = f'{os.path.basename(codex)} could not start: {error.strerror}'
            started = False
        record['ended_at'] = now()
        output = Path(record['output'])
        blank = True
        if output.is_file():
            record['output_sha256'], record['output_bytes'] = sha256_file(output), output.stat().st_size
            blank = not output.read_bytes().strip()
        try:
            record['after'] = tree_state(repo)
        except (OSError, subprocess.CalledProcessError) as error:
            record['reason'] = f'tree state after the run could not be read: {error}'
        try:
            moved = resolve_target(repo, args.target) != target
        except subprocess.CalledProcessError:
            moved = True  # a target that no longer resolves has moved
        if record['after'] is None:
            moved = None
        if moved is None:
            record['status'] = 'UNKNOWN'
        elif record['after'] != record['before']:
            record.update(status='FAIL', reason='working tree or HEAD changed during the review')
        elif moved:
            record.update(status='FAIL', reason='target refs moved during the review')
        elif not started:
            record['status'] = 'NOT_RUN'
        elif record['exit_code'] != 0:
            record.update(status='UNKNOWN', reason=record['reason'] or f'exit {record["exit_code"]}')
        elif blank:
            record.update(status='UNKNOWN', reason='empty, blank or missing output')
        else:
            record['status'] = 'COMPLETED'
    Path(args.record).write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: record[k] for k in ('kind', 'status', 'reason', 'exit_code', 'codex_version',
                                             'prompt_sha256', 'prompt_names_target')}, ensure_ascii=False))
    return EXIT[record['status']]


def one_line(value):
    # Free text can quote Codex, which read the reviewed code: keep it from opening HTML (`<!--` would
    # hide the rest of the block on GitHub).
    return ' '.join(str(value).split()).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def target_text(record):
    if record['target_kind'] == 'range':
        return f'`{record["target_base"]}...{record["target_head"]}`'
    if record['target_kind'] == 'commit':
        return f'커밋 `{record["target_head"]}`'
    return f'작업 트리(HEAD `{record["target_head"]}`, 지문 `{record["before"]["fingerprint"]}`)'


def header(record):
    version = record.get('codex_version') or 'codex-cli UNKNOWN'
    exit_code = 'UNKNOWN' if record.get('exit_code') is None else record['exit_code']
    after = record.get('after')
    tree = 'UNKNOWN' if after is None else '불변' if after == record['before'] else '변경됨'
    times = f'{record.get("started_at") or "UNKNOWN"} ~ {record.get("ended_at") or "UNKNOWN"}'
    return (f'대상 {target_text(record)}, 모델 `{record["model"]}`, effort `{record["effort"]}`, '
            f'{version}, exit {exit_code}, 작업 트리 {tree}, '
            f'프롬프트 sha256 `{record["prompt_sha256"]}`, 실행 {times}')


def checked_list(kind, judged, key):
    value = judged.get(key)
    if value is not None and not (isinstance(value, list) and all(isinstance(item, dict) for item in value)):
        raise ValueError(f'{kind}.{key} must be a list of objects')
    return value


def finding_lines(kind, judged):
    if judged is None:
        return ['지적과 처리: UNKNOWN(판정 기록 없음)', '목적 이의: UNKNOWN(판정 기록 없음)']
    lines = []
    findings = checked_list(kind, judged, 'findings')
    if findings is None:
        lines.append('지적과 처리: UNKNOWN(판정 기록 없음)')
    elif not findings:
        lines.append('지적: Codex가 지적을 보고하지 않았습니다. 정확성·보안 PASS는 아닙니다.')
    for number, item in enumerate(findings or [], 1):
        assessment = item.get('assessment')
        if assessment not in ASSESSMENTS:
            raise ValueError(f'{kind} finding {number}: assessment must be one of {", ".join(ASSESSMENTS)}')
        lines.append(f'지적 {number}: `{one_line(item.get("location") or "위치 없음")}` '
                     f'{one_line(item.get("severity") or "등급 없음")}, {one_line(item.get("claim") or "UNKNOWN")} '
                     f'→ 평가: {ASSESSMENTS[assessment]}, 처리: {one_line(item.get("handling") or "UNKNOWN")}')
    challenges = checked_list(kind, judged, 'purpose_challenges')
    if challenges is None:
        lines.append('목적 이의: UNKNOWN(판정 기록 없음)')
    elif not challenges:
        lines.append('목적 이의: 없음')
    for number, item in enumerate(challenges or [], 1):
        decision = item.get('boss_decision')
        decided = (f'BOSS 결정({one_line(item.get("decided_on") or "날짜 없음")}): {one_line(decision)}'
                   if decision else 'BOSS 결정 대기(이 head에 auto-merge를 켜지 않음)')
        lines.append(f'목적 이의 {number}: {one_line(item.get("claim") or "UNKNOWN")}, '
                     f'의견: {one_line(item.get("view") or "없음")}, {decided}')
    return lines


def render(args):
    records = {}
    for path in args.record:
        record = json.loads(Path(path).read_text(encoding='utf-8'))
        if record.get('kind') not in KINDS:
            raise ValueError(f'{path}: kind must be cross or security')
        if record['kind'] in records:
            raise ValueError(f'{path}: a second {record["kind"]} record; render one run per kind')
        records[record['kind']] = record
    adjudication = json.loads(Path(args.adjudication).read_text(encoding='utf-8')) if args.adjudication else {}
    if not isinstance(adjudication, dict) or any(
            not isinstance(adjudication.get(kind, {}), dict) for kind in KINDS):
        raise ValueError('adjudication must be an object keyed by cross and security')
    not_applicable = {}
    for item in args.not_applicable:
        kind, _, reason = item.partition('=')
        # Only the security review may be skipped, for documentation-only changes (repository-operations.md).
        if kind != 'security' or not reason.strip():
            raise ValueError('--not-applicable takes security=REASON')
        if kind in records:
            raise ValueError(f'{kind} has a run record and cannot also be NOT_APPLICABLE')
        not_applicable[kind] = reason
    out = ['- 로컬 Codex 리뷰']
    # For an uncommitted target the fingerprint is the version: HEAD alone does not change with the edits.
    versions = {(r.get('target_base'), r.get('target_head'),
                 r.get('before', {}).get('fingerprint') if r.get('target_kind') == 'uncommitted' else None)
                for r in records.values()}
    if len(records) == 2 and len(versions) > 1:
        out.append('  - 경고: 교차와 보안 기록의 대상(SHA 또는 작업 트리 지문)이 다릅니다.')
    for kind, label in KINDS.items():
        record = records.get(kind)
        if kind in not_applicable:
            out.append(f'  - {label}: NOT_APPLICABLE({one_line(not_applicable[kind])})')
            continue
        if record is None:
            out.append(f'  - {label}: NOT_RUN(실행 기록 없음)')
            continue
        out.append(f'  - {label}: {header(record)}')
        if not record.get('prompt_names_target'):
            out.append('    - 경고: 프롬프트의 대상 줄에 이 대상이 보이지 않습니다.')
        if record['target_kind'] != 'uncommitted' and record['before']['head'] != record['target_head']:
            out.append(f'    - 경고: 실행 때 HEAD `{record["before"]["head"]}`가 대상 head와 다릅니다. '
                       'Codex가 읽은 저장소 내용은 대상 head가 아닙니다.')
        if record['status'] != 'COMPLETED':
            # No adjudication is shown for a run that did not complete: there was nothing to assess.
            out.append(f'    - 실행 결과: {record["status"]}({one_line(record.get("reason") or "이유 없음")}), '
                       '지적과 목적 이의는 판정하지 않았습니다.')
            continue
        judged = adjudication.get(kind)
        if judged is not None and (not record.get('run_id') or judged.get('run_id') != record['run_id']):
            # An adjudication of another run (an older head, say) must not stand in for this one.
            why = '판정 파일의 run_id가 이 실행 기록과 다름' if record.get('run_id') else '실행 기록에 run_id 없음'
            out += [f'    - 지적과 처리: UNKNOWN({why})',
                    '    - 목적 이의: UNKNOWN(판정 파일이 이 실행과 연결되지 않음)']
            continue
        out += [f'    - {line}' for line in finding_lines(kind, judged)]
    print('\n'.join(out))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    run_parser = commands.add_parser('run', help='run one review and write its record')
    run_parser.add_argument('--kind', choices=KINDS, required=True)
    run_parser.add_argument('--target', required=True,
                            help='BASE...HEAD, one commit, or "uncommitted"; the prompt target line must name it')
    run_parser.add_argument('--model', required=True)
    run_parser.add_argument('--effort', required=True)
    run_parser.add_argument('--prompt', required=True, help='prompt file outside the reviewed tree')
    run_parser.add_argument('--output', required=True, help='final message file outside the reviewed tree')
    run_parser.add_argument('--record', required=True, help='JSON record file outside the reviewed tree')
    run_parser.add_argument('--repo', default='.')
    run_parser.add_argument('--codex', default='codex', help='Codex CLI executable')
    run_parser.add_argument('--timeout', type=float, help='seconds before the run is stopped as UNKNOWN')
    render_parser = commands.add_parser('render', help='render records as the PR body block')
    render_parser.add_argument('--record', action='append', default=[], help='run record; once per kind')
    render_parser.add_argument('--adjudication', help='JSON file with findings and purpose challenges per kind')
    render_parser.add_argument('--not-applicable', action='append', default=[], metavar='KIND=REASON')
    args = parser.parse_args()
    try:
        return run(args) if args.command == 'run' else render(args)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors='replace').strip() if isinstance(error, subprocess.CalledProcessError) else error
        print(f'error: {detail}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
