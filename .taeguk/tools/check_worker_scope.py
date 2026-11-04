#!/usr/bin/env python3
"""Check that a scheduled worker PR changes only what its worker may change, before auto-merge.

This checks paths, file modes, case collisions and, for Rust sources, that test-gap edits stay inside
the trailing `#[cfg(test)]` module. It does not judge whether a change is needed or correct.

Without --config the Taeguk repository's own scope applies, and only there. An installed project names
its scope file with --config; it is read from the base commit, so the PR under check cannot change its
own scope.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tomllib

WORKERS = ('test-gap', 'daily-cleanup')

# Never changed by a worker PR, whatever the worker or project scope. Matched case-insensitively,
# since a case-insensitive checkout puts `Docs/Rules/x.md` next to the real rules.
PROTECTED_PREFIXES = (
    '.github/', '.taeguk/', '.claude/', '.codex/', '.agents/',
    'codex/',        # skills and agent roles: agent instructions
    'docs/rules/',   # rule bodies, registry, approvals, proposals
)
PROTECTED_NAMES = {
    'agents.md', 'claude.md', 'claude.local.md',
    '.gitattributes', '.gitignore', '.gitmodules',
    'cargo.toml', 'cargo.lock', 'mix.exs', 'mix.lock',
}
PROTECTED_FILES = {
    'scripts/check_worker_scope.py', 'tests/test_check_worker_scope.py',
    'scripts/check_rules.py', 'tests/test_rules.py',
    'scripts/check_doc_drift.py', 'tests/test_doc_drift.py',  # input of the daily cleanup itself
    # Run by the scheduled validation-health worker with this Mac's environment and gh login (BOSS, 2026-11-04).
    'scripts/validation_health.py', 'scripts/validation-suites.toml', 'tests/test_validation_health.py',
    'docs/repository-operations.md',
}

TEST_PREFIXES = ['tests/', 'apps/taeguk/test/', 'tools/taeguk-cli/tests/']
RUST_SOURCE_PREFIX = 'tools/taeguk-cli/src/'

# The Taeguk repository's scope, in the form a project scope file takes.
# CI runs `python3 scripts/...` and `unittest discover -s tests`, which put these directories first
# on sys.path: a module there named like a standard one replaces it in protected checks.
TAEGUK_SCOPE = {
    'python_import_roots': ['scripts/', 'tests/'],
    'executable_files': True,
    'protected': [],
    'workers': {
        'test-gap': {'allow': TEST_PREFIXES, 'rust_test_module': [RUST_SOURCE_PREFIX + '**/*.rs'],
                     'forbid_removed_lines': False},
        'daily-cleanup': {'allow': TEST_PREFIXES + ['scripts/', 'apps/taeguk/lib/', RUST_SOURCE_PREFIX, 'docs/',
                                                    'README.md'],
                          'rust_test_module': [], 'forbid_removed_lines': False},
    },
}
DEFAULT_CONFIG = '.taeguk/worker-scope.toml'
# Paths only the Taeguk repository has; a project that copied the checker into scripts/ lacks the rest.
TAEGUK_MARKERS = ('scripts/check_worker_scope.py', 'docs/rules/registry.toml', 'tools/taeguk-cli/Cargo.toml')
SCOPE_KEYS = {'schema_version', 'python_import_roots', 'executable_files', 'protected', 'workers'}
WORKER_KEYS = {'allow', 'rust_test_module', 'forbid_removed_lines'}
SHADOWED = set(sys.stdlib_module_names) | {'sitecustomize', 'usercustomize'}

ZERO = '0' * 40
# Override user config that would hide changes (diff.relative, diff.ignoreSubmodules, external diff).
DIFF_FLAGS = ('-z', '--no-renames', '--no-relative', '--ignore-submodules=none', '--no-ext-diff', '--no-textconv')


def git(*args, check=True):
    out = subprocess.run(['git', *args], capture_output=True)
    if check and out.returncode != 0:
        raise RuntimeError(f'git {args[0]} failed: ' + out.stderr.decode(errors='replace').strip())
    return out


def changes(base, head):
    """Raw entries from the merge-base of base and head to head, without rename detection."""
    raw = git('diff', '--raw', *DIFF_FLAGS, '--abbrev=40', f'{base}...{head}').stdout
    parts = raw.split(b'\0')
    entries = []
    i = 0
    while i + 1 < len(parts) and parts[i]:
        meta = parts[i].decode('ascii').lstrip(':').split()
        path = parts[i+1].decode('utf-8', errors='surrogateescape')
        entries.append({'old_mode': meta[0], 'new_mode': meta[1], 'old': meta[2], 'new': meta[3],
                        'status': meta[4], 'path': path})
        i += 2
    return entries


def blob(sha):
    return b'' if sha == ZERO else git('cat-file', 'blob', sha).stdout


def protected(path, extra=()):
    """Built-in protected paths, plus the project's `extra` patterns; both case-insensitive."""
    lower = path.lower()
    name = lower.rsplit('/', 1)[-1]
    # Agents discover instruction directories below the root too.
    if {'.github', '.taeguk', '.claude', '.codex', '.agents'} & set(lower.split('/')[:-1]):
        return True
    return (lower.startswith(PROTECTED_PREFIXES) or name in PROTECTED_NAMES
            or lower in PROTECTED_FILES or (name.startswith('agents') and name.endswith('.md'))
            or any(pattern.fullmatch(lower) for pattern in extra))


def compile_pattern(pattern, fold=False):
    """A scope path pattern as a regex: `dir/` is a prefix, `*` and `?` stay within one segment,
    and a `**` segment matches any number of segments. Anything else matches itself.
    """
    if (not isinstance(pattern, str) or not pattern or not pattern.isascii() or not pattern.isprintable()
            or pattern.startswith('/') or '\\' in pattern or '[' in pattern or ']' in pattern):
        raise ValueError(f'invalid scope pattern: {pattern!r}')
    segments = pattern.split('/')
    if pattern.endswith('/'):
        segments[-1] = '**'
    if any(seg in ('', '.', '..') or ('**' in seg and seg != '**') for seg in segments):
        raise ValueError(f'invalid scope pattern: {pattern!r}')
    out = ''
    for i, seg in enumerate(segments):
        last = i == len(segments) - 1
        if seg == '**':
            out += '.*' if last else '(?:[^/]+/)*'
            continue
        out += ''.join('[^/]*' if c == '*' else '[^/]' if c == '?' else re.escape(c) for c in seg)
        out += '' if last else '/'
    return re.compile(out.lower() if fold else out)


def exists(commit, path):
    return git('cat-file', '-e', f'{commit}:{path}', check=False).returncode == 0


def load_scope(base, config):
    """The scope for this run: Taeguk's own without config, else the config file at the base commit."""
    if config is None:
        # Taeguk's paths mean something else elsewhere: an installed project must name its scope file.
        if not all(exists(base, path) for path in TAEGUK_MARKERS) or exists(base, DEFAULT_CONFIG):
            raise ValueError(f'not the Taeguk repository; pass --config {DEFAULT_CONFIG}')
        doc, source = TAEGUK_SCOPE, 'built-in (Taeguk repository)'
    else:
        if not protected(config):
            # A scope file a worker may edit would let one worker PR widen the next one.
            raise ValueError(f'scope file is not a protected path: {config}')
        compile_pattern(config)
        if not exists(base, config):
            raise ValueError(f'no scope file {config} at base commit')
        try:
            doc = tomllib.loads(git('cat-file', 'blob', f'{base}:{config}').stdout.decode('utf-8'))
        except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
            raise ValueError(f'unreadable scope file {config}: {exc}')
        source = f'{config} at {base}'
        unknown = set(doc) - SCOPE_KEYS
        if unknown or type(doc.get('schema_version')) is not int or doc['schema_version'] != 1:
            raise ValueError(f'scope file needs schema_version = 1 and only known keys, got {sorted(unknown)}')
    def patterns(table, key, fold=False):
        value = table.get(key, [])
        if not isinstance(value, list):
            raise ValueError(f'scope {key} must be a list')
        return [compile_pattern(v, fold) for v in value]
    def flag(table, key):
        value = table.get(key, False)
        if not isinstance(value, bool):
            raise ValueError(f'scope {key} must be true or false')
        return value
    workers = doc.get('workers', {})
    if not isinstance(workers, dict) or set(workers) - set(WORKERS):
        raise ValueError(f'scope workers must be among {", ".join(WORKERS)}')
    scope = {'source': source, 'protected': patterns(doc, 'protected', fold=True),
             'executable_files': flag(doc, 'executable_files'), 'workers': {}}
    roots = doc.get('python_import_roots', [])
    # Matched as literal prefixes, so a wildcard would silently match nothing.
    if not isinstance(roots, list) or not all(isinstance(r, str) and re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]*/', r)
                                              for r in roots):
        raise ValueError('scope python_import_roots must be top-level directories such as "scripts/"')
    scope['python_import_roots'] = tuple(roots)
    for worker, table in workers.items():
        if not isinstance(table, dict) or set(table) - WORKER_KEYS or not table.get('allow'):
            raise ValueError(f'scope for {worker} needs a non-empty allow list and only {sorted(WORKER_KEYS)}')
        scope['workers'][worker] = {'allow': patterns(table, 'allow'),
                                    'rust_test_module': patterns(table, 'rust_test_module'),
                                    'forbid_removed_lines': flag(table, 'forbid_removed_lines')}
    return scope


def significant(src):
    """Positions of code characters outside comments and literals; a literal counts as one `L`.

    Handles line and nested block comments, strings with escapes over several lines, raw and
    byte strings, char literals and lifetimes. An unterminated comment or literal raises.
    """
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
        elif src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
        elif src.startswith('/*', i):
            depth, i = 1, i + 2
            while depth:
                if i >= n:
                    raise ValueError('unterminated block comment')
                if src.startswith('/*', i):
                    depth, i = depth + 1, i + 2
                elif src.startswith('*/', i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
        elif raw := re.match(r'[bc]?r(#*)"', src[i:]) if (c in 'bcr' and (i == 0 or not (src[i-1].isalnum() or src[i-1] == '_'))) else None:
            close = '"' + raw.group(1)
            j = src.find(close, i + raw.end())
            if j < 0:
                raise ValueError('unterminated raw string')
            out.append((i, 'L'))
            i = j + len(close)
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            if j >= n:
                raise ValueError('unterminated string')
            out.append((i, 'L'))
            i = j + 1
        elif c == "'":
            if src.startswith('\\', i + 1):
                j = src.find("'", i + 3)
                if j < 0:
                    raise ValueError('unterminated char literal')
                out.append((i, 'L'))
                i = j + 1
            elif i + 2 < n and src[i+2] == "'":
                out.append((i, 'L'))
                i += 3
            else:
                out.append((i, c))  # lifetime marker
                i += 1
        else:
            out.append((i, c))
            i += 1
    return out


def test_module_span(src):
    """Offsets of the `{` and `}` of the trailing `#[cfg(test)] mod name { ... }`, or None.

    The module must be the only `#[cfg(test)]` item and the last item: nothing but whitespace and
    comments may follow its closing brace.
    """
    tokens = significant(src)
    text = ''.join(c for _, c in tokens)
    attr = '#[cfg(test)]'
    if text.count(attr) != 1:
        return None
    k = text.index(attr) + len(attr)
    after_attr = tokens[k-1][0] + 1
    opening = next((j for j in range(k, len(tokens)) if tokens[j][1] in '{;'), None)
    if opening is None or tokens[opening][1] != '{' or not re.fullmatch(r'\s*mod\s+[A-Za-z_]\w*\s*', src[after_attr:tokens[opening][0]]):
        return None
    depth = 0
    for j in range(opening, len(tokens)):
        depth += {'{': 1, '}': -1}.get(tokens[j][1], 0)
        if depth == 0:
            return (tokens[opening][0], tokens[j][0]) if j == len(tokens) - 1 else None
    return None


def rust_test_only(old, new):
    """True when old and new differ only inside the trailing test module's braces.

    A second `#[cfg(test)]`, even inside the module, makes this False: rejected, never passed.
    """
    try:
        old_src, new_src = old.decode(), new.decode()
        old_span, new_span = test_module_span(old_src), test_module_span(new_src)
    except (UnicodeDecodeError, ValueError):
        return False
    return (old_span is not None and new_span is not None
            and old_src[:old_span[0]+1] == new_src[:new_span[0]+1] and old_src[old_span[1]:] == new_src[new_span[1]:])


def violation(worker, entry, scope, removed):
    path, status = entry['path'], entry['status']
    rules = scope['workers'][worker]
    if not path.isascii() or not path.isprintable():
        return 'non-ASCII or control character in path'
    if protected(path, scope['protected']):
        return 'protected path'
    if path.startswith(scope['python_import_roots']) and status != 'D':
        rest = path.split('/', 1)[1]
        top = rest.split('/')[0]
        if (top.split('.')[0] if top == rest else top).lower() in SHADOWED:
            return 'shadows a standard library module'
        if top != rest and status == 'A':
            # A new package would be imported before a same-named protected module or test.
            return f'new package under {" or ".join(scope["python_import_roots"])}'
    if status not in 'AMD':
        return f'unsupported change type {status}'
    regular = {'100644', '100755'} if scope['executable_files'] else {'100644'}
    for mode in (entry['old_mode'], entry['new_mode']):
        if mode != '000000' and mode not in regular:
            return f'not a regular file (mode {mode})'
    if status == 'M' and entry['old_mode'] != entry['new_mode']:
        return 'file mode change'
    if status == 'A' and entry['new_mode'] != '100644':
        return 'new file is not mode 100644'
    old, new = blob(entry['old']), blob(entry['new'])
    if b'\0' in old or b'\0' in new:
        return 'binary content'
    try:
        old.decode('utf-8'), new.decode('utf-8')
    except UnicodeDecodeError:
        return 'binary content'
    if worker == 'test-gap' and status == 'D':
        return 'test-gap does not delete files'
    if rules['forbid_removed_lines'] and removed.get(path):
        return 'removed lines'
    if any(p.fullmatch(path) for p in rules['allow']):
        return None
    if any(p.fullmatch(path) for p in rules['rust_test_module']) and status == 'M':
        return None if rust_test_only(old, new) else 'change outside the trailing #[cfg(test)] module'
    return 'not a test path' if worker == 'test-gap' else 'not a cleanup path'


def removed_lines(base, head):
    """Whether each changed path lost a line, read as text whatever the attributes say."""
    raw = git('diff', '--numstat', '--text', *DIFF_FLAGS, f'{base}...{head}').stdout
    counts = {}
    for item in raw.split(b'\0'):
        if item:
            _, removed, path = item.split(b'\t', 2)
            counts[path.decode('utf-8', errors='surrogateescape')] = removed != b'0'
    return counts


def case_collisions(*commits):
    """Paths, files or directories, that differ only in case across the given trees.

    On a case-insensitive checkout `test/Test_helper.exs` overwrites `test/test_helper.exs`; base and
    head are both listed so a path main gained after the merge-base is compared too.
    """
    names = set()
    for commit in commits:
        names |= set(git('ls-tree', '-r', '-t', '-z', '--name-only', commit).stdout.split(b'\0')) - {b''}
    groups = {}
    for name in names:
        path = name.decode('utf-8', errors='surrogateescape')
        groups.setdefault(path.casefold(), []).append(path)
    return sorted(p for group in groups.values() if len(group) > 1 for p in group)


def resolve(ref):
    # An option-like ref would change what git prints rather than name a commit.
    if ref.startswith('-'):
        raise ValueError(f'not a commit: {ref}')
    return git('rev-parse', '--verify', '--end-of-options', f'{ref}^{{commit}}').stdout.decode().strip()


def check(worker, base, head, config=None):
    # From the top level, so diff.relative or a subdirectory cwd cannot hide paths.
    os.chdir(git('rev-parse', '--show-toplevel').stdout.decode().rstrip('\n'))
    base, head = resolve(base), resolve(head)
    scope = load_scope(base, config)
    if worker not in scope['workers']:
        raise ValueError(f'scope from {scope["source"]} has no {worker} section')
    entries = changes(base, head)
    removed = removed_lines(base, head) if scope['workers'][worker]['forbid_removed_lines'] else {}
    rejected = [{'path': e['path'], 'reason': reason} for e in entries
                if (reason := violation(worker, e, scope, removed))]
    rejected += [{'path': path, 'reason': 'case collision'} for path in case_collisions(base, head)]
    return {'status': 'FAIL' if rejected else 'PASS', 'worker': worker, 'base': base, 'head': head,
            'scope': scope['source'], 'changed': len(entries), 'rejected': rejected,
            'limits': ['paths, modes and test-module boundary only; not whether a change is needed or correct']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('worker', choices=WORKERS)
    parser.add_argument('--base', default='origin/main')
    parser.add_argument('--head', default='HEAD')
    parser.add_argument('--config', help='scope file path in the repository, read at the base commit '
                                         '(installed projects: .taeguk/worker-scope.toml)')
    args = parser.parse_args()
    try:
        result = check(args.worker, args.base, args.head, args.config)
    except (RuntimeError, ValueError, IndexError) as exc:
        print(json.dumps({'status': 'UNKNOWN', 'error': str(exc)}, ensure_ascii=False))
        sys.exit(2)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0 if result['status'] == 'PASS' else 1)


if __name__ == '__main__':
    main()
