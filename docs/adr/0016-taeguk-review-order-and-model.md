# ADR 0016: 태극 번들 갱신과 로컬 리뷰 순서·모델 변경

- 상태: 제안
- 날짜: 2026-10-29
- 태극 원본: sensibile/taeguk `f71224ac2e9c93db2b3f2004767e1fcce3579121`
- 대체: [ADR 0011](0011-local-review-auto-merge.md) 결정 3의 리뷰 순서("PR 누적 범위를 태극
  `taeguk-codex-local-review` 절차로 리뷰한다" 앞에 자체 리뷰 반복을 더함)와 리뷰 설정 "`gpt-6-astra`, `medium`
  effort". ADR 0011의 나머지 결정은 그대로 유효하다.

## 맥락

2026-10-29 BOSS가 태극에서 로컬 Codex 리뷰를 두 가지 바꿨다(sensibile/taeguk#36). 하나는 비용 때문에 리뷰 모델을
`gpt-6-astra`/`medium`에서 `gpt-6-sol`/`high`로 바꾼 것이고, 다른 하나는 리뷰 순서다. 세션 자신의 리뷰 에이전트가
VER-005 종료 조건을 만족할 때까지 같은 범위를 반복해서 리뷰한 뒤에야 Codex 교차·보안 리뷰를 돌린다. Codex
지적으로 코드가 바뀌면 자체 리뷰부터 다시 한다. 같은 순서를 데일리 정리·테스트 보강 워커와 `taeguk-work-contract`의
단계 설명에도 적용했다.

BOSS는 수정이 끝나면 archon에도 설치해 반영하라고 했다. 이 요청은 태극 세션을 거쳐 archon 세션에 전달됐고,
archon 세션에서 BOSS가 "진행"으로 확인했다.

archon에 설치된 번들은 `c6b42fb`(ADR 0013)다. 그 사이 태극에는 #31~#36이 머지됐다.

## 결정

1. **태극 번들을 `f71224a`로 갱신한다.** 설치기 dry-run에서 세 구성요소가 모두 `planned`였고, 적용 뒤 `--check`에서
   rules·codex·claude가 모두 `verified`였다. 설치본은 직접 고치지 않는다(ADR 0007 결정 3).
2. **로컬 리뷰 모델은 `gpt-6-sol`, effort는 `high`다.** 설정은 설치된 `taeguk-codex-local-review` 스킬의 명령에 있다.
   ADR 0011 결정 3의 `gpt-6-astra`/`medium`을 대체한다.
3. **리뷰 순서는 자체 리뷰 반복, 그다음 Codex 리뷰다.** push 전에 세션의 리뷰 에이전트(Claude Code에서는 리뷰
   서브에이전트)가 PR 누적 범위를 VER-005 종료 조건까지 반복 리뷰한다. 그 head에 대해 Codex 교차 리뷰(항상)와
   보안 리뷰(실행 동작에 영향을 주는 변경)를 돌린다. Codex 지적으로 head가 바뀌면 자체 리뷰부터 다시 한다.
   절차는 AGENTS.md "PR과 머지"에 둔다.
4. **새로 들어온 워커 스킬은 archon에서 돌리지 않는다.**
   - `taeguk-validation-health`는 설치 프로젝트가 BOSS 승인(예약·보고 위치)을 기록해야 돈다. archon은 기록하지 않았다.
   - `taeguk-doc-drift`는 태극 저장소에서만 돈다. 설치 프로젝트 예외가 없고, 스캔 스크립트도 번들에 들어 있지 않다.
5. **워커의 범위 검사(#34)는 archon의 경로 검사로 연결한다.** #34는 데일리 정리·테스트 보강 스킬에
   "Scope check" 절을 넣었다. auto-merge는 범위 검사가 "exit 0 with status PASS"일 때만 켜고, 설치 프로젝트는
   자기 전달 문서가 지정한 검사를 쓰되 지정이 없으면 auto-merge 없이 PR을 열고 보고한다. 또 두 스킬은 자체 리뷰를
   "project's PR flow step 2"로 가리킨다. archon에서는 [운영 문서](../operations.md)에 다음을 적는다.
   - 스킬의 Scope check는 `scripts/worker_path_check.sh` 경로 검사다. 태극의 `scripts/check_worker_scope.py`는
     archon에 없으므로 쓰지 않는다. 이 검사의 종료 코드 0이 PASS다.
   - 자체 리뷰 루프는 AGENTS.md "PR과 머지" 1단계다.

## 대안

- **번들 갱신 없이 AGENTS.md만 고치기:** 스킬 명령의 모델 설정은 번들 안에 있고, 설치본을 직접 고치지 않는
  원칙(ADR 0007)과 맞지 않는다.
- **이번 변경(#36)만 골라 설치:** 설치기는 원본 커밋 하나를 통째로 설치한다. #31·#33은 결정 4대로 archon에서 돌지
  않는 새 워커이고, #35는 `taeguk graph` 보조 안내다. #34는 archon 워커의 auto-merge 조건을 바꾸므로 결정 5로 연결한다.

## 결과

- Codex가 archon 세션에서 새 모델 설정을 실제로 따르는지는 이 PR의 로컬 리뷰 실행 로그(모델·effort)로 확인한다.
  결과는 PR 본문에 적는다.
- 데일리 정리·테스트 보강 예약 작업은 다음 실행부터 새 스킬을 읽는다. 결정 5의 연결대로 범위 검사를 PASS로 보고
  auto-merge를 켜는지는 관측하지 않았다. 다음 실행 보고(`.taeguk/daily-cleanup/`, `.taeguk/test-gap/`)로 확인한다.
