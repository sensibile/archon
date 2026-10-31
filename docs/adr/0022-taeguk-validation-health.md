# ADR 0022: 태극 검증 건강도 워커 적용과 주간 CI 실행

- 상태: 제안
- 날짜: 2026-11-01
- 태극 원본: sensibile/taeguk `42fb9647ac8ceb17708e173344a3f924baa9cecc`(sensibile/taeguk#31 머지 커밋)

## 맥락

archon CI는 push와 PR 때만 돈다. 변경이 없는 날의 `main`은 검증을 받지 않는다. 데일리 정리와 테스트 보강
워커([ADR 0013](0013-taeguk-daily-workers.md))는 이 Mac의 로컬 툴체인으로 검증하는데, 코드가 그대로여도 툴체인이
바뀌면 검증이 깨질 수 있다. 간헐적으로 실패하는 테스트도 워커 PR의 실패로 섞여 보인다.

태극은 sensibile/taeguk#31에서 `taeguk-validation-health` 스킬을 추가했다. 매일 최신 `origin/main`에서 검증 전체를
돌리고, 실패한 스위트를 한 번 다시 돌려 결정적 실패와 간헐 실패 의심을 나눠 보고만 한다. 같은 PR에서 태극 CI에
주간 schedule을 넣었다. 2026-10-29 BOSS가 태극에서 이 기본값(매일 정리 전 실행, 보고만, 주간 CI schedule, 후속 워커
게이트 없음)을 승인했다. 스킬의 "Where it runs" 절에 따라, 설치 프로젝트에서는 그 프로젝트가 BOSS 승인(예약과 보고
위치)을 기록한 경우에만 돈다. archon에는 스킬이 이미 설치돼 있지만 승인 기록이 없었다.

2026-11-01 태극 세션에서 BOSS가 "archon 도 검증 건강도 작업 추가해"라고 했다. 같은 날 archon 세션에서 Postgres
스위트를 실행마다 일회용 컨테이너로 돌리는 방식을 골랐다.

## 결정

1. **archon에서 검증 건강도 워커를 매일 돌린다.** 승인 내용과 archon용 실행 방법은 [운영 문서](../operations.md)에
   둔다. 스킬이 요구하는 BOSS 승인 기록은 그 문서다.
   - 예약: 이 Mac의 로컬 Claude 예약 작업 `archon-validation-health`, 매일 08:41. 태극 검증 건강도(08:31) 다음,
     archon 데일리 정리(09:01) 전이다.
   - 권한: 보고만 한다. 코드, 테스트, lockfile, 툴체인, CI를 바꾸지 않고 PR이나 이슈를 열지 않는다. 데일리 정리와
     테스트 보강의 실행을 막지 않는다.
   - 보고 위치: main checkout의 `.taeguk/validation-health/<날짜>.md`. Git에서 무시한다.
2. **스위트는 AGENTS.md 검증 명령과 CI가 도는 단계를 따른다.** `mix deps.unlock --check-unused`, `mix hex.audit`,
   Postgres를 요구하는 `mix test`와 `ARCHON_BACKEND=postgres mix test`를 포함한다. 설치된 `taeguk-*` 스킬은
   skill-creator 검증기로 확인한다. 목록은 운영 문서에 있다. sanitizer 빌드(`c-sanitize` job)는 Linux CI 전용이라
   로컬에서는 NOT_APPLICABLE이고, 결정 4의 주간 CI가 본다.
3. **Postgres 스위트는 실행마다 일회용 컨테이너에서 돌린다.** CI `services.postgres`와 같은 이미지를 docker로
   `127.0.0.1`의 임의 포트에 띄우고, 일회용 비밀번호를 만들어 `DATABASE_URL`에 쓴다. 끝나면 컨테이너를 지운다.
   다른 세션의 컨테이너나 기존 데이터베이스를 쓰지 않는다. docker가 없거나 이미지를 받지 못하거나 서버가 준비되지
   않으면 Postgres 스위트는 NOT_RUN이고 원인을 기록한다. 서버를 설치하거나 docker 설정을 바꾸지 않는다.
4. **CI에 주간 schedule을 둔다.** `.github/workflows/ci.yml`이 매주 월요일 08:27(KST, cron `27 23 * * 0`)에
   `main`을 검증한다. 로컬 점검과 달리 GitHub runner의 툴체인과 `c-sanitize` job을 본다. job과 권한은 바꾸지 않는다.
5. **실패를 고치지 않는다.** 결정적 실패나 두 번 이상 보고된 간헐 실패 후보의 수정은 별도 작업으로 시작한다.

## 대안

- **Postgres는 닿으면 쓰고 없으면 NOT_RUN:** 워커가 서버를 띄우지 않아 단순하다. 이 Mac에서는 기본 포트 5432에
  다른 용도의 서버가 응답할 수 있고, `DATABASE_URL`이 없으면 그 서버에 `archon_test`를 만든다. 다른 세션의
  데이터베이스와 섞일 위험이 있고, 늘 NOT_RUN이면 Postgres 백엔드를 매일 보지 못해 채택하지 않았다.
- **GitHub Actions 예약만 사용:** 로컬 툴체인 변화와 워커가 실제로 쓰는 환경을 보지 못한다. 그래서 주간 CI는
  보조로만 둔다.
- **매일 CI 예약:** 로컬 점검과 겹치고 runner 사용량만 늘어 태극 기본값대로 주간으로 둔다.

## 결과

- 매일 아침 `main`이 이 Mac의 툴체인에서 통과하는지와 간헐 실패 후보가 보고된다. 통과는 "이 SHA와 툴체인에서
  오늘 검증이 통과했다"는 뜻이고 코드 품질 판정이 아니다.
- 워커는 매번 새 worktree에서 의존성을 받고 dialyzer PLT를 새로 만든다. 실행 시간이 길어지는 대신 다른 워커의
  빌드 산출물과 섞이지 않는다.
- 예약 작업은 저장소 밖(`~/.claude/scheduled-tasks/`)에 있다. 이 Mac이 꺼져 있거나 docker가 멈춰 있으면 해당
  실행이나 스위트가 NOT_RUN으로 보고된다.
- 주간 CI schedule은 기본 브랜치의 workflow로 돈다. 공개 저장소에서 60일 동안 활동이 없으면 GitHub가 예약
  실행을 끈다. 필수 체크(`test`, `credo`, `dialyzer`, `audit`)는 PR에서 그대로 돈다.
- 이 ADR은 구현 PR이 머지된 뒤 다음 PR에서 승인으로 바꾼다.
