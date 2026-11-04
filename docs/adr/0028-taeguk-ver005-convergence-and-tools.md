# ADR 0028: 태극 번들 갱신과 VER-005 1.1, 도구 네 가지 반영

- 상태: 제안
- 날짜: 2026-11-04
- 태극 원본: sensibile/taeguk `7d0a7a82a0386651848f9b86411b2f48923acba8`(sensibile/taeguk#58 머지 커밋)
- 보완: [ADR 0016](0016-taeguk-review-order-and-model.md) 결정 5의 "스킬에 적힌 태극 `scripts/check_worker_scope.py`는
  archon에 없으므로 쓰지 않는다"를 아래 결정 4로 바꾼다. 경로 검사를 `scripts/worker_path_check.sh`로 하는 결정은
  그대로다. ADR 0016의 나머지 결정은 그대로 유효하다.

## 맥락

archon에 설치된 태극 번들은 `81817cf`([ADR 0020](0020-taeguk-codex-transmission-list-removal.md))다. 그 뒤 태극
`main`에는 다음이 머지됐다.

- sensibile/taeguk#41~#46: DEV-004 1.0(학습 수집·실수 유형 강제, 스킬 `taeguk-harvest-lessons`·`taeguk-encode-mistake-class`),
  VER-007 1.0·1.1(테스트 대역 선택). 승인 기록은 Approval-2026-10-30, Approval-2026-10-30-lessons,
  Approval-2026-10-30-ver007-general이다.
- sensibile/taeguk#54: `check_doc_drift.py`의 opt-in ADR 목록 점검(`--adr-dir`).
- sensibile/taeguk#55: 워커 범위 검사기 `check_worker_scope.py`를 설치 프로젝트에 `.taeguk/tools/`로 배치하고
  프로젝트 범위 파일(`--config`)을 받게 함.
- sensibile/taeguk#56: `validation_health.py run --suites`(TOML 스위트 목록 실행)와 `observations`(PR 시점 간헐 실패 수집).
- sensibile/taeguk#57: `review_record.py`. Codex 로컬 리뷰를 실제로 실행하고 그 실행에서 계산한 기록과 PR용 블록을 만든다.
- sensibile/taeguk#58: VER-005 1.1. 승인 기록은 VER-005 Approval-2026-11-04다.

2026-11-04 BOSS가 조정 세션에서 이 재설치를 "시작"으로 승인했다. 이것이 archon에 대한 프로젝트별 승인이다.

## 결정

1. **태극 번들을 `7d0a7a8`로 갱신한다.** 설치기는 태극 `7d0a7a8` 체크아웃의
   `scripts/taeguk_install.py project --root <worktree> --agent codex,claude`다.
   - dry-run: `installer_version` `7d0a7a8`, `installed_versions`는 세 구성요소 모두 `81817cf`. rules·codex·claude가
     모두 `planned`(19·68·50 파일)이고 경고와 `shadowed_by_user_skills` 항목은 없었다. 적용 직전에 다시 돌린 dry-run
     출력이 처음과 바이트 단위로 같았다. 같은 `origin/main`의 별도 worktree에 먼저 적용해 본 diff와 실제 적용 diff도
     같았다.
   - `--apply` 뒤 `--check`: rules·codex·claude 모두 `verified`(19·68·50), 세 영수증의 `source_version`은 `7d0a7a8`.
   - 새 파일: `.taeguk/tools/check_worker_scope.py`, `taeguk-codex-local-review/scripts/review_record.py`(`.claude/skills/`,
     `.agents/skills/`), 스킬 `taeguk-harvest-lessons`·`taeguk-encode-mistake-class`, 개정안 사본 네 개.
   - 내용이 바뀐 파일: 규칙 `approvals.md`·`development.md`·`index.md`·`verification.md`·`registry.toml`·
     `mechanical-checks.md`, 스킬 `taeguk-codex-local-review`·`taeguk-daily-cleanup`·`taeguk-test-gap`·
     `taeguk-validation-health`·`taeguk-doc-drift`·`taeguk-learn-from-outcome`·`taeguk-implement-small-change`·
     `taeguk-work-contract`, 역할 `taeguk-coordinator`.
   - archon 쪽 파일과 겹치는 경로는 없다. 설치기가 덮어쓰기를 거부한 파일도 없다. 설치본은 직접 고치지 않는다
     (ADR 0007 결정 3).
2. **VER-005 1.1을 채택한다.** 근거는 태극 VER-005 Approval-2026-11-04다. P2 이하 지적은 목적·요구사항·수용 기준
   위반, 이 변경의 회귀, 관측됐거나 승인된 신뢰 경계 안의 도달 경로가 확인된 경우에만 고친다. 같은 리뷰 역할(자체 리뷰,
   Codex 리뷰 각각)이 연속 3회차 동안 매 회차 반영 대상 지적을 내면 BOSS에게 보고한다. archon에는 이 사본이 `main`에
   머지된 뒤 새로 시작하는 작업부터 적용한다. 진행 중인 작업은 1.0을 유지하고, 1.1을 채택하면 그 사실을 기록한다.
   AGENTS.md "PR과 머지"는 "VER-005 종료 조건"을 가리키므로 문구를 바꾸지 않아도 1.1을 따른다.
3. **`check_doc_drift.py --adr-dir`(#54)은 정기 실행으로 켜지 않는다.** archon에는 문서 드리프트 예약 작업이 없고,
   새 예약은 새 실행 권한이라 이번 범위 밖이다. 대신 ADR을 추가하거나 상태를 바꾸는 세션이 태극 체크아웃에서
   읽기 전용으로 돌려 확인할 수 있다:
   `python3 -I <태극>/scripts/check_doc_drift.py --root <worktree> --adr-dir docs/adr --adr-only`.
   archon ADR 형식(`# ADR NNNN: 제목`, `- 상태: …`, `docs/adr/README.md` 표)은 기본 패턴과 맞는다. 2026-11-04
   `origin/main`에서 `NONE`이었고, 목록의 0022 상태를 일부러 바꾼 사본에서는 `adr_index` 지적을 냈다. 결과는 후보이며
   gate가 아니다.
4. **워커 범위 검사기(#55)는 설치만 하고 아직 쓰지 않는다.** 갱신된 데일리 정리·테스트 보강 스킬은
   `.taeguk/tools/check_worker_scope.py --config .taeguk/worker-scope.toml`을 예시로 들지만, 설치 프로젝트에서는
   "delivery document가 정한 검사"를 쓰라고 한다. archon의 delivery document인 [운영 문서](../operations.md)는
   `origin/main`의 `scripts/worker_path_check.sh`를 정하고 있고, `.taeguk/worker-scope.toml`은 없다. 범위 파일 없이
   돌리면 검사기는 `UNKNOWN`(exit 2)을 낸다. 그래서 워커 auto-merge 조건은 계속 `worker_path_check.sh`의
   `path check exit` 0이다. 운영 문서의 해당 문장을 이 상태에 맞게 고친다.
5. **`validation_health.py`(#56)의 `run --suites`는 archon 스위트 목록이 생길 때까지 쓰지 않는다.** archon 검증
   건강도는 [운영 문서](../operations.md) "검증 건강도"의 스위트 목록을 따른다. 그 목록이 갱신된 스킬이 말하는
   "its own suite list"다. 읽기 전용 `observations` 명령은 ADR 0022의 "보고만 한다" 권한 안에서 쓸 수 있다.
6. **`review_record.py`(#57)는 쓸 수 있다.** 갱신된 `taeguk-codex-local-review` 스킬은 이 도구로 Codex를 실행하고 PR
   본문에 렌더된 블록을 넣으라고 한다. 같은 명령(`codex exec`, 읽기 전용 sandbox, `gpt-6-sol`, `high`)을 실행하고
   프롬프트 sha256과 실행 정보를 실행 결과에서 계산하므로, AGENTS.md "PR과 머지" 1단계의 "프롬프트 sha256을 PR 본문에
   적는다"를 이 블록이 채운다. 손으로 적는 기존 방식도 계속 허용한다.
7. **VER-007과 DEV-004 사본이 함께 들어온다.** registry상 VER-007 범위는 "Taeguk and Taeguk pilot projects", DEV-004는
   "Taeguk and explicitly assigned workflows"다. VER-007은 태극 지정 흐름에 사본 머지 뒤 새로 시작하는 작업부터
   적용된다. 일반 개발에 적용되는 시점은 VER-007을 가리키는 진입 문구가 AGENTS.md에 머지된 때이며(VER-007 1.1
   결정 (4)), 그 문구는 이 PR에서 BOSS 확인을 받아 따로 정한다(아래 결과). archon `test/`에는 mock 라이브러리
   (Mox, meck 등) 사용이 없어, 데일리 정리 스킬의 일회성 VER-007 대역 조사는 찾을 항목이 거의 없을 것이다.
8. **[ADR 0022](0022-taeguk-validation-health.md)를 승인으로 바꾼다.** 구현 PR #55(archon)가 머지됐다.

## 대안

- **도구를 바로 archon에 연결하기:** `worker_path_check.sh`를 `check_worker_scope.py`와 범위 파일로 바꾸고, 스위트
  목록 TOML을 만들면 태극 스킬과 문장이 맞는다. 다만 검사 범위가 줄지 않는지 비교해야 하고, 범위 파일·스위트 목록은
  워커 보호 경로에 둬야 한다. 재설치와 섞으면 리뷰 범위가 커지므로 후속 작업으로 나눈다.
- **`--adr-dir` 정기 실행을 켜기:** 문서 드리프트 예약 작업과 그 권한이 먼저 있어야 한다. 이번 승인 범위에 새 실행
  권한은 없다.

## 결과

- 후속 작업 둘이 남는다. (1) `scripts/worker_path_check.sh`를 `.taeguk/tools/check_worker_scope.py`와
  `.taeguk/worker-scope.toml`로 바꾼다. 바꿀 때 검사 범위가 줄면 안 된다. (2) archon 검증 스위트 목록 TOML을 만든다.
  이 파일은 워커 보호 경로에 둔다(태극 sensibile/taeguk#56 PR 본문의 인계 노트 참고).
- AGENTS.md 진입 문구에 VER-007 절을 더할지는 BOSS 확인 결과를 PR 본문에 남긴다.
- 이 ADR은 구현 PR이 머지된 뒤 다음 PR에서 승인으로 바꾼다.
