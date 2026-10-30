# ADR 0013: 태극 데일리 정리와 테스트 보강 워커 적용

- 상태: 승인
- 날짜: 2026-10-29
- 태극 원본: sensibile/taeguk `c6b42fb1ced01249d24a8134c5fc0510dd5c3489`
- 대체: [ADR 0012](0012-taeguk-pilot-and-bundle-update.md) 결정 3("데일리 정리는 archon에 적용하지 않는다").
  ADR 0012의 나머지 결정은 그대로 유효하다.
- 비고(2026-10-30): 결정 2의 "Codex 전송" 항목과 결과의 "Codex 전송 허용을 넓힌다는 BOSS 확인" 조건은
  [ADR 0020](0020-taeguk-codex-transmission-list-removal.md)이 대체한다. 태극 #39 뒤 워커의 적용 조건은 예약 시각과
  머지 권한이고, Codex 실행 가능 여부는 Codex CLI 설정이 정한다. 맥락의 상시 허용 기록은 사실 기록으로 남긴다.

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
   - 경로 허용 목록: auto-merge를 켜기 직전에 `origin/main`의 `scripts/worker_path_check.sh`로 리뷰한 head SHA의
     변경 경로를 기계적으로 검사한다. 테스트 보강은 `test/`만 허용하고 삭제는 없어야 한다. 데일리 정리는 `lib/`,
     `test/`, `docs/`, `README.md`만 허용하되 ADR과 운영 문서는 뺀다. 심볼릭 링크, 서브모듈, 바이너리, 비ASCII 경로,
     대소문자 충돌, git 메타 파일(`.gitattributes` 등), 에이전트 지시 파일(`CLAUDE.md`, `AGENTS*.md` 등)은 허용하지 않는다.
     테스트 보강은
     줄을 지울 수 없다. 종료 코드가 0이 아니면 auto-merge를 켜지 않고 BOSS에게 보고한다. 목록과 절차는 운영 문서에 있다.
   - Codex 전송: archon diff를 로컬 Codex CLI로 보내는 것은 상시 허용이다.
3. **coverage는 측정 도구로만 쓴다.** 측정 명령은 `mix test --cover`다. `mix.exs`에
   `test_coverage: [summary: [threshold: 0]]`을 두어, 통과한 suite가 커버리지 임계값(Elixir 기본 90%) 때문에
   실패하지 않게 한다. 커버리지 수치는 목표나 결과로 쓰지 않는다.
4. **실행 보고는 `.taeguk/daily-cleanup/`와 `.taeguk/test-gap/`에 남기고 Git에서 무시한다.**

## 대안

- **보고 모드만 적용:** BOSS가 자동 머지까지 고른 기본값과 맞지 않아 채택하지 않았다.
- **서버 측 경로 보호(CODEOWNERS 필수 승인, ruleset 경로 제한):** 1인 저장소에서 BOSS 승인을 필수로 하면
  워커가 auto-merge하는 의미가 없어진다. 우선 auto-merge 직전의 경로 검사로 범위를 막는다. 우회가 관측되면 다시 검토한다.
- **GitHub Actions 예약 실행:** 로컬 Codex CLI와 로그인 상태가 필요해 이 Mac의 로컬 예약 작업으로 둔다.

## 결과

- 머지 전 테스트에서 `mix test --cover`는 종료 코드 0이었다. 전체 커버리지는 Elixir 기본 임계값 90%보다 낮았다.
  그래서 임계값 0 설정이 없으면 측정 실행이 실패로 끝났을 것으로 본다. 이 부분은 추정이며 재현하지 않았다.
- 예약 작업은 저장소 밖(`~/.claude/scheduled-tasks/`)에 있다. 이 Mac이 꺼져 있거나 Codex CLI 로그인이 풀리면
  실행은 NOT_RUN으로 보고된다.
- 남는 위험(로컬 보안 리뷰, 재현하지 않은 시나리오 포함):
  - 경로 검사와 PR base·head 확인(`gh pr view`)은 워커 자신이 실행하는 절차이고 서버가 강제하지 않는다. ruleset은
    승인 0건을 요구하고 필수 체크는 경로를 보지 않는다. 공개 PR 댓글이나 upstream 소스의 지시문에 넘어간 워커가
    검사를 건너뛰면, 권한 기록을 바꾼 PR에도 auto-merge를 켤 수 있다. 검사는 정상으로 동작하는 워커의 실수와
    리뷰에서 재현된 우회(대소문자, 비ASCII 경로, 심볼릭 링크, `.gitattributes`, 바이너리, git 설정, 옵션 모양
    인자, 대소문자 충돌)와 하위 디렉터리의 에이전트 지시 파일을 막는다. 리뷰를 거듭할 때마다 새 우회가 나왔으므로,
    이 목록이 완전하다고 보지 않는다.
  - 허용 경로 `test/`, `lib/`는 실행되는 코드다. 두 워커 모두 리뷰 전에 로컬에서 검증 명령(`mix test` 등)을 돌리므로,
    주입된 코드가 이 Mac의 자격 증명으로 실행될 수 있다. 머지된 뒤에는 CI와 다른 checkout에서도 실행된다.
  - 테스트 보강의 "추가만" 검사는 테스트를 약하게 만드는 추가(`ExUnit.configure(exclude: ...)`, `@moduletag :skip`,
    `test/support` 코드)를 막지 못한다. 이것은 Codex의 테스트 적정성 리뷰에 기댄다.
  - 이 위험을 받아들일지, 서버 측 보호나 워커 실행 격리를 둘지는 BOSS가 정한다. 우회나 의심 실행이 관측되면
    예약 작업을 끄고 다시 검토한다.
- hoplites, acropolis, thesmothetai에는 적용하지 않는다. 그 프로젝트들에 적용하려면 Codex 전송 허용을 넓힌다는
  BOSS 확인이 먼저 필요하다.
- 이 ADR은 구현 PR이 머지된 뒤 다음 PR에서 승인으로 바꾼다.
