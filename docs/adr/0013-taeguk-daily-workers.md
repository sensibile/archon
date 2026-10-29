# ADR 0013: 태극 데일리 정리와 테스트 보강 워커 적용

- 상태: 제안
- 날짜: 2026-10-29
- 태극 원본: sensibile/taeguk `c6b42fb1ced01249d24a8134c5fc0510dd5c3489`
- 대체: [ADR 0012](0012-taeguk-pilot-and-bundle-update.md) 결정 3("데일리 정리는 archon에 적용하지 않는다").
  ADR 0012의 나머지 결정은 그대로 유효하다.

## 맥락

태극은 데일리 정리(`taeguk-daily-cleanup`)와 테스트 보강(`taeguk-test-gap`) 워커를 태극 저장소에서 돌리고 있다.
sensibile/taeguk#30에서 두 스킬에 "Where it runs" 절이 생겼다. 설치 프로젝트에서는 그 프로젝트가 BOSS 승인을
기록한 경우에만 돈다. 기록할 내용은 예약 시각, 머지 권한, Codex 전송 상시 허용이다.

2026-10-29 BOSS가 "이 정리/테스트 보강 에이전트는 태극을 적용하는 쪽에도 들어가면 좋겠고"라고 했고, 적용 대상과
머지 방식은 제안된 기본값을 골랐다. archon에 먼저 적용하고, 태극과 같이 Codex가 동의한 항목만 auto-merge한다.
같은 날 archon 세션에서 번들 갱신, 승인 기록, coverage 명령, 예약 작업(09:01·10:01) 계획에 "진행해"라고 답했다.
archon 작업의 로컬 Codex 전송은 같은 날 상시 허용됐다.

## 결정

1. **태극 번들을 `c6b42fb`로 갱신한다.** 설치기 dry-run은 세 구성요소 모두 `planned`였고, 적용 뒤 `--check`가
   rules, codex, claude 모두 `verified`였다. 설치본은 직접 고치지 않는다(ADR 0007 결정 3).
2. **archon에서 데일리 정리와 테스트 보강(reinforce 모드)을 매일 돌린다.** 승인 내용과 archon용 실행 방법은
   [운영 문서](../operations.md)에 둔다. 스킬이 요구하는 BOSS 승인 기록은 그 문서다.
   - 예약: 이 Mac의 로컬 Claude 예약 작업. 정리는 매일 09:01, 테스트 보강은 매일 10:01.
   - 머지 권한: Codex가 필요하다고 동의한 항목만 AGENTS.md "PR과 머지" 절차로 head를 고정해 auto-merge한다.
     Codex가 필요 없다고 보거나 판단이 불분명한 항목은 뺀다.
   - Codex 전송: archon diff를 로컬 Codex CLI로 보내는 것은 상시 허용이다.
3. **coverage는 측정 도구로만 쓴다.** 측정 명령은 `mix test --cover`다. `mix.exs`에
   `test_coverage: [summary: [threshold: 0]]`을 두어, 통과한 suite가 커버리지 임계값(Elixir 기본 90%) 때문에
   실패하지 않게 한다. 커버리지 수치는 목표나 결과로 쓰지 않는다.
4. **실행 보고는 `.taeguk/daily-cleanup/`와 `.taeguk/test-gap/`에 남기고 Git에서 무시한다.**

## 대안

- **보고 모드만 적용:** BOSS가 자동 머지까지 고른 기본값과 맞지 않아 채택하지 않았다.
- **GitHub Actions 예약 실행:** 로컬 Codex CLI와 로그인 상태가 필요해 이 Mac의 로컬 예약 작업으로 둔다.

## 결과

- 머지 전 테스트에서 `mix test --cover`는 종료 코드 0이었다. 전체 커버리지는 Elixir 기본 임계값 90%보다 낮았다.
  그래서 임계값 0 설정이 없으면 측정 실행이 실패로 끝났을 것으로 본다. 이 부분은 추정이며 재현하지 않았다.
- 예약 작업은 저장소 밖(`~/.claude/scheduled-tasks/`)에 있다. 이 Mac이 꺼져 있거나 Codex CLI 로그인이 풀리면
  실행은 NOT_RUN으로 보고된다.
- hoplites, acropolis, thesmothetai에는 적용하지 않는다. 그 프로젝트들에 적용하려면 Codex 전송 허용을 넓힌다는
  BOSS 확인이 먼저 필요하다.
- 이 ADR은 구현 PR이 머지된 뒤 다음 PR에서 승인으로 바꾼다.
