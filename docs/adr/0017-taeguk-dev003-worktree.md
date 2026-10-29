# ADR 0017: 태극 번들 갱신과 작업 전용 워크트리 규칙(DEV-003) 적용

- 상태: 제안
- 날짜: 2026-10-29
- 태극 원본: sensibile/taeguk `a820b4a7027813368fd41d3a1b619f19e6f063a1`

## 맥락

archon에 태극이 설치돼 있었지만 워크트리 지침은 일반 개발 작업에 적용되지 않았다. 태극의 워크트리 문장은
"프로젝트의 워크트리 절차를 따른다"뿐이었고, archon AGENTS.md의 태극 줄은 태극 규칙을 "명시적으로 배정된 워크플로"에만
적용하라고 했다. 이 문제를 보고받은 BOSS가 고칠 위치로 "태극 번들에 포함"을 골랐다. 이어서 개정안에 "그대로 승인"이라고
답했다(sensibile/taeguk#37, 태극 승인 기록 `Approval-2026-10-29-worktree`).

BOSS는 태극 세션에서 "이거 완료되면 archon에 배달해줘"라고 지시했고, 이 요청은 태극 세션을 거쳐 archon 세션에 전달됐다.
archon 세션에서 BOSS가 dry-run 결과를 보고 "적용하고 문구도 교체"라고 승인했다. archon에 설치된 번들은 `f71224a`(ADR 0016)다.

## 결정

1. **태극 번들을 `a820b4a`로 갱신한다.** 설치 버전과 검사 결과는 다음과 같다.
   - 설치기 dry-run: 세 구성요소 모두 `planned`, 경고 없음.
   - 새 파일: `.taeguk/rules/development.md`(DEV-003 1.0)와 `.taeguk/rules/proposals/worktree-first.md`.
   - 적용 뒤 `--check`: rules·codex·claude가 각각 14·63·47 파일로 모두 `verified`.
   - 설치본은 직접 고치지 않는다(ADR 0007 결정 3).
2. **DEV-003을 archon의 모든 저장소 편집에 적용한다.** AGENTS.md의 태극 줄 끝에 "apply DEV-003 (dedicated worktree,
   `.taeguk/rules/development.md`) to all repository edits."를 붙인다. 이 문장이 없으면 태극 스킬 밖의 일반 개발 작업이
   DEV-003을 읽지 않을 수 있다. CLAUDE.md는 `@AGENTS.md`를 불러오므로 따로 고치지 않는다.
3. **archon은 별도 워크트리 규약을 두지 않고 DEV-003 기본값을 쓴다.**
   - 위치: checkout 바깥의 `../archon-worktrees/<slug>`. [운영 문서](../operations.md)의 워커 작업 위치와 같다.
   - 브랜치: `type/slug`. AGENTS.md "PR과 머지"의 이름 규칙과 같다.
   - base: 원격에서 확인한 `main` SHA.
   - 데스크톱 앱이 세션용으로 만든 워크트리(`.claude/worktrees/…`)는 DEV-003대로 작업 브랜치를 만든 뒤 그 작업의
     워크트리로 쓴다.
   - 테스트 보강 워커의 측정 워크트리도 `../archon-worktrees/` 아래에 둔다. 결함 주입처럼 커밋하지 않고 되돌리는 임시
     편집은 DEV-003의 개발 편집이 아니다.
4. **머지된 구현 PR의 ADR 상태를 함께 갱신한다.** ADR 0013(#23), 0014(#24~#27, #31), 0015(#28, #29),
   0016(#30)을 `승인`으로 바꾼다.

## 대안

- **AGENTS.md에 archon 전용 워크트리 규약 쓰기:** DEV-003 기본값이 이미 운영 문서의 위치, AGENTS.md의 브랜치 이름과
  같다. 같은 내용을 두 곳에 두면 어긋날 수 있어 기본값을 따른다.
- **문구를 바꾸지 않고 번들만 갱신:** DEV-003이 일반 개발 작업에 닿지 않는다. 이번 개정의 목적이 그것이므로 택하지 않는다.

## 결과

- 이 ADR이 들어간 스냅샷이 `main`에 머지된 뒤 새로 시작하는 작업부터 DEV-003을 적용한다. 진행 중인 작업에는 소급하지
  않는다.
- 이 PR 자체도 `../archon-worktrees/taeguk-bundle-a820b4a`, 브랜치 `chore/taeguk-bundle-a820b4a`, base `1a21bfe`에서
  만들었다.
- DEV-003은 문서 지침이고 편집 위치를 기계적으로 막지 않는다. 워크트리 정리 시점과 방법도 정하지 않는다.
- 이 ADR은 구현 PR이 머지된 뒤 다음 PR에서 승인으로 바꾼다.
