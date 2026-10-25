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
- 머지는 필수 체크와 Codex 리뷰를 통과하면 PR을 맡은 세션이 켭니다([ADR 0010](docs/adr/0010-codex-gate-status-only.md)).
  head의 `codex-review`가 success이고 미해결 리뷰 thread가 없으면 `gh pr merge <번호> --squash --auto --match-head-commit <head SHA>`로
  켭니다. draft PR과 `no-auto-merge` label PR은 제외합니다. 사용자가 특정 PR에 대해 직접 요청하지 않는 한 머지를 미루지 않습니다.
- gate workflow는 `codex-review` status 판정만 합니다. 리뷰를 요청하지 않고, 판정이 없으면 시간이 지나도 pending입니다.
- 리뷰 요청은 세션이 `gh` 계정으로 합니다. Codex는 gate(`github-actions[bot]`)의 요청을 무시합니다. PR은 멘션 없이 열고
  2분 안에 리뷰 요약이 붙지 않을 때만 `@codex review`를 답니다. 새 커밋 push 뒤나 gate의 무효 표식 뒤에도 그 head에 한 번
  답니다. 그 head의 Codex 결과 댓글이 이미 있거나 리뷰가 `running`이면 달지 않습니다. 10분 넘게 멈추면 한 번 더 달고,
  그래도 응답이 없으면 BOSS에게 보고합니다. 멈춤에는 Auto-fix 이벤트가 오지 않으므로 세션이 직접 다시 확인합니다.
- PR 제목·본문·댓글에는 리뷰 요청 댓글 말고는 `@codex` 문자열을 쓰지 않습니다. 백틱 안에 있어도 멘션으로 읽혀 리뷰 대신
  Codex 클라우드 작업이 호출됩니다(PR #11, 태극 PR #13~#16). 가리킬 때는 "Codex 리뷰 요청"처럼 풀어 씁니다.
