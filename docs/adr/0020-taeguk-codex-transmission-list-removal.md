# ADR 0020: 태극 번들 갱신과 Codex 전송 저장소 허용 목록 제거

- 상태: 제안
- 날짜: 2026-10-30
- 태극 원본: sensibile/taeguk `81817cf899e22bc193205f6a3de3863ea52f3b70`(sensibile/taeguk#39 머지 커밋)
- 대체: [ADR 0011](0011-local-review-auto-merge.md) 결정 3의 "전송 권한 근거는 태극 저장소의 승인 기록(Approval-2026-10-29)과 태극
  `docs/architecture.md`의 로컬 Codex 검토 절이다", [ADR 0013](0013-taeguk-daily-workers.md) 결정 2의 "Codex 전송"
  항목과 결과의 "그 프로젝트들에 적용하려면 Codex 전송 허용을 넓힌다는 BOSS 확인이 먼저 필요하다".
  두 ADR의 나머지 결정은 그대로 유효하다.

## 맥락

태극 `taeguk-codex-local-review` 스킬은 Codex CLI 실행으로 diff와 저장소 맥락이 OpenAI로 가는 것을 저장소 허용
목록으로 관리했다. 2026-10-28 태극 저장소, 2026-10-29 archon이 목록에 들어갔고, 그 밖의 저장소는 작업마다
BOSS 승인이 없으면 NOT_RUN이었다. 데일리 정리(`taeguk-daily-cleanup`)와 테스트 보강(`taeguk-test-gap`)도 설치
프로젝트에서 도는 조건으로 예약 시각, 머지 권한과 함께 "Codex 전송 상시 허용" 기록을 요구했다. archon은 이 조건에
맞추려고 [운영 문서](../operations.md)의 승인 표와 ADR 0013 결정 2에 "Codex 전송" 항목을 두었다.

2026-10-30 BOSS는 "그건 툴에서 설정하는 부분일건데 왜 그걸 허용 리스트로 관리를 해"라고 했고, 태극 #39가 허용
목록을 없앴다.

- Codex를 어느 저장소에서 돌릴 수 있는지는 Codex CLI 자체의 로그인과 설정이 정한다. CLI가 그 저장소에서 실행을
  거부하면 리뷰는 CLI가 밝힌 이유와 함께 NOT_RUN이다.
- 두 데일리 워커가 설치 프로젝트에서 도는 조건은 BOSS 승인 기록 중 예약 시각과 머지 권한만 남는다. Codex CLI가
  돌지 못하면 데일리 정리는 7단계 필요성 리뷰가 NOT_RUN이 되어 PR 전에 멈추고, 테스트 보강의 reinforce 모드는
  리뷰 전에 NOT_RUN으로 멈춘다.

archon에 설치된 번들은 `b7b4b58`(ADR 0019)다.

## 결정

1. **태극 번들을 `81817cf`로 갱신한다.** 설치기는 `scripts/taeguk_install.py project --root <worktree> --agent codex,claude`다.
   - dry-run: `installer_version` `81817cf`, `installed_versions`는 세 구성요소 모두 `b7b4b58`. rules·codex·claude가
     모두 `planned`(14·63·47 파일)이고, 경고와 `shadowed_by_user_skills` 항목은 없었다. 적용 직전에 다시 돌린
     dry-run 출력이 처음과 바이트 단위로 같았다.
   - `--apply` 뒤 `--check`: rules·codex·claude 모두 `verified`(14·63·47), 설치 버전은 세 구성요소 모두 `81817cf`.
   - 내용이 바뀐 파일: `taeguk-codex-local-review`·`taeguk-daily-cleanup`·`taeguk-test-gap` 스킬(`.claude/skills/`,
     `.agents/skills/`), 교차·보안 리뷰 역할(`.claude/agents/`, `.codex/agents/`). `.taeguk/rules/`의 4개 파일은
     태극 원본 링크의 고정 SHA만 바뀌었고, `.taeguk/receipts/`의 3개 영수증은 설치 버전과 해시가 갱신됐다.
   - 설치본은 직접 고치지 않는다(ADR 0007 결정 3).
2. **archon에서 Codex 실행 가능 여부는 이 Mac의 Codex CLI 로그인·설정이 정한다.** archon 문서는 더 이상 Codex 전송
   허용을 리뷰나 워커의 적용 조건으로 쓰지 않는다. CLI가 없거나 로그인이 풀렸거나 실행을 거부하면 그 리뷰는 NOT_RUN이고,
   AGENTS.md "PR과 머지" 2단계의 NOT_RUN 게이트로 auto-merge가 막힌다.
   - 2026-10-29 BOSS가 archon diff 전송을 상시 허용했다는 사실은 ADR 0011·0013에 그대로 남긴다. 그 기록은 조건이
     아니라 과거 결정의 기록이다.
3. **데일리 워커의 archon 적용 조건은 예약 시각과 머지 권한이다.** [운영 문서](../operations.md)의 승인 표에서
   "Codex 전송" 행을 "Codex 실행" 행으로 바꿔 위 결정 2를 적는다. 예약 작업 지시(`~/.claude/scheduled-tasks/archon-*`)는
   이미 "Codex CLI가 없거나 로그인이 풀리면 NOT_RUN으로 보고"하라고 적고 있어 바꾸지 않는다.
4. **AGENTS.md는 바꾸지 않는다.** AGENTS.md에는 Codex 전송 허용 문구가 없고, 리뷰 절차는 갱신된 스킬을 부른다.

## 대안

- **archon 문서의 허용 기록을 그대로 두기:** 동작은 같지만, 워커나 리뷰어가 운영 문서의 "Codex 전송" 행을 적용 조건으로
  읽고 태극 스킬과 어긋난 판단을 할 수 있다. 조건으로 읽히는 곳만 고친다.
- **과거 ADR 본문을 고쳐 쓰기:** ADR 규칙상 과거 결정을 고쳐 쓰지 않는다. 이 ADR이 대체하고 이전 ADR에는 비고만 단다.

## 결과

- Codex 실행 범위는 이제 Codex CLI 설정이 기계적으로 정하고, 저장소 문서의 목록으로는 확인하지 않는다. 다른 시험
  프로젝트(hoplites, acropolis, thesmothetai)에서 Codex 리뷰가 도는지는 각 프로젝트의 CLI 설정에 달렸다. 데일리 워커를
  그 프로젝트들에 적용하는 것은 여전히 각 프로젝트의 예약·머지 권한 승인 기록이 필요하다.
- 구현 PR #34가 머지된 [ADR 0019](0019-taeguk-codex-purpose-context.md)를 이 PR에서 승인으로 바꾼다.
- 이 ADR은 구현 PR이 머지된 뒤 다음 PR에서 승인으로 바꾼다.
