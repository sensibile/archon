# 기계 검사와 확장 계획

## 현재 검사

Taeguk 저장소의 `python3 scripts/check_rules.py`는 표준 라이브러리만 사용하고 성공은 exit 0, 오류는 exit 1과 JSON FAIL을 반환한다. registry 스키마·ID 중복·허용 상태·버전·적용 범위·본문·승인 참조·기계 검사 표시, 규칙 문서의 UTF-8/LF·제목·마지막 줄바꿈·닫힌 코드 블록·로컬 링크를 검사한다. 승인 상태의 기록이 빠지거나 문서가 연결되지 않으면 실패한다.

이 검사는 문서 구조 검사다. 승인된 문구의 의미, 승인 진실성, 필수 제품 검사 목록, 실제 효과는 검증하지 않는다. 에이전트가 파일을 바꿀 수 있으므로 독립적인 권한 통제 장치가 아니다.

## 실행 연결

Taeguk 저장소에서는 AGENTS.md의 로컬 검증 명령과 `.githooks/pre-push`에서 실행한다. hook은 `.githooks`에 보관하고 저장소 `core.hooksPath` 설정을 통해 활성화한다. 기존 hooksPath나 실행 hook이 있으면 교체하지 않고 연결 방법을 별도로 정한다. 현재 Taeguk 저장소에서 기존 실행 hook과 hooksPath가 없는 것을 확인한 뒤 `.githooks`를 활성화했다. hook은 로컬에서 우회될 수 있다. 새 clone에는 Git 설정이 복사되지 않으므로 기존 hook을 먼저 확인하고 `git config --local core.hooksPath .githooks`로 연결한다.

Taeguk 저장소의 GitHub workflow는 push와 PR에서 규칙 검사, Python 테스트, Rust 테스트, DB를 포함한 Elixir 테스트와 format 검사를 실행한다. Elixir job은 `TAEGUK_REQUIRE_STATE_TESTS=1`로 DB 검사 skip을 실패로 만든다. pre-push hook은 빠른 로컬 확인을 위해 규칙과 Python 검사만 실행한다. 필수 branch protection은 설정하지 않았으므로 CI 실패가 merge를 자동으로 막지는 않는다. 원격 설정의 세부는 [저장소 운영 기록](https://github.com/sensibile/taeguk/blob/8dbf62681faf14771c86b86dddc2d1b5f0378d33/docs/repository-operations.md)을 따른다. 로컬 통과를 원격 강제 정책으로 보고하지 않는다.

규칙을 설치한 프로젝트에는 이 검사기와 hook이 복사되지 않는다. 그 프로젝트의 검사 연결·CI·권한은 해당 프로젝트에서 정하며, 이 문서의 Taeguk 저장소 설정을 그 프로젝트의 상태로 보고하지 않는다.

## 실제 작업에서 추가할 순서

1. 작업 계약과 실제 필수 검사 목록·규칙 버전을 정한다.
2. 알려진 위반과 정상 사례로 검사기가 무엇을 잡는지 확인한다.
3. 실제 입력·실행 결과·외부 관측을 읽는 adapter를 붙인다. 모델이 적은 PASS만 읽는 검사를 강제 장치로 삼지 않는다.
4. 미실행·누락·오래된 증거·대상 불일치를 실패 또는 판정 불가로 처리한다.
5. 재현 명령과 실패 경로를 검증한 뒤 로컬 gate와 실제 CI에 연결한다. 적용 시점과 권한은 BOSS와 정한다.

먼저 관측된 누락을 자동화한다. 미리 모든 검증 도구를 설치하거나 제품별 임계값을 임의로 만들지 않는다.
