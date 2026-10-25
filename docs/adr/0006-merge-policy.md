# ADR 0006: 머지 정책과 Codex 리뷰 게이트

- 상태: 승인 (결정 3·4는 [ADR 0008](0008-codex-review-gate-hardening.md)이 대체)
- 날짜: 2026-10-25
- 관련 PR: sensibile/archon#6, sensibile/archon#7
- 비고: 저장소 설정은 생성 때, Codex 게이트는 PR #6에서 구현했다. 기록은 결정 이후에 보충했다.

## 맥락

저장소 설정은 다른 sensibile 저장소(taeguk, hoplites, acropolis, thesmothetai)와 같게 맞춘다.
사용자는 "검사와 Codex 리뷰까지 통과해 지적이 없으면 자동 머지"를 원했다. GitHub 자동 머지는 PR마다 켜야 하고
필수 체크만 기다리므로, 필수 체크가 아닌 Codex 리뷰는 기다리지 않는다.

## 결정

1. **머지 방식은 squash만 허용한다.** 커밋 제목은 PR 제목, 본문은 PR 본문이다. 머지 후 브랜치는 자동 삭제한다.
2. **`main protection` ruleset**을 건다.
   - 브랜치 삭제와 force push를 막는다.
   - 반영은 PR로만 한다. 승인 수는 0이지만 리뷰 스레드는 모두 해결해야 한다.
   - 필수 체크: `test`, `credo`, `dialyzer`, `audit`, `codex-review`. strict 모드라 PR 브랜치가 main 최신이어야 한다.
   - Credo code scanning 규칙([ADR 0005](0005-static-analysis.md)).
3. **`codex-review` 커밋 상태**를 `.github/workflows/codex-review.yml`이 게시한다. Codex 요약 코멘트의
   `codex-review-state:v1` 블록을 읽어, 최신 커밋을 리뷰했고 미해결 지적이 없을 때만 `success`가 된다.
   새 커밋을 push한 뒤에는 `@codex review` 코멘트로 다시 리뷰를 요청해야 한다.
4. **자동 머지**는 `.github/workflows/auto-merge.yml`이 같은 저장소 브랜치에서 연 PR(드래프트 제외)에 켠다.
   포크 PR은 승인 리뷰 없이 머지될 수 있어 제외한다.
5. **사람이나 에이전트가 PR별로 머지를 막지 않는다.** 머지 게이트는 필수 체크와 Codex 리뷰다.
   예외는 사용자가 특정 PR에 대해 직접 요청한 경우뿐이다.

## 대안

- **사람이 매번 머지:** 사용자가 원하는 흐름이 아니라 채택하지 않았다.
- **Codex 리뷰를 필수 체크 없이 자동 머지만 켜기:** Codex 리뷰가 끝나기 전에 머지되므로 채택하지 않았다.

## 결과

- `GITHUB_TOKEN`으로 켠 자동 머지가 머지하면 그 push로는 main CI가 돌지 않는다(GitHub의 재귀 방지).
  `AUTO_MERGE_TOKEN` 시크릿(fine-grained PAT, contents·pull requests 읽기/쓰기)을 넣으면 해결된다. 아직 넣지 않았다.
- 2026-10-25 Phase 1 작업 지시에 "머지하지 말라"는 조건이 들어가 PR #8의 자동 머지가 꺼진 일이 있었다.
  결정 5는 이 일을 막기 위한 것이다.
