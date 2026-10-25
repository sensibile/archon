#!/usr/bin/env python3
"""Publish the Codex review result for a PR head as the `codex-review` commit status."""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
import re
import subprocess
import sys

CONTEXT = 'codex-review'
CODEX_LOGIN = 'chatgpt-codex-connector[bot]'
CODEX_APP = 'chatgpt-codex-connector'
ACTIONS_LOGIN = 'github-actions[bot]'
NO_AUTO_MERGE_LABEL = 'no-auto-merge'
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


# Time rule approved by BOSS (2026-10-25): with no Codex verdict, ask again
# every REQUEST_INTERVAL; after MAX_REQUESTS unanswered requests, pass.
REQUEST_INTERVAL = timedelta(minutes=10)
MAX_REQUESTS = 3


def gh(*args, token=None):
    env = {**os.environ, 'GH_TOKEN': token} if token else None
    result = subprocess.run(['gh', *args], capture_output=True, text=True, check=True, env=env)
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


def request_marker(head_sha):
    return f'<!-- codex-review-gate-request:{head_sha} -->'


def invalidation_marker(head_sha):
    return f'<!-- codex-review-gate-invalidated:{head_sha} -->'


def invalidated(comments, head_sha):
    """True when the gate voided the review evidence for this head after Codex last updated it."""
    summary = codex_summary(comments)
    reviewed_at = (summary or {}).get('updated_at') or ''
    marker = invalidation_marker(head_sha)
    return any((comment.get('user') or {}).get('login') == ACTIONS_LOGIN and marker in (comment.get('body') or '')
               and (comment.get('created_at') or '') > reviewed_at for comment in comments)


def parse_time(value):
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00')) if value else None
    except ValueError:
        return None


def gate_requests(comments, head_sha):
    """Times of the gate's own review requests for this head since its last invalidation.

    Returns None when a request has no readable time, so nothing is counted on guesswork.
    """
    markers = (request_marker(head_sha), invalidation_marker(head_sha))
    found = []
    for comment in comments:
        body = comment.get('body') or ''
        if (comment.get('user') or {}).get('login') != ACTIONS_LOGIN or not any(marker in body for marker in markers):
            continue
        created = parse_time(comment.get('created_at'))
        if created is None:
            return None
        found.append((created, invalidation_marker(head_sha) in body))
    voided_at = max((created for created, invalidation in found if invalidation), default=None)
    return sorted(created for created, _ in found if voided_at is None or created >= voided_at)


def first_gate_status(repo, head_sha, call):
    """When the gate first published a status for this head: the time rule's starting point."""
    pages = json.loads(call('api', '--paginate', '--slurp', f'repos/{repo}/commits/{head_sha}/statuses'))
    times = [parse_time(status.get('created_at')) for page in pages for status in page
             if status.get('context') == CONTEXT and (status.get('creator') or {}).get('login') == ACTIONS_LOGIN]
    times = [time for time in times if time is not None]
    return min(times) if times else None


def current_status(repo, head_sha, call):
    """Latest gate status on this head; GitHub keeps at most 1000 per SHA and context."""
    # The combined-status endpoint omits the creator, so read the newest-first list.
    for status in json.loads(call('api', f'repos/{repo}/commits/{head_sha}/statuses?per_page=100')):
        if status.get('context') == CONTEXT and (status.get('creator') or {}).get('login') == ACTIONS_LOGIN:
            return status.get('state'), status.get('description')
    return None


def opted_out(pr):
    return bool(pr.get('draft')) or NO_AUTO_MERGE_LABEL in {label.get('name') for label in pr.get('labels') or []}


def needs_review_request(state, comments, head_sha):
    """Ask again only after Codex reviewed an older head; it reviews new PRs by itself."""
    review = (state or {}).get('code_review')
    if not isinstance(review, dict) or not review.get('commit_sha') or review.get('commit_sha') == head_sha:
        return False
    marker = request_marker(head_sha)
    return not any((comment.get('user') or {}).get('login') == ACTIONS_LOGIN and marker in (comment.get('body') or '')
                   for comment in comments)


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


def time_rule_applies(state, comments, head_sha):
    """Only the approved stalls: no review yet for this head, a running review,
    or a completed review with explicit null findings and no receipt at all.
    Unreadable states, and any receipt Codex did post, stay pending."""
    if newest_receipt(comments, head_sha) is not None:
        return False  # Codex answered for this head; that is not "no verdict".
    if state is None:
        return True
    review = state.get('code_review')
    if not isinstance(review, dict) or not isinstance(review.get('commit_sha'), str):
        return False
    if review['commit_sha'] != head_sha:
        return True
    if review.get('status') == 'running':
        return True
    return null_findings(state, head_sha)


def decide(repo, number, head, call, now, request_review):
    """Return (state, comments, status, description, ask_codex)."""
    state, comments, status, description = judge(repo, number, head, call)
    if status != 'pending' or not request_review:
        return state, comments, status, description, False
    requests = gate_requests(comments, head)
    if requests is None:
        return state, comments, status, description, False
    if not requests and needs_review_request(state, comments, head):
        return state, comments, status, description, True
    if not time_rule_applies(state, comments, head):
        return state, comments, status, description, False
    anchor = requests[-1] if requests else first_gate_status(repo, head, call)
    if anchor is None or now - anchor < REQUEST_INTERVAL:
        return state, comments, status, description, False
    if len(requests) < MAX_REQUESTS:
        return state, comments, status, f'{description}; asking Codex again ({len(requests) + 1}/{MAX_REQUESTS})'[:140], True
    threads = unresolved_codex_threads(repo, number, call)
    if threads == 0:
        return state, comments, 'success', f'No Codex verdict after {MAX_REQUESTS} requests; passed by the time rule', False
    if threads:
        return state, comments, 'failure', 'Codex left unresolved review threads', False
    return state, comments, status, description, False


def run(repo, number, request_review=False, auto_merge=False, invalidate=False, now=None, call=gh, merge=None):
    # Merges performed through GITHUB_TOKEN do not trigger the push-to-main CI run, so auto-merge
    # may use a separate user token; comments and statuses stay with github-actions[bot].
    merge = merge or call
    now = now or datetime.now(timezone.utc)
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
    actions = []
    if invalidate:
        # Record step: a deleted summary or a retargeted base voids the evidence.
        # The marker is persistent state, so the serialized gate step sees it even
        # if the run carrying this event is replaced in the queue.
        call('api', '-X', 'POST', f'repos/{repo}/issues/{number}/comments', '-f', f'body=@codex review\n\n{invalidation_marker(head)}')
        actions.append('invalidated_codex_review')
        return {'pr': number, 'head': head, 'actions': actions}
    state, comments, status, description, ask_codex = decide(repo, number, head, call, now, request_review)
    if status == 'success':
        # Re-read right before publishing success to narrow the window for
        # evidence that changed while this run was working.
        state, comments, status, description, ask_codex = decide(repo, number, head, call, now, request_review)
    if auto_merge and opted_out(pr) and pr.get('auto_merge'):
        # Before the status: a success could otherwise merge the PR first. A
        # failed disable raises here, so no status is published.
        merge('pr', 'merge', str(number), '--repo', repo, '--disable-auto')
        actions.append('disabled_auto_merge')
    if current_status(repo, head, call) != (status, description):
        call('api', '-X', 'POST', f'repos/{repo}/statuses/{head}', '-f', f'state={status}',
             '-f', f'context={CONTEXT}', '-f', f'description={description}', '-f', f'target_url={pr["html_url"]}')
    if ask_codex and status == 'pending':
        call('api', '-X', 'POST', f'repos/{repo}/issues/{number}/comments', '-f', f'body=@codex review\n\n{request_marker(head)}')
        actions.append('requested_codex_review')
    if auto_merge and status == 'success' and not opted_out(pr) and not pr.get('auto_merge'):
        # Re-read just before enabling to narrow the window for a new opt-out or
        # push; draft is the only opt-out GitHub itself enforces at merge time.
        latest = json.loads(call('api', f'repos/{repo}/pulls/{number}'))
        if not opted_out(latest) and latest['head']['sha'] == head and not latest.get('auto_merge'):
            # Bind the merge to the reviewed commit so a later push cannot ride along.
            merge('pr', 'merge', str(number), '--repo', repo, '--auto', '--squash', '--match-head-commit', head)
            actions.append('enabled_auto_merge')
    return {'pr': number, 'head': head, 'status': status, 'description': description, 'actions': actions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--pr', required=True, type=int)
    parser.add_argument('--request-review', action='store_true', help='comment @codex review once per head after Codex reviewed an older head')
    parser.add_argument('--auto-merge', action='store_true', help='enable squash auto-merge once the gate succeeds')
    parser.add_argument('--invalidate', action='store_true', help='only record that the current review evidence is void and request a new review')
    args = parser.parse_args()
    token = os.environ.get('AUTO_MERGE_TOKEN')
    merge = (lambda *call_args: gh(*call_args, token=token)) if token else None
    try:
        result = run(args.repo, args.pr, args.request_review, args.auto_merge, args.invalidate, merge=merge)
    except subprocess.CalledProcessError as error:
        print(error.stderr, file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
