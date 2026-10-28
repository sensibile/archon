# ADR 0010: Codex 리뷰 게이트를 판정 전용으로 줄이고 요청·머지는 세션이 맡기

- 상태: 대체됨 ([ADR 0011](0011-local-review-auto-merge.md) 전체)
- 날짜: 2026-10-26
- 관련 PR: sensibile/archon#15 (`79f8876`)
- 대체: [ADR 0009](0009-codex-review-time-rule.md) 전체. [ADR 0008](0008-codex-review-gate-hardening.md)의 결정 1 중
  `@codex review` 요청 항목 두 개와 결정 2, 결정 4의 `AUTO_MERGE_TOKEN` 항목. ADR 0008의 판정 규칙과 결정 3은 그대로 유효하다.
- 출처: 태극(sensibile/taeguk) #16 `148be9a`, #17 `062d95d`의 `scripts/codex_review_gate.py`,
  `tests/test_codex_review_gate.py`, `.github/workflows/codex-review-gate.yml`과 `docs/repository-operations.md` PR 플로우 3~6단계

## 맥락

ADR 0009의 시간 기준 규칙은 Codex가 `github-actions[bot]`의 요청에 응답하는 것을 전제로 했다. 실제로는 응답하지 않았다
(archon PR #12, 태극 PR #3). 그래서 판정이 멈추면 이 규칙은 사실상 "약 40분 뒤 리뷰 없이 통과"로 작동했다.
반대로 사람 계정(BOSS의 `gh` 인증 계정) 요청에는 13초~2분 안에 응답했다.

2026-10-25 태극에서 추가로 관측한 것:

- PR 제목이나 본문에 `@codex` 문자열이 있으면(백틱 안 포함) PR 생성 리뷰 대신 Codex 클라우드 작업이 호출된다.
  클라우드 환경이 없을 때는 "create an environment for this repo" 안내가, 있을 때는 작업 응답이나 👀만 붙고,
  게이트가 읽을 요약과 결과 표식은 남지 않는다. archon PR #11도 같은 경우였다.
- 리뷰에는 클라우드 환경이 필요 없다. 멘션이 없는 PR은 생성 후 10~20초 안에 리뷰가 시작되고,
  새 커밋을 push하면 "New commits" 트리거로 다시 리뷰한다.
- `running`에서 멈춘 리뷰는 BOSS 계정으로 다시 요청하면 1분 안에 끝났다(태극 PR #17, 7시간 정지).

BOSS는 2026-10-25 태극에서 게이트를 판정 전용으로 줄이고 요청과 머지를 세션에 맡기기로 정했다(태극 #16, #17).
2026-10-26 같은 설정을 archon에 전파하라고 지시했다.

## 결정

1. **게이트는 `codex-review` status 판정만 한다.** 판정 규칙은 ADR 0008 결정 1과 같다. 리뷰를 요청하지 않고
   auto-merge를 켜거나 끄지 않는다. 시간 기준 규칙과 10분 주기 `schedule` 실행을 없앤다. Codex가 head를 리뷰하지 않으면
   시간이 지나도 pending이다. Codex 요약 삭제나 base 변경 때는 무효 표식 댓글만 남기고 `@codex`는 쓰지 않는다.
   `gate` job 권한은 `statuses: write` 외에는 읽기만 둔다. opt-out 이벤트(`ready_for_review`, `converted_to_draft`,
   `labeled`, `unlabeled`)는 트리거에서 뺀다.
2. **리뷰 요청은 PR을 맡은 세션이 BOSS 계정으로 한다.**
   - PR은 제목과 본문에 `@codex` 문자열 없이 연다. 2분 안에 그 head의 리뷰 요약이 붙지 않을 때만 `@codex review`를 단다.
   - 새 커밋 push 뒤나 게이트의 무효 표식 뒤에도 그 head에 한 번 요청한다. 그 head의 결과 댓글이 이미 있거나
     `running`이면 달지 않는다.
   - 10분 넘게 시작하지 않거나 `running`에서 멈추면 한 번 더 요청하고, 그래도 없으면 BOSS에게 보고한다.
     응답이 없다고 리뷰 없이 머지하지 않는다. 멈춤에는 Auto-fix 이벤트가 오지 않으므로 세션이 직접 다시 확인한다.
3. **머지도 세션이 한다.** head의 `codex-review`가 success이고 미해결 리뷰 thread가 없으면
   `gh pr merge <번호> --squash --auto --match-head-commit <head SHA>`로 리뷰한 커밋에 고정해 auto-merge를 켠다.
   draft PR과 `no-auto-merge` label이 붙은 PR에는 켜지 않는다. 사용자 토큰으로 켜므로 그 머지로 생긴 main push에도
   CI가 돈다. `AUTO_MERGE_TOKEN`은 더 쓰지 않는다.
4. **archon 차이는 `actions/checkout@v7`과 스크립트 테스트 위치(`scripts/tests/`)뿐이다.** 필수 체크 이름과 ruleset은 바꾸지 않는다.

## 대안

- **시간 기준 규칙 유지:** 리뷰 없는 통과가 사실상 기본 동작이 된다. 채택하지 않았다.
- **게이트를 모두 없애고 세션 판단만 쓰기:** 필수 체크라는 결정적 안전장치가 사라진다. 태극에서 BOSS가 택하지 않았다.

## 결과

- 세션이 없는 PR은 `codex-review`가 success여도 사람이 머지할 때까지 기다린다. 이전처럼 리뷰 없이 머지되지는 않는다.
- `AGENTS.md`의 "사용자가 요청하지 않는 한 자동 머지를 끄거나 미루지 않는다"는 원칙은 유지한다. 세션이 결정 3대로 켠다.
- `AUTO_MERGE_TOKEN` 시크릿이 등록돼 있다면 더 쓰이지 않는다. 시크릿 삭제는 BOSS 승인 사항이라 이 PR에서 하지 않았다.
- `pull_request_target`·`issue_comment` workflow는 기본 브랜치 파일로 돌기 때문에 이 ADR을 담은 PR은 기존 게이트로 판정된다.
  새 게이트는 머지 후 다음 PR에서 확인한다.
