# ADR 0008: Codex 리뷰 게이트 보강

- 상태: 승인
- 날짜: 2026-10-25
- 관련 PR: sensibile/archon#11
- 보완: [ADR 0009](0009-codex-review-time-rule.md)가 멈춘 리뷰 처리를 정한다.
- 대체: [ADR 0006](0006-merge-policy.md)의 결정 3·4. 결정 1·2·5는 그대로 유효하다.
- 출처: 태극(sensibile/taeguk) `.github/workflows/codex-review-gate.yml`, `scripts/codex_review_gate.py`,
  `tests/test_codex_review_gate.py`, 기준 커밋 `44dfb55`

## 맥락

ADR 0006의 게이트는 태극 게이트를 단순화해 만들었고, 태극에서 이미 고친 문제가 빠져 있었다.

- Codex가 지적 없이 끝난 리뷰에 `has_unresolved_findings: null`을 남기면 archon 게이트는 failure를 냈다.
- 새 커밋을 push할 때마다 사람이나 에이전트가 `@codex review`를 직접 달아야 했다.
- auto-merge를 PR을 열 때 켜서, 리뷰하지 않은 커밋이 리뷰 전에 머지 대상에 올라 있었다. 필수 체크가 막긴 하지만
  머지 대상 커밋을 리뷰한 커밋으로 고정하지 않았다.
- draft·label로 자동 머지를 빼는 방법, Codex 요약 삭제나 base 변경 때 이전 리뷰를 무효로 하는 처리가 없었다.
- 게이트가 `pull_request` 이벤트로도 돌아 PR이 자기 판정 코드를 바꿀 수 있었다.

2026-10-25 PR #9에서 Codex 리뷰가 50분 넘게 `running`에 멈췄고 수동 `@codex review`로 다시 시작됐다.
BOSS는 이를 반복되는 문제로 보고 archon 게이트를 태극 수준으로 맞추라고 지시했다.

## 결정

1. **태극 게이트를 그대로 가져온다.** `.github/workflows/codex-review-gate.yml`과 `scripts/codex_review_gate.py`가
   `.github/workflows/codex-review.yml`과 `.github/workflows/auto-merge.yml`을 대체한다. 판정 규칙은 다음과 같다.
   - head 커밋에 대한 Codex 리뷰가 `completed`이고 `has_unresolved_findings: false`이면 success,
     `true`이면 failure, 그 밖에는 pending이다. 요약 표식을 읽을 수 없으면 pending이다.
   - `has_unresolved_findings: null`이면, 같은 head 커밋에 대한 Codex의 최신 결과 댓글이
     "Didn't find any major issues"이고 Codex가 시작한 미해결 리뷰 thread가 0개일 때만 success다.
     둘 중 하나라도 확인할 수 없으면 pending이다. 태극에서 2026-10-24 BOSS가 승인한 기준이며,
     이번 지시로 archon에도 적용한다.
   - 이전 커밋을 리뷰한 상태에서 새 head가 오면 workflow가 head마다 한 번 `@codex review`를 단다.
     댓글의 head SHA 표식으로 중복을 막는다. 새 PR은 Codex가 스스로 리뷰하므로 요청하지 않는다.
   - Codex 요약 댓글이 삭제되거나 PR base가 바뀌면 무효 표식과 함께 `@codex review`를 달고,
     Codex가 요약을 갱신할 때까지 pending이다.
2. **auto-merge는 `codex-review`가 success가 된 뒤 켠다.** `gh pr merge --auto --squash --match-head-commit <head>`로
   리뷰한 커밋에 고정한다. draft PR과 `no-auto-merge` label이 붙은 PR은 켜지 않고, 이미 켜져 있으면 끈다.
3. **게이트는 `pull_request_target`과 `issue_comment`로만 돈다.** 둘 다 기본 브랜치의 workflow와 스크립트를
   실행하므로 PR이 자기 판정을 바꿀 수 없다. fork PR과 기본 브랜치가 아닌 base로 향하는 PR은 처리하지 않는다.
4. **archon 차이만 맞춘다.**
   - 머지 호출에만 `AUTO_MERGE_TOKEN` 시크릿을 쓰고, 없으면 `GITHUB_TOKEN`을 쓴다(ADR 0006 결과 참고).
     댓글과 상태는 `github-actions[bot]`으로 남긴다. 표식 확인이 그 작성자를 전제로 하기 때문이다.
   - 스크립트 테스트(`scripts/tests/`)는 CI `test` job에서 `python3 -m unittest`로 돌린다.
   - 필수 체크 이름(`test`, `credo`, `dialyzer`, `audit`, `codex-review`)과 ruleset은 바꾸지 않는다.

## 대안

- **archon 게이트를 JavaScript(`actions/github-script`)로 유지하고 기능만 덧붙이기:** 태극과 판정 코드가 갈라져
  태극의 수정을 다시 옮겨야 한다. 태극 구현과 테스트를 그대로 쓰는 쪽을 택했다. Elixir 저장소에 Python 스크립트가
  하나 늘지만 runner에 기본으로 있고 의존성이 없다.
- **auto-merge를 PR 열 때 계속 켜기:** 필수 체크가 머지를 막지만, 리뷰한 커밋에 머지를 고정하지 못한다.

## 결과

- 리뷰 thread 해결 이벤트로는 게이트가 다시 돌지 않는다. `null` 판정에서 thread를 해결한 뒤에는 다음 이벤트
  (Codex 댓글 수정, push, label 등)가 있어야 다시 판정한다.
- `no-auto-merge` label은 GitHub의 머지 조건이 아니다. workflow가 돈 뒤에 적용되므로 그 사이 마지막 필수 체크가 끝나면
  머지될 수 있다. 확실히 멈추려면 PR을 draft로 바꾼다.
- Codex 요약의 상태 표식은 공개 API가 아니다. 형식이 바뀌면 게이트는 pending에 머물고, 사람이 결과를 확인해 머지한다.
- 게이트는 저장소 writer를 신뢰하는 자동화다. push 권한이 있으면 다른 workflow로 상태를 게시할 수 있다.
- `pull_request_target`·`issue_comment` workflow는 기본 브랜치 파일로 돌기 때문에 이 ADR을 담은 PR 안에서는
  새 게이트가 실행되지 않는다. 실제 동작은 머지 후 sensibile/archon#12에서 확인했다.
- **멈춘 리뷰 재요청은 넣지 않았다(제안).** Codex 리뷰가 `running`에 머물면 게이트를 깨울 이벤트가 없다.
  이를 처리하려면 예약 실행(`schedule`)으로 열린 PR을 훑어, head 리뷰가 임계값 이상 `running`이면 head와 요약 시각마다
  한 번 `@codex review`를 다는 job이 필요하다. 임계값은 BOSS가 정한다. 근거로 2026-10-16~25 archon·태극 요약 댓글
  수정 기록을 보면 리뷰 시작에서 첫 결과까지 대부분 15초~2분, 길어도 약 6분이었고, PR #9의 정지는 약 50분이었다.
  넣는다면 기본값으로 임계값 15분, 실행 주기 10분, head당 재요청 최대 2회를 제안한다.
