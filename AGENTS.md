# AGENTS.md

Archon에서 일하는 에이전트(Claude Code, Codex 등)를 위한 규칙입니다.

Read `.taeguk/rules/index.md` before planning and apply Taeguk rules to explicitly assigned workflows.

## 프로젝트

Conductor OSS(`../conductor-oss`, Java/Spring)를 Elixir/OTP로 포팅합니다. 외부 계약(REST·JSON)은 upstream과
같게 유지하고, 내부는 OTP 모델로 다시 설계합니다. 기준과 단계 순서는
[ADR 0003](docs/adr/0003-porting-strategy.md)을 따릅니다.

## 결정 기록 (ADR)

- 설계·범위·도구·운영 정책을 정하거나 바꾸면 `docs/adr/`에 ADR을 쓰고 [목록](docs/adr/README.md)을 갱신합니다.
  해당 기준과 형식은 `docs/adr/README.md`에 있습니다.
- ADR은 그 결정을 구현하는 PR에 함께 넣습니다. ADR이 필요한 변경인데 빠져 있으면 PR을 완료로 보지 않습니다.
- 구현 PR이 머지되면 해당 ADR 상태를 `승인`으로 바꿉니다. 다음 PR에서 반영해도 됩니다.
- 채팅이나 다른 세션에서 합의한 결정도 저장소에 ADR로 남깁니다. 대화 기록은 결정 기록을 대신하지 않습니다.

## upstream 파생과 출처

- upstream에서 파생한 파일에는 `Copyright Conductor Authors`와 `Copyright 2026 sensibile`를 모두 적고
  수정 표시를 붙입니다([ADR 0004](docs/adr/0004-license-and-attribution.md)).
- PR의 "upstream 대응" 섹션에 참조한 소스와 커밋 SHA를 적습니다.
- REST 경로·필드명은 upstream 소스나 `priv/contract/`에서 그대로 옮깁니다. 추측해서 쓰지 않습니다.

## 검증

PR 전에 로컬에서 다음을 통과시킵니다.

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix deps.audit
```

## PR과 머지

- 브랜치는 `type/slug`, 커밋·PR 제목은 conventional 형식에 한국어 본문입니다.
  PR 본문은 `.github/pull_request_template.md`를 따릅니다.
- GitHub Codex 리뷰 gate는 없습니다. 리뷰는 push 전에 로컬에서 하고, 머지 조건은 필수 체크(`test`, `credo`, `dialyzer`, `audit`)입니다
  ([ADR 0011](docs/adr/0011-local-review-auto-merge.md)).
  1. push 전에 PR 누적 범위(`origin/main`과의 merge-base부터 head까지)를 태극 `taeguk-codex-local-review` 절차로 리뷰합니다.
     교차 리뷰는 항상, 보안 리뷰는 코드·스크립트·CI·의존성·권한처럼 실행 동작에 영향을 주는 변경에 합니다(문서만이면 NOT_APPLICABLE).
     지적은 반영하거나 반영하지 않은 이유를 PR 본문에 남깁니다.
  2. 그 head에 대한 필수 로컬 리뷰가 NOT_RUN이나 UNKNOWN이면 auto-merge를 켜지 않고 원인을 해소하거나 BOSS에게 보고합니다.
     끝났으면 PR을 만든 세션이 `gh pr merge <번호> --squash --auto --match-head-commit <리뷰한 head SHA>`로 켭니다.
     draft PR과 `no-auto-merge` label PR은 제외합니다. 사용자가 특정 PR에 대해 직접 요청하지 않는 한 머지를 미루지 않습니다.
  3. 새 커밋을 올리기 전에 `gh pr merge <번호> --disable-auto`로 끄고, 새 누적 범위를 리뷰한 뒤 push하고 다시 켭니다.
  4. `main`이 앞서 나가면 먼저 auto-merge를 끄고 `gh pr view <번호> --json autoMergeRequest`가 `null`인지 확인한 뒤
     `gh pr update-branch`로 갱신합니다. 누적 diff가 같아도 새 head로 다시 리뷰한 뒤 켭니다.
- GitHub의 Codex 자동 리뷰는 Codex 설정에서 켜져 있어 계속 댓글을 달 수 있습니다. 머지 조건은 아니지만 ruleset이 리뷰 thread
  해소를 요구하므로, 판정해 반영하거나 이유를 답한 뒤 해소합니다.
- PR 제목·본문·댓글에는 `@codex` 문자열을 쓰지 않습니다. 백틱 안에 있어도 멘션으로 읽혀 리뷰 대신
  Codex 클라우드 작업이 호출됩니다(PR #11, 태극 PR #13~#16). 가리킬 때는 "Codex 리뷰 요청"처럼 풀어 씁니다.
