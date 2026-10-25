#!/usr/bin/env python3
"""Publish the Codex review result for a PR head as the `codex-review` commit status."""
import argparse
import json
import re
import subprocess
import sys

CONTEXT = 'codex-review'
CODEX_LOGIN = 'chatgpt-codex-connector[bot]'
CODEX_APP = 'chatgpt-codex-connector'
ACTIONS_LOGIN = 'github-actions[bot]'
# Undocumented marker inside Codex's summary comment; a format change must
# leave the gate pending, never successful.
SUMMARY_MARKERS = ('codex-pull-request-review-summary', 'codex-review-state')
STATE = re.compile(r'<!--\s*codex-review-state:v1\s+(\{.*?\})\s*-->', re.DOTALL)
# A receipt starts with its marker; the clean verdict starts its own line, so
# text Codex merely quotes in a reply cannot pass as a receipt.
RECEIPT_MARKER = '<!-- codex-review-receipt:v1 -->'
RECEIPT_COMMIT = re.compile(r'^\*\*Reviewed commit:\*\*\s*`([0-9a-f]{7,40})`', re.MULTILINE)
CLEAN_RECEIPT = re.compile(r"^Codex Review: Didn't find any major issues", re.MULTILINE)
CODEX_THREAD_AUTHOR = 'chatgpt-codex-connector'  # GraphQL drops the [bot] suffix
THREADS = '''query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    reviewThreads(first: 100) { pageInfo { hasNextPage } nodes { isResolved comments(first: 1) { nodes { author { login } } } } }
  } }
}'''


def gh(*args):
    result = subprocess.run(['gh', *args], capture_output=True, text=True, check=True)
    return result.stdout


def is_codex(comment):
    user = comment.get('user') or {}
    app = comment.get('performed_via_github_app') or {}
    return user.get('login') == CODEX_LOGIN and user.get('type') == 'Bot' and app.get('slug') == CODEX_APP


def codex_summary(comments):
    summaries = [comment for comment in comments
                 if is_codex(comment) and any(marker in (comment.get('body') or '') for marker in SUMMARY_MARKERS)]
    # Never fall back to an older summary: the newest one is the current verdict.
    return max(summaries, key=lambda comment: comment.get('updated_at') or '') if summaries else None


def codex_state(comments):
    """Return the state from the newest Codex summary comment, or {} if it is unreadable."""
    newest = codex_summary(comments)
    if newest is None:
        return None
    match = STATE.search(newest.get('body') or '')
    try:
        state = json.loads(match.group(1)) if match else None
    except json.JSONDecodeError:
        state = None
    return state if isinstance(state, dict) else {}


def evaluate(state, head_sha):
    """Map Codex state to a commit status; anything unproven stays pending."""
    if state is None:
        return 'pending', 'Codex review has not reported yet'
    review = state.get('code_review')
    if not isinstance(review, dict):
        return 'pending', 'Codex review state is unreadable'
    if review.get('commit_sha') != head_sha:
        return 'pending', f'Codex review has not covered head {head_sha[:7]}'
    if review.get('status') != 'completed':
        return 'pending', f'Codex review is {review.get("status") or "not started"}'
    unresolved = review.get('has_unresolved_findings')
    if unresolved is False:
        return 'success', 'Codex review completed with no unresolved findings'
    if unresolved is True:
        return 'failure', 'Codex review has unresolved findings'
    return 'pending', 'Codex review finding state is unknown'


def null_findings(state, head_sha):
    review = (state or {}).get('code_review')
    return (isinstance(review, dict) and review.get('commit_sha') == head_sha
            and review.get('status') == 'completed'
            # Only an explicit null was approved; a missing field is a format change.
            and 'has_unresolved_findings' in review and review['has_unresolved_findings'] is None)


def newest_receipt(comments, head_sha):
    """Codex's newest receipt comment for this head, or None."""
    receipts = []
    for comment in comments:
        body = comment.get('body') or ''
        match = RECEIPT_COMMIT.search(body)
        if is_codex(comment) and body.lstrip().startswith(RECEIPT_MARKER) and match and head_sha.startswith(match.group(1)):
            receipts.append(comment)
    return max(receipts, key=lambda comment: comment.get('updated_at') or '') if receipts else None


def clean_receipt(comments, head_sha):
    """True when Codex's newest receipt for this head reports no major issues."""
    newest = newest_receipt(comments, head_sha)
    return newest is not None and bool(CLEAN_RECEIPT.search(newest.get('body') or ''))


def unresolved_codex_threads(repo, number, call):
    """Count unresolved review threads Codex started; None if not fully listed."""
    owner, name = repo.split('/', 1)
    try:
        data = json.loads(call('api', 'graphql', '-f', f'query={THREADS}', '-f', f'owner={owner}', '-f', f'name={name}', '-F', f'number={number}'))
        threads = data['data']['repository']['pullRequest']['reviewThreads']
        if threads['pageInfo']['hasNextPage']:
            return None
        return sum(1 for thread in threads['nodes'] if not thread['isResolved']
                   and any((comment.get('author') or {}).get('login') == CODEX_THREAD_AUTHOR for comment in thread['comments']['nodes']))
    except (subprocess.CalledProcessError, ValueError, KeyError, TypeError):
        # Unknown, not clean: the caller then publishes pending over any older success.
        return None


def invalidation_marker(head_sha):
    return f'<!-- codex-review-gate-invalidated:{head_sha} -->'


def invalidated(comments, head_sha):
    """True when the gate voided the review evidence for this head after Codex last updated it."""
    summary = codex_summary(comments)
    reviewed_at = (summary or {}).get('updated_at') or ''
    marker = invalidation_marker(head_sha)
    return any((comment.get('user') or {}).get('login') == ACTIONS_LOGIN and marker in (comment.get('body') or '')
               and (comment.get('created_at') or '') > reviewed_at for comment in comments)


def judge(repo, number, head, call):
    """Decide only from persistent PR state, never from the triggering event."""
    pages = json.loads(call('api', '--paginate', '--slurp', f'repos/{repo}/issues/{number}/comments'))
    comments = [comment for page in pages for comment in page]
    state = codex_state(comments)
    if invalidated(comments, head):
        return state, comments, 'pending', 'Codex review evidence was invalidated; waiting for a new review'
    if null_findings(state, head) and clean_receipt(comments, head) and unresolved_codex_threads(repo, number, call) == 0:
        # Approved by BOSS (2026-10-24): a completed review with unknown finding
        # state counts only with a clean same-commit receipt and no open Codex thread.
        return state, comments, 'success', 'Codex review completed; receipt reports no major issues'
    return (state, comments, *evaluate(state, head))


def current_status(repo, head_sha, call):
    """Latest gate status on this head; GitHub keeps at most 1000 per SHA and context."""
    # The combined-status endpoint omits the creator, so read the newest-first list.
    for status in json.loads(call('api', f'repos/{repo}/commits/{head_sha}/statuses?per_page=100')):
        if status.get('context') == CONTEXT and (status.get('creator') or {}).get('login') == ACTIONS_LOGIN:
            return status.get('state'), status.get('description')
    return None


def run(repo, number, invalidate=False, call=gh):
    pr = json.loads(call('api', f'repos/{repo}/pulls/{number}'))
    head_repo = (pr.get('head') or {}).get('repo') or {}
    base = pr.get('base') or {}
    if pr.get('state') != 'open' or head_repo.get('full_name') != repo:
        return {'pr': number, 'skipped': 'closed or cross-repository pull request'}
    # A commit status belongs to the SHA, not the PR. GitHub allows one open PR
    # per head and base, so gating only default-branch PRs keeps verdicts apart.
    if base.get('ref') != (base.get('repo') or {}).get('default_branch'):
        return {'pr': number, 'skipped': 'pull request does not target the default branch'}
    head = pr['head']['sha']
    if invalidate:
        # Record step: a deleted summary or a retargeted base voids the evidence.
        # The marker is persistent state, so the serialized gate step sees it even
        # if the run carrying this event is replaced in the queue. Asking Codex
        # again is left to the session driving the PR: Codex ignores bot requests.
        call('api', '-X', 'POST', f'repos/{repo}/issues/{number}/comments', '-f',
             f'body=Codex review evidence for this head was invalidated; a new Codex review is needed.\n\n{invalidation_marker(head)}')
        return {'pr': number, 'head': head, 'actions': ['invalidated_codex_review']}
    state, comments, status, description = judge(repo, number, head, call)
    if status == 'success':
        # Re-read right before publishing success to narrow the window for
        # evidence that changed while this run was working.
        state, comments, status, description = judge(repo, number, head, call)
    if current_status(repo, head, call) != (status, description):
        call('api', '-X', 'POST', f'repos/{repo}/statuses/{head}', '-f', f'state={status}',
             '-f', f'context={CONTEXT}', '-f', f'description={description}', '-f', f'target_url={pr["html_url"]}')
    return {'pr': number, 'head': head, 'status': status, 'description': description, 'actions': []}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--pr', required=True, type=int)
    parser.add_argument('--invalidate', action='store_true', help='only record that the current review evidence is void')
    args = parser.parse_args()
    try:
        result = run(args.repo, args.pr, args.invalidate)
    except subprocess.CalledProcessError as error:
        print(error.stderr, file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
