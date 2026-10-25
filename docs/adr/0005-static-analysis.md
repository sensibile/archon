# ADR 0005: CodeQL 대신 쓰는 정적 분석

- 상태: 승인
- 날짜: 2026-10-25
- 관련 PR: sensibile/archon#4
- 비고: PR #4에서 구현했다. 기록은 결정 이후에 보충했다.

## 맥락

다른 sensibile 저장소의 `main protection` ruleset은 CodeQL code scanning 규칙을 건다. CodeQL은 Elixir를
지원하지 않아서, 같은 규칙을 archon에 걸면 결과가 올라오지 않아 PR이 막힐 수 있다. 사용자는 CodeQL이
없더라도 자체 정적 분석은 붙이기로 했다.

## 결정

CI에 다음 잡을 두고 모두 main 머지 필수 체크로 건다.

| 잡 | 도구 | 내용 |
|---|---|---|
| `test` | ExUnit | 포맷 검사, 경고를 에러로 보는 컴파일, 안 쓰는 lock 항목 검사, 테스트 |
| `credo` | Credo `--strict` | 코드 품질·스타일. 결과를 SARIF로 GitHub code scanning에 업로드(category `credo`) |
| `dialyzer` | Dialyxir | 타입 분석. 플래그 `error_handling`, `extra_return`, `missing_return`, `underspecs`. PLT는 `priv/plts`에 캐시 |
| `audit` | `mix hex.audit`, mix_audit | 폐기된 패키지와 알려진 취약점 |

ruleset의 code scanning 규칙은 CodeQL 대신 Credo를 대상으로 한다. 기준은 다른 저장소와 같다
(error 수준 지적, high 이상 보안 지적이면 머지 차단).

## 대안

- **CodeQL 규칙 유지:** Elixir를 지원하지 않아 채택하지 않았다.
- **Sobelow:** Phoenix 전용 보안 분석이라 Phoenix가 없는 지금은 넣지 않았다. Phase 5에서 Phoenix를 붙일 때 추가한다.

## 결과

- 잡마다 반복되는 BEAM 설치·캐시·`deps.get`은 `.github/actions/setup-elixir`로 묶었다.
- GitHub Actions 캐시는 main에서 저장한 것만 다른 브랜치가 쓸 수 있다. [ADR 0006](0006-merge-policy.md)의
  자동 머지가 `GITHUB_TOKEN`으로 머지하면 main CI가 돌지 않아 PLT 캐시와 code scanning 기준선이 갱신되지 않는다.
- Sobelow는 아직 적용하지 않았다.
