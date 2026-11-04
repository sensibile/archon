# ADR 0029: 워커 범위 검사를 태극 검사기로 바꾸고 검증 스위트 목록을 TOML로 두기

- 상태: 제안
- 날짜: 2026-11-04
- 태극 원본: sensibile/taeguk `7d0a7a82a0386651848f9b86411b2f48923acba8`(archon 설치본, [ADR 0028](0028-taeguk-ver005-convergence-and-tools.md))
- 대체: [ADR 0028](0028-taeguk-ver005-convergence-and-tools.md) 결정 4·5, [ADR 0013](0013-taeguk-daily-workers.md)
  결정의 경로 허용 목록 검사 도구(`scripts/worker_path_check.sh`), [ADR 0016](0016-taeguk-review-order-and-model.md)
  결정 5의 "Scope check는 `scripts/worker_path_check.sh` 경로 검사다". auto-merge 조건은 그대로이고, 허용 범위는 `test/scripts/`를 막아 줄기만 했다.

## 맥락

ADR 0028은 태극 `7d0a7a8`을 재설치하면서 두 도구를 설치만 하고 쓰지 않았다.

- 워커 범위 검사기 `.taeguk/tools/check_worker_scope.py`(sensibile/taeguk#55): archon 범위 파일
  `.taeguk/worker-scope.toml`이 없어 `UNKNOWN`을 낸다. 그래서 데일리 정리·테스트 보강의 auto-merge 조건은 계속
  `scripts/worker_path_check.sh`였다. 같은 안전 검사가 bash 사본과 태극 Python 사본으로 갈라져 있었다.
- 검증 건강도 `validation_health.py run --suites`(sensibile/taeguk#56): archon 스위트 목록 TOML이 없어 쓰지 않았다.
  태극 #56 인계 노트는 일회용 Postgres가 필요한 `mix test` 두 개를 archon 쪽 래퍼로 감싸라고 했다.

2026-11-04 BOSS가 조정 세션에서 ADR 0028의 후속 셋(이 ADR의 두 결정과 ADR 0028 승인)을 한 PR로 하라고 "시작"으로
승인했다. 정기 워커가 이 범위 검사로 auto-merge를 정하므로, 바꾸면서 검사 범위가 줄지 않는 것이 조건이다.

## 결정

1. **워커 범위 검사는 `origin/main`의 `.taeguk/tools/check_worker_scope.py`와 `.taeguk/worker-scope.toml`로 한다.**
   `scripts/worker_path_check.sh`와 그 시험은 지운다.
   - 범위 파일 내용: 보호 경로 `docs/adr/`, `docs/operations.md`, `scripts/`, `test/scripts/`(대소문자 무시),
     `executable_files = false`, `python_import_roots = []`, `test-gap`은 `test/` 허용과 `forbid_removed_lines = true`,
     `daily-cleanup`은 `lib/`, `test/`, `docs/`, `README.md` 허용.
   - 검사기 내장 보호(`.github/`, `.taeguk/`, `.claude/`, `.codex/`, `.agents/`, 어느 깊이든 `AGENTS*.md`·`CLAUDE.md`·
     `CLAUDE.local.md`·`.gitattributes`·`.gitignore`·`.gitmodules`, `mix.exs`, `mix.lock`)는 범위 파일로 풀 수 없고, 범위
     파일은 보호를 더하기만 한다. 검사기는 범위 파일을 PR head가 아니라 base 커밋에서 읽으므로 워커 PR이 자기 범위를
     넓힐 수 없다.
   - 통과 조건은 종료 코드 0이면서 JSON `status`가 `PASS`인 것이다. 1은 거부 경로가 있음(`rejected`에 경로와 이유),
     2는 `UNKNOWN`(설정·git 오류, 잘못된 ref)이다.
   - 옛 스크립트보다 넓어진 보호: `scripts/`와 `test/scripts/`를 보호 경로로 명시했다. `scripts/`는 원래 허용 밖이었지만
     검증 건강도가 실행하는 래퍼가 들어 있어 이름을 붙였다. `test/scripts/`는 옛 스크립트에서 두 워커 모두 바꿀 수
     있었는데, 범위를 고정하는 시험이 들어 있어 막았다. 그 밖에 UTF-8이 아닌 내용, `A`·`M`·`D`가 아닌 변경 유형,
     유니코드 대소문자 접기(`casefold`) 충돌도 거부한다.
2. **옛 검사가 막던 경로를 새 검사기도 모두 막는지 시험과 실행 기록으로 확인한다.**
   - `test/scripts/worker_scope_test.exs`가 옛 시험 20건을 모두 옮겨 실제 archon 범위 파일로 돌린다. 이름으로만 막던
     경로(`.taeguk/` 아래 범위 파일·스위트 목록·설치본, `.github/`, `scripts/`, `test/scripts/`, `AGENTS.md`, `mix.lock`,
     `config/`, `priv/contract/`)와 base에서 범위를 읽는 동작도 시험한다. 이 시험은 실제 `git`과 `python3`을 쓰고
     대역은 없다.
   - 범위 파일을 느슨하게 바꾼 변이 다섯 개(`docs/adr/` 보호 제거, `test/scripts/` 보호 제거,
     `forbid_removed_lines = false`, `executable_files = true`, `test-gap`에 `lib/` 허용)는 모두 시험을 실패시켰다.
   - 2026-11-04 `origin/main`(`707368e`)의 첫 부모 이력 99개 커밋을 두 워커로 나란히 돌렸다(198쌍, 각 커밋의 부모와
     커밋에 범위 파일을 더해 base·head로 씀). 종료 코드와 거부 경로 집합이 196쌍에서 같았다. 다른 2쌍(`55d5578`, 워커
     도입 커밋)은 둘 다 FAIL이고 새 검사기가 `test/scripts/worker_path_check_test.exs`를 더 거부했다. 옛 스크립트가
     거부한 경로를 새 검사기가 통과시킨 경우는 0건이다. 실제 워커 PR(#38, #45, #46, #57, #74, #85, #86)은 양쪽 판정이
     같았다.
3. **검증 건강도 스위트 목록은 `.taeguk/validation-suites.toml`이다.** 태극 체크아웃의 `origin/main`에서 꺼낸
   `validation_health.py`로 `run --suites <worktree>/.taeguk/validation-suites.toml --root <worktree> --rerun-failed`를
   실행한다. 목록은 현재 디렉터리 기준으로 열리므로 시험 대상 worktree의 절대 경로로 준다.
   - 스위트: `mix deps.get`, `mix deps.unlock --check-unused`, AGENTS.md 검증 여섯 가지(`mix format --check-formatted`,
     `mix compile --warnings-as-errors`, `mix test`, `mix credo --strict`, `mix dialyzer`, `mix deps.audit`),
     `ARCHON_BACKEND=postgres mix test`, `mix hex.audit`, skill-creator 검증기. 모두 CI와 같이 `MIX_ENV=test`다.
   - 두 `mix test`는 `scripts/with_test_postgres.sh`로 감싼다. 스위트마다 CI와 같은 이미지의 일회용 컨테이너를
     `127.0.0.1` 임의 포트로 띄우고, 비밀번호는 도구의 가려지는 `{secret}`을 쓰고, 끝나면 지운다. 시간 초과로
     SIGKILL되면 지우지 못하므로 실행 끝에 이 실행의 `archon-validation-health-*` 컨테이너가 남았는지 확인해 지운다.
   - 이 TOML은 정기 실행이 이 Mac의 환경으로 실행하는 명령 목록이다. 그래서 워커가 바꿀 수 없는 `.taeguk/`(검사기
     내장 보호)에 두고, 래퍼는 `scripts/`(범위 파일 보호)에 둔다.
   - 태극 체크아웃은 읽기만 한다(`git show origin/main:scripts/validation_health.py`를 임시 파일로 꺼내 `python3 -I`로
     실행). 검증 건강도의 권한은 [ADR 0022](0022-taeguk-validation-health.md) 그대로 "보고만 한다"다.
4. **이 PR이 머지되면 예약 작업 세 개의 프롬프트를 운영 문서의 새 통과 조건에 맞춘다.** 데일리 정리·테스트 보강
   프롬프트의 "출력이 있으면 실패"는 JSON을 출력하는 새 검사기와 맞지 않으므로 "운영 문서 절의 통과 조건"으로 바꾸고,
   검증 건강도 프롬프트는 태극 체크아웃에서 도구를 읽기 전용으로 꺼내도록 고친다. 예약 시각과 권한은 바꾸지 않는다.

## 대안

- **옛 스크립트를 한동안 함께 두기:** 판정 대조는 이 PR에서 이력과 시험으로 끝냈다. 두 검사를 같이 두면 어느 쪽이
  기준인지 다시 갈라진다.
- **스위트 목록을 `scripts/`에 두기:** 태극처럼 `scripts/validation-suites.toml`에 둘 수 있다. archon에서는
  `scripts/`를 범위 파일로 보호하지만, 범위 파일과 같은 `.taeguk/`에 두면 검사기 내장 보호가 덮어 범위 파일 수정만으로
  풀리지 않는다.
- **Postgres 컨테이너를 스위트 목록 밖에서 띄우기:** 운영 문서 절차대로 한 컨테이너를 두 스위트와 재실행에 쓸 수 있다.
  그러면 도구가 실행하는 명령만으로 재현되지 않고, 재실행이 같은 데이터베이스 상태를 이어받는다.

## 결과

- 데일리 정리·테스트 보강의 auto-merge 조건이 태극 스킬 문장("exit 0 with status PASS")과 같아진다. 범위 검사 코드는
  태극 한 곳에서 고치고 재설치로 들어온다.
- 범위 파일과 스위트 목록은 base 커밋 기준이라 이 PR이 머지된 뒤 시작하는 워커 실행부터 적용된다.
- 검증 스위트가 워커가 바꿀 수 있는 제품 코드와 시험을 실행하는 구조는 그대로다(태극 #56 정리 후보).
  이 PR의 로컬 Codex 교차·보안 리뷰가 이것을 P1 "inherited or deferred risk"로 냈다. 머지된 워커 코드(`lib/`, `test/`)를
  검증 건강도 예약 실행이 이 Mac의 환경(자격 증명, docker)으로 실행한다. 이 구조는
  [ADR 0022](0022-taeguk-validation-health.md)부터 있던 기존 위험이고, 이 PR은 워커가 바꿀 수 있는 범위를 넓히지 않는다.
  2026-11-05 BOSS가 "머지, 격리는 후속"을 골랐다. 후속 후보: 예약 실행의 격리(자격 증명과 docker 접근을 떼어 낸 실행
  환경)는 별도 작업으로 다룬다.
- 이 ADR은 구현 PR이 머지된 뒤 다음 PR에서 승인으로 바꾼다.
