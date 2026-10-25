# ADR 0002: 도메인 모델 표현과 JSON 코덱

- 상태: 승인 (PR #8 머지, 2026-10-25)
- 날짜: 2026-10-25
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`

## 맥락

Phase 1은 upstream `common` 모듈의 정의 모델(`WorkflowDef`, `WorkflowTask`, `TaskDef`와 하위 타입)과
실행 모델(`Workflow`, `Task`, `TaskResult`)을 Elixir로 옮긴다. 기준은 Java 클래스 구조가 아니라
`priv/contract/*.json` 스키마와 `test/fixtures/contract/`의 골든 픽스처다. 모델은 세 가지를 동시에
만족해야 한다.

1. upstream Jackson 설정(`common/.../config/ObjectMapperProvider.java`)이 만드는 JSON과 같은 JSON을
   읽고 쓴다. null 필드 생략(`NON_NULL`), 미지 필드 무시, primitive 필드의 null 허용, getter가 덧붙이는
   파생 키(`Task.queueWaitTime`, `Workflow.startTime` 등)가 포함된다.
2. 재귀 구조(`decisionCases`의 map-of-list, `forkTasks`의 list-of-list, `loopOver`, `Workflow.history`)를
   표현한다.
3. Phase 2 Decider가 패턴 매칭으로 다루기 쉽고, Phase 4 Postgres 영속화를 막지 않는다.

## 결정

**Ecto embedded schema 대신 typed struct와 필드 표 기반 코덱을 쓴다.**

- 각 모델은 `defstruct`와 손으로 쓴 `@type t`를 갖고, 필드를 `{key, json_name, type, opts}` 표로
  선언한다. `Archon.Domain.Codec`이 이 표로 `from_json/2`·`to_json/1`을 수행한다.
- 누락 키는 Java 필드 초기값(`:default`), 명시적 `null`은 `:null` 옵션 값으로 읽는다. primitive(`:int`,
  `:bool`)는 0/false, boxed 타입과 컬렉션은 `nil`, null을 대체하는 setter·getter가 있으면 그 값이다.
  struct 기본값은 누락 키 디코딩 결과와 같아서 `%WorkflowTask{}`가 Java `new WorkflowTask()`와 같다.
- enum은 atom(`:time_out_wf`)이고 wire에서는 upstream 상수명(`"TIME_OUT_WF"`)이다. `WorkflowTask.type`처럼
  upstream이 임의 문자열을 받는 필드는 문자열로 둔다.
- 파생 키는 각 모델의 `to_json/1`이 upstream getter와 같은 규칙으로 계산하고, 디코딩에서는 무시한다.
- bean validation은 디코딩과 분리한 `validate/2`로 옮긴다. 메시지는 upstream 어노테이션 문구를 그대로
  쓰고, 서버 설정에 따라 달라지는 제약(`ownerEmailMandatory`, 이름 패턴)은 옵션으로 받으며 기본값은
  upstream 배포 설정(`server/src/main/resources/application.properties`, 둘 다 `false`)을 따른다.

### Ecto를 쓰지 않은 이유

- `decisionCases`(`Map<String, List<WorkflowTask>>`), `forkTasks`(`List<List<WorkflowTask>>`),
  `onStateChange`는 `embeds_many`로 표현되지 않아 결국 커스텀 `Ecto.Type`이 필요하다.
  `SubWorkflowParams.workflowDefinition`(정의 객체 | `${...}` 문자열 | null)과 `priority`(정수 | 문자열)도
  마찬가지다.
- Jackson의 "누락 vs null" 구분, `NON_NULL` 생략, 파생 키, 스칼라 강제 변환은 changeset `cast/3`의
  모델과 맞지 않는다. 결국 Ecto 위에 같은 규칙을 다시 쓰게 된다.
- upstream의 Postgres 영속화(`postgres-persistence`)도 workflow·task·정의를 JSON 문서(`json_data TEXT` 컬럼, `V1__initial_schema.sql`)로
  저장한다. Phase 4는 같은 방식으로 이 코덱의 출력을 `jsonb`에 넣고, 조회용 컬럼(id, status, 시각)만 따로
  둘 수 있다. 행 단위 Ecto schema가 필요하면 그때 저장 계층에서 정의하고 도메인 struct와 분리한다.
- 의존성을 늘리지 않는다(현재 런타임 의존성 없음).

## upstream과 의도적으로 다른 점

- JSON 객체의 키 순서는 보존하지 않는다. `decisionCases`도 Elixir map이라 순회 순서가 키 정렬 순이다
  (upstream은 `LinkedHashMap` 삽입 순).
- `Workflow.failedReferenceTaskNames`·`failedTaskNames`(Java `Set`)는 리스트로 두고 디코딩 때 중복만
  제거한다.
- 정의 없는 `Workflow`를 직렬화하면 upstream은 `workflowName` getter에서 예외를 던지지만 Archon은 두
  키를 생략한다.
- protobuf 전용 `Task.inputMessage`·`outputMessage`, `TaskResult.outputMessage`(`@Hidden`)는 모델링하지
  않는다.
- `${...}` 입력 참조의 경로 문법 검사는 Jayway `JsonPath.compile` 대신 근사 규칙(공백·괄호·후행 `.`)을
  쓴다(`WorkflowDef.input_path_valid?/1`).
- `reasonForIncompletion` 500자 절단은 UTF-16 코드 단위가 아니라 Unicode 코드포인트 기준이다.

## 결과

- 골든 픽스처의 모든 도메인 응답 body가 decode → encode 후 원본과 일치하고(`normalize/1` 기준이며
  실제로는 바이트 수준까지 같다), 등록 요청은 upstream이 저장해 돌려준 정의와 서버 채움 필드를 빼고
  일치한다(`test/archon/domain/contract_round_trip_test.exs`).
- core 모듈의 `WorkflowTaskTypeConstraint`(태스크 타입별 필수 필드)와 `WorkflowDef`의 Decider용 탐색
  메서드(`getNextTask` 등)는 Phase 2 범위로 남긴다.
