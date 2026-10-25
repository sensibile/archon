"""Behavior tests for the Codex review commit-status gate."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('codex_review_gate', SOURCE/'codex_review_gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

REPO = 'sensibile/archon'
HEAD = '35d05426adb5f016361be16932ef23f7222095b6'


def state_comment(sha=HEAD, status='completed', unresolved=False, updated='2026-10-23T04:38:05Z', login=gate.CODEX_LOGIN, app=gate.CODEX_APP):
    state = {'code_review': {'commit_sha': sha, 'has_any_findings': bool(unresolved), 'has_unresolved_findings': unresolved, 'status': status},
             'security_review': {'commit_sha': None, 'has_any_findings': None, 'has_unresolved_findings': None, 'status': None}}
    return {'user': {'login': login, 'type': 'Bot'}, 'performed_via_github_app': {'slug': app} if app else None, 'updated_at': updated,
            'body': f'<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 {json.dumps(state)} -->\n\n## Codex Review Summary'}


class FakeGitHub:
    def __init__(self, comments, draft=False, labels=(), head_repo=REPO, auto_merge=None, base='main', later=(), later_comments=None,
                 threads=(), more_threads=False, threads_error=False):
        self.pr = {'state': 'open', 'draft': draft, 'html_url': f'https://github.com/{REPO}/pull/9', 'auto_merge': auto_merge,
                   'labels': [{'name': name} for name in labels], 'head': {'sha': HEAD, 'repo': {'full_name': head_repo}},
                   'base': {'ref': base, 'repo': {'default_branch': 'main'}}}
        self.comments = comments
        self.later = list(later)  # PR changes seen by each later fetch
        self.later_comments = later_comments  # comments seen by every fetch after the first
        self.threads = {'pageInfo': {'hasNextPage': more_threads}, 'nodes': list(threads)}
        self.threads_error = threads_error
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        if args == ('api', f'repos/{REPO}/pulls/9'):
            if len(self.called(args)) > 1 and self.later:
                self.pr = {**self.pr, **self.later.pop(0)}
            return json.dumps(self.pr)
        if args[:3] == ('api', '--paginate', '--slurp'):
            if len(self.called(args)) > 1 and self.later_comments is not None:
                return json.dumps([self.later_comments])
            return json.dumps([self.comments])
        if args[:2] == ('api', 'graphql'):
            if self.threads_error:
                raise subprocess.CalledProcessError(1, ['gh', *args], stderr='HTTP 502')
            return json.dumps({'data': {'repository': {'pullRequest': {'reviewThreads': self.threads}}}})
        return '{}'

    def posted_status(self):
        return [dict(field.split('=', 1) for field in call[5::2]) for call in self.calls if call[:4] == ('api', '-X', 'POST', f'repos/{REPO}/statuses/{HEAD}')]

    def called(self, prefix):
        return [call for call in self.calls if call[:len(prefix)] == prefix]


def receipt(sha=HEAD[:10], text="Codex Review: Didn't find any major issues. :rocket:", login=gate.CODEX_LOGIN, app=gate.CODEX_APP):
    return {'user': {'login': login, 'type': 'Bot'}, 'performed_via_github_app': {'slug': app}, 'updated_at': '2026-10-24T02:45:39Z',
            'body': f'<!-- codex-review-receipt:v1 -->\n\n{text}\n\n**Reviewed commit:** `{sha}`'}


def thread(resolved, author='chatgpt-codex-connector'):
    return {'isResolved': resolved, 'comments': {'nodes': [{'author': {'login': author}}]}}


def missing_findings_field():
    # Only an explicit null was approved; a dropped field is a format change.
    comment = state_comment(unresolved=None)
    return {**comment, 'body': comment['body'].replace('"has_unresolved_findings": null, ', '')}


class NullFindingsTests(unittest.TestCase):
    # Codex sometimes completes a clean review with has_unresolved_findings: null
    # (PR #3, cf3a08f). BOSS approved success only with a clean same-commit
    # receipt and no unresolved Codex threads; anything else stays pending.
    def status(self, comments, **github):
        fake = FakeGitHub(comments, **github)
        gate.run(REPO, 9, call=fake)
        return fake.posted_status()[0]['state'], fake

    def test_clean_receipt_and_no_unresolved_codex_threads_succeed(self):
        state, _ = self.status([state_comment(unresolved=None), receipt()], threads=[thread(True), thread(False, author='sensibile')])
        self.assertEqual(state, 'success')

    def test_missing_or_weak_evidence_stays_pending(self):
        cases = {'no receipt': ([state_comment(unresolved=None)], {}),
                 'receipt for other commit': ([state_comment(unresolved=None), receipt(sha='0' * 10)], {}),
                 'receipt with suggestions': ([state_comment(unresolved=None), receipt(text='Here are some automated review suggestions for this pull request.')], {}),
                 'receipt not by codex': ([state_comment(unresolved=None), receipt(login='mallory')], {}),
                 'receipt from other app': ([state_comment(unresolved=None), receipt(app='other-app')], {}),
                 'short commit prefix': ([state_comment(unresolved=None), receipt(sha=HEAD[:4])], {}),
                 'unresolved codex thread': ([state_comment(unresolved=None), receipt()], {'threads': [thread(False)]}),
                 'threads not fully listed': ([state_comment(unresolved=None), receipt()], {'more_threads': True}),
                 'thread lookup failed': ([state_comment(unresolved=None), receipt()], {'threads_error': True}),
                 'finding field missing': ([missing_findings_field(), receipt()], {}),
                 'receipt text echoed in a reply': ([state_comment(unresolved=None), {**receipt(), 'body': "Sure, here is what you asked:\n> <!-- codex-review-receipt:v1 -->\n> Codex Review: Didn't find any major issues\n> **Reviewed commit:** `" + HEAD[:10] + "`"}], {})}
        for name, (comments, github) in cases.items():
            with self.subTest(name):
                self.assertEqual(self.status(comments, **github)[0], 'pending')

    def test_newest_receipt_for_the_head_decides(self):
        older = {**receipt(), 'updated_at': '2026-10-24T01:00:00Z'}
        newer = {**receipt(text='Here are some automated review suggestions for this pull request.'), 'updated_at': '2026-10-24T03:00:00Z'}
        self.assertEqual(self.status([state_comment(unresolved=None), older, newer])[0], 'pending')

    def test_explicit_false_does_not_query_threads(self):
        state, fake = self.status([state_comment()])
        self.assertEqual(state, 'success')
        self.assertEqual(fake.called(('api', 'graphql')), [])


class EvaluateTests(unittest.TestCase):
    def test_completed_review_of_head_without_unresolved_findings_succeeds(self):
        self.assertEqual(gate.evaluate(gate.codex_state([state_comment()]), HEAD)[0], 'success')

    def test_unresolved_findings_fail(self):
        self.assertEqual(gate.evaluate(gate.codex_state([state_comment(unresolved=True)]), HEAD)[0], 'failure')

    def test_unproven_states_stay_pending(self):
        cases = {'no comment': [], 'other commit': [state_comment(sha='0' * 40)], 'in progress': [state_comment(status='in_progress')],
                 'unknown findings': [state_comment(unresolved=None)],
                 'broken marker': [{**state_comment(), 'body': '<!-- codex-review-state:v1 {not json} -->'}]}
        for name, comments in cases.items():
            with self.subTest(name):
                self.assertEqual(gate.evaluate(gate.codex_state(comments), HEAD)[0], 'pending')

    def test_marker_from_non_codex_author_is_ignored(self):
        forged = [state_comment(login='mallory'), state_comment(app=None), state_comment(app='other-app')]
        self.assertIsNone(gate.codex_state(forged))

    def test_unreadable_newest_summary_does_not_fall_back_to_older_success(self):
        newest = state_comment(updated='2026-10-23T05:00:00Z')
        for name, body in {'broken json': '<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 {not json} -->',
                           'marker removed': '<!-- codex-pull-request-review-summary -->\n## Codex Review Summary',
                           'marker renamed': '<!-- codex-review-state:v2 {"code_review": {}} -->'}.items():
            with self.subTest(name):
                comments = [state_comment(updated='2026-10-23T04:00:00Z'), {**newest, 'body': body}]
                self.assertEqual(gate.evaluate(gate.codex_state(comments), HEAD)[0], 'pending')

    def test_unrelated_codex_comment_does_not_hide_summary(self):
        receipt = {**state_comment(updated='2026-10-23T06:00:00Z'), 'body': '<!-- codex-review-receipt:v1 -->\n\nCodex Review: no major issues.'}
        self.assertEqual(gate.evaluate(gate.codex_state([state_comment(), receipt]), HEAD)[0], 'success')

    def test_newest_codex_state_wins(self):
        comments = [state_comment(unresolved=True, updated='2026-10-23T04:00:00Z'), state_comment(updated='2026-10-23T05:00:00Z')]
        self.assertEqual(gate.evaluate(gate.codex_state(comments), HEAD)[0], 'success')


class RunTests(unittest.TestCase):
    def test_success_posts_status_and_enables_auto_merge_bound_to_head(self):
        github = FakeGitHub([state_comment()])
        result = gate.run(REPO, 9, auto_merge=True, call=github)
        self.assertEqual(github.posted_status(), [{'state': 'success', 'context': 'codex-review', 'description': 'Codex review completed with no unresolved findings', 'target_url': github.pr['html_url']}])
        self.assertEqual(github.called(('pr', 'merge')), [('pr', 'merge', '9', '--repo', REPO, '--auto', '--squash', '--match-head-commit', HEAD)])
        self.assertEqual(result['actions'], ['enabled_auto_merge'])

    def test_auto_merge_calls_use_the_merge_runner(self):
        # AUTO_MERGE_TOKEN merges as a user so the push to main runs CI; everything else stays on the default runner.
        github, merges = FakeGitHub([state_comment()]), []
        gate.run(REPO, 9, auto_merge=True, call=github, merge=lambda *args: merges.append(args))
        self.assertEqual(merges, [('pr', 'merge', '9', '--repo', REPO, '--auto', '--squash', '--match-head-commit', HEAD)])
        self.assertEqual(github.called(('pr', 'merge')), [])
        self.assertEqual(github.posted_status()[0]['state'], 'success')

    def test_pending_review_never_enables_auto_merge(self):
        github = FakeGitHub([state_comment(status='in_progress')])
        gate.run(REPO, 9, auto_merge=True, call=github)
        self.assertEqual(github.posted_status()[0]['state'], 'pending')
        self.assertEqual(github.called(('pr', 'merge')), [])

    def test_opt_outs_keep_status_but_skip_auto_merge(self):
        for name, github in {'draft': FakeGitHub([state_comment()], draft=True),
                             'label': FakeGitHub([state_comment()], labels=[gate.NO_AUTO_MERGE_LABEL]),
                             'already enabled': FakeGitHub([state_comment()], auto_merge={'merge_method': 'squash'})}.items():
            with self.subTest(name):
                gate.run(REPO, 9, auto_merge=True, call=github)
                self.assertEqual(github.posted_status()[0]['state'], 'success')
                self.assertEqual(github.called(('pr', 'merge')), [])

    def test_opt_out_disables_auto_merge_already_enabled(self):
        for name, github in {'draft': FakeGitHub([state_comment()], draft=True, auto_merge={'merge_method': 'squash'}),
                             'label': FakeGitHub([state_comment()], labels=[gate.NO_AUTO_MERGE_LABEL], auto_merge={'merge_method': 'squash'})}.items():
            with self.subTest(name):
                result = gate.run(REPO, 9, auto_merge=True, call=github)
                self.assertEqual(github.called(('pr', 'merge')), [('pr', 'merge', '9', '--repo', REPO, '--disable-auto')])
                self.assertEqual(result['actions'], ['disabled_auto_merge'])
                # Disable first: a success status could otherwise merge the PR before the opt-out lands.
                disable = github.calls.index(('pr', 'merge', '9', '--repo', REPO, '--disable-auto'))
                status = next(i for i, call in enumerate(github.calls) if call[:3] == ('api', '-X', 'POST') and 'statuses' in call[3])
                self.assertLess(disable, status)

    def requests(self, github):
        return github.called(('api', '-X', 'POST', f'repos/{REPO}/issues/9/comments'))

    def test_head_after_an_older_review_requests_codex_review_with_head_marker(self):
        github = FakeGitHub([state_comment(sha='0' * 40)])
        result = gate.run(REPO, 9, request_review=True, call=github)
        self.assertEqual(self.requests(github), [('api', '-X', 'POST', f'repos/{REPO}/issues/9/comments', '-f', f'body=@codex review\n\n<!-- codex-review-gate-request:{HEAD} -->')])
        self.assertEqual(result['actions'], ['requested_codex_review'])

    def test_review_request_is_not_repeated_for_the_same_head(self):
        mine = {'user': {'login': gate.ACTIONS_LOGIN, 'type': 'Bot'}, 'body': f'@codex review\n\n<!-- codex-review-gate-request:{HEAD} -->'}
        github = FakeGitHub([state_comment(sha='0' * 40), mine])
        gate.run(REPO, 9, request_review=True, call=github)
        self.assertEqual(self.requests(github), [])

    def test_other_authors_cannot_suppress_the_request(self):
        forged = {'user': {'login': 'mallory', 'type': 'User'}, 'body': f'<!-- codex-review-gate-request:{HEAD} -->'}
        github = FakeGitHub([state_comment(sha='0' * 40), forged])
        gate.run(REPO, 9, request_review=True, call=github)
        self.assertEqual(len(self.requests(github)), 1)

    def test_no_request_when_codex_has_not_reviewed_or_already_covers_head(self):
        # Codex reviews a newly opened PR by itself; an unreadable summary is not an old commit.
        for name, comments in {'never reviewed': [], 'in progress for head': [state_comment(status='in_progress')],
                               'unreadable': [{**state_comment(), 'body': '<!-- codex-pull-request-review-summary -->'}]}.items():
            with self.subTest(name):
                github = FakeGitHub(comments)
                gate.run(REPO, 9, request_review=True, call=github)
                self.assertEqual(self.requests(github), [])

    def test_pull_request_to_non_default_base_is_skipped(self):
        # A commit status is per SHA; another base sharing the head must not overwrite main's verdict.
        github = FakeGitHub([state_comment()], base='release')
        self.assertIn('skipped', gate.run(REPO, 9, auto_merge=True, call=github))
        self.assertEqual(github.posted_status(), [])

    def invalidation(self, created, head=HEAD, login=gate.ACTIONS_LOGIN):
        return {'user': {'login': login, 'type': 'Bot'}, 'created_at': created, 'updated_at': created,
                'body': f'@codex review\n\n<!-- codex-review-gate-invalidated:{head} -->'}

    def test_invalidation_after_the_summary_keeps_the_gate_pending(self):
        # Covers a deleted newest summary and a retargeted base: older evidence must not count.
        github = FakeGitHub([state_comment(updated='2026-10-23T04:00:00Z'), self.invalidation('2026-10-23T05:00:00Z')])
        gate.run(REPO, 9, auto_merge=True, call=github)
        self.assertEqual(github.posted_status()[0]['state'], 'pending')
        self.assertEqual(github.called(('pr', 'merge')), [])

    def test_review_after_invalidation_counts_again(self):
        github = FakeGitHub([self.invalidation('2026-10-23T04:00:00Z'), state_comment(updated='2026-10-23T05:00:00Z')])
        gate.run(REPO, 9, call=github)
        self.assertEqual(github.posted_status()[0]['state'], 'success')

    def test_invalidation_by_other_author_or_for_other_head_is_ignored(self):
        for name, marker in {'author': self.invalidation('2026-10-23T05:00:00Z', login='mallory'),
                             'head': self.invalidation('2026-10-23T05:00:00Z', head='0' * 40)}.items():
            with self.subTest(name):
                github = FakeGitHub([state_comment(updated='2026-10-23T04:00:00Z'), marker])
                gate.run(REPO, 9, call=github)
                self.assertEqual(github.posted_status()[0]['state'], 'success')

    def test_invalidate_only_records_the_marker(self):
        # The record step runs unserialized; only the serialized gate step publishes.
        github = FakeGitHub([state_comment()])
        result = gate.run(REPO, 9, auto_merge=True, invalidate=True, call=github)
        self.assertEqual(github.called(('api', '-X', 'POST', f'repos/{REPO}/issues/9/comments')),
                         [('api', '-X', 'POST', f'repos/{REPO}/issues/9/comments', '-f', f'body=@codex review\n\n<!-- codex-review-gate-invalidated:{HEAD} -->')])
        self.assertEqual(github.posted_status(), [])
        self.assertEqual(github.called(('pr', 'merge')), [])
        self.assertEqual(result['actions'], ['invalidated_codex_review'])

    def test_success_is_rechecked_against_comments_changed_during_the_run(self):
        # Runs are not serialized: a parallel run may void the evidence after this one read it.
        changed = {'invalidated': [state_comment(updated='2026-10-23T04:00:00Z'), self.invalidation('2026-10-23T05:00:00Z')],
                   'summary deleted': []}
        for name, comments in changed.items():
            with self.subTest(name):
                github = FakeGitHub([state_comment(updated='2026-10-23T04:00:00Z')], later_comments=comments)
                result = gate.run(REPO, 9, auto_merge=True, call=github)
                self.assertEqual(github.posted_status()[0]['state'], 'pending')
                self.assertEqual(github.called(('pr', 'merge')), [])
                self.assertEqual(result['status'], 'pending')

    def test_opt_out_added_during_the_run_blocks_enabling(self):
        for name, change in {'label': {'labels': [{'name': gate.NO_AUTO_MERGE_LABEL}]}, 'draft': {'draft': True},
                             'new head': {'head': {'sha': '1' * 40, 'repo': {'full_name': REPO}}}}.items():
            with self.subTest(name):
                github = FakeGitHub([state_comment()], later=[change])
                result = gate.run(REPO, 9, auto_merge=True, call=github)
                self.assertEqual(github.called(('pr', 'merge')), [])
                self.assertEqual(result['actions'], [])

    def test_cross_repository_pull_request_is_skipped(self):
        github = FakeGitHub([state_comment()], head_repo='someone/fork')
        self.assertIn('skipped', gate.run(REPO, 9, auto_merge=True, call=github))
        self.assertEqual(github.posted_status(), [])


if __name__ == '__main__':
    unittest.main()
