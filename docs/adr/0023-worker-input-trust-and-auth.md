# ADR 0023: worker 입력의 신뢰 경계와 MVP 인증

- 상태: 제안
- 날짜: 2026-11-01
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`
- 비고: 2026-11-01 BOSS가 추천안(런타임 소유권 규칙으로 L7·L8을 닫고, MVP REST는 인증 없이 기본 `127.0.0.1`)을 골랐다.

## 맥락

[ADR 0018](0018-phase3-otp-runtime.md) 결과 절은 워커 `TaskResult`의 `subWorkflowId`를 upstream `updateTask`처럼 그대로 저장하기로
했다(BOSS 2026-10-30). upstream OSS는 워커와 API 호출자를 신뢰하고 권한 모델이 없다. 그 결과 다음 한계가 남았다
([ADR 0021](0021-phase4-postgres-persistence.md) 맥락의 표).

| 번호 | 한계 |
|---|---|
| L6(남은 부분) | 종료 경로 `pre`의 조상 취소는 감독되는 Task로 띄우기만 하므로 VM과 함께 사라질 수 있다(ADR 0021 결정 4 "조상 취소") |
| L7 | worker가 준 `subWorkflowId`들이 조상 사슬이 아닌 순환을 이루면 종료가 call timeout까지 기다린다 |
| L8 | worker가 준 `subWorkflowId`로 관계없는 워크플로우가 취소·재시도될 수 있다 |

ADR 0021 결과 절은 이 경로를 태스크 갱신 REST가 외부에 열리기 전에 인증·인가 ADR이 닫으라고 했다. 이 문서가 그 ADR이다.

실제 경로는 다음과 같다(archon `875c6c2`).

- **쓰기.** `Archon.Runtime.Step.Tasks.result_task/3`는 갱신 결과의 `subWorkflowId`를 태스크 타입과 관계없이 태스크의
  `sub_workflow_id`에 넣고, worker 출력에 `"subWorkflowId"` 키가 있으면 그 값도 같은 값으로 바꾼다(upstream
  `WorkflowExecutorOps.updateTask`의 `task.setSubWorkflowId(taskResult.getSubWorkflowId())`). worker는 SUB_WORKFLOW 태스크의
  taskId를 조회 API로 알 수 있고, upstream처럼 시스템 태스크도 갱신할 수 있다(WAIT 등을 밖에서 끝내는 용도).
- **대체값.** `Archon.Domain.Task.sub_workflow_id/1`은 저장된 값이 비면 `outputData["subWorkflowId"]`, 그다음
  `inputData["subWorkflowId"]`를 쓴다(upstream `getSubWorkflowId`). 정의를 쓰는 쪽이 SUB_WORKFLOW 태스크의 `inputParameters`에
  `subWorkflowId`(예: `${workflow.parentWorkflowId}`)를 넣으면, 저장된 값이 아직 없는 태스크의 종료(`Step.Terminate`)가 그 ID를
  대상으로 삼는다. 이 경로는 worker 없이 정의만으로 생긴다.
- **사용처.** 부모 종료의 자식 취소(`Step.Terminate`, 종료 경로 `pre`의 `Effects` → `SubWorkflows.terminate_child/4`, outbox의
  `:terminate_sub_workflow`), 형제 실패 자식 재시도(`:retry_sub_workflow`, `SubWorkflows.retry_child/2`), `resumeSubworkflowTasks`
  하강(`Archon.Runtime.Lifecycle.last_failed/3`), 자식 상태 읽기와 반영(`WorkflowServer.workflows/1`·`failed_children/2`가
  `Env.workflows`에 읽는 자식, `Step.Async`, `Step.Lifecycle`의 되살림, `Step.Recover`의 복구 검사).
- 그래서 런타임에는 자기 자신·조상을 자식으로 가리키는 경우를 위한 우회 코드가 있다: `SubWorkflows`의 `ancestor?/3`,
  `cancel_later/2`, `terminate_child/4`의 `in_process:` 옵션과 자기 자신 가드, `retry_child/2`의 자기·조상 건너뛰기,
  `Lifecycle.last_failed/3`의 `seen`. 종료 경로 `pre`는 워크플로우 프로세스 안에서 자식을 동기 호출하므로, 조상을 그대로
  호출하면 조상이 이 프로세스를 다시 호출해 교착이 된다. `cancel_later/2`가 그것을 피한다.
- 자식의 `parentWorkflowId`·`parentWorkflowTaskId`는 런타임이 자식을 만들 때 정하고 바뀌지 않는다. 시작 REST의
  `StartWorkflowRequest`에는 두 필드가 없다(upstream `StartWorkflowRequest.java`). 다만 `Archon.Runtime.start_workflow/1`의 입력
  맵은 두 키를 받으므로(하위 워크플로우 시작용), REST가 그 맵을 요청 필드로만 만들어야 한다.

upstream OSS 문서는 인증이 없다고 밝힌다(`docs/devguide/how-tos/cicd-integration.md:112`, 서버를 사설망에 두라고 권한다).
Orkes 배포는 `POST /token`(keyId·keySecret)으로 받은 토큰을 `X-Authorization` 헤더로 보내지만, 이 경로는 OSS 계약과
OpenAPI 스냅샷(`priv/contract/openapi.json`)에 없다.

## 결정

### 1. SUB_WORKFLOW 태스크의 `subWorkflowId`는 런타임이 정한 값만 쓴다

- 태스크 갱신(`Tasks.update/1`, `Tasks.update_v2/1`)이 SUB_WORKFLOW 태스크에 닿으면 `TaskResult.subWorkflowId`를 반영하지 않고
  저장된 `sub_workflow_id`를 그대로 둔다. worker 출력에 `"subWorkflowId"` 키가 있으면 저장된 값으로 덮고(저장된 값이 없으면 키를
  지운다), 키가 없으면 지금처럼 그대로 둔다. 상태·출력·실패 이유 같은 나머지 필드는 지금처럼 반영한다(upstream처럼 SUB_WORKFLOW
  태스크를 밖에서 끝내는 일은 막지 않는다).
- 다른 타입의 태스크는 지금처럼 저장한다. 런타임이 그 값을 자식으로 쓰는 곳은 SUB_WORKFLOW 태스크뿐이다.
- 런타임이 정하는 값은 `Step.SubWorkflow`가 자식을 시작할 때의 ID(`start_id`)와, 실패한 자식을 다시 시작하는 재시도 분기
  (`started/3`)가 새로 정해 저장하는 ID다.

### 2. 자식으로 쓰는 워크플로우는 소유권을 확인한다

어떤 워크플로우 C를 워크플로우 P의 SUB_WORKFLOW 태스크 T의 자식으로 쓰려면 C가 P의 자식이어야 한다. 이 확인은 ID가 어디서
왔든(worker, 정의 입력의 대체값, 저장된 옛 데이터) 적용하고, 두 필드는 바뀌지 않으므로 확인과 사용 사이에 경합이 없다.

- **호출은 보내는 쪽이 먼저 확인한다.** 자식 취소(`SubWorkflows.terminate_child/4`, 종료 경로 `pre`와 outbox 모두)와 형제 자식
  재시도(`SubWorkflows.retry_child/2`)는 대상을 호출하기 전에 저장소에서 대상을 읽어(`Runtime.get_workflow(id, false)`)
  `parentWorkflowId`가 소유 워크플로우의 ID인지 본다. 맞지 않으면 호출하지 않는다.
  - 취소에서 맞지 않거나 대상 기록이 없으면 지금의 "자식 없음"(`:not_found`)처럼 성공으로 본다. 부모 종료는 막히지 않고 outbox
    항목은 ack된다.
  - 재시도에서 맞지 않으면 경고를 남기고 `:ok`(ack)다. 지금의 자기·조상 건너뛰기와 같은 처리다.
  - 대상을 호출하지 않으므로 관계없는 워크플로우의 프로세스를 활성화하지도 않는다. 종료 경로 `pre`가 워크플로우 프로세스 안에서
    조상을 동기 호출하는 일(교착)도 생기지 않는다. 조상은 부모 사슬에 순환이 없으므로 그 워크플로우의 자식일 수 없다.
  - Effect와 outbox 항목의 모양(`{:terminate_sub_workflow, child_id, reason[, parent_end_count]}`, `{:retry_sub_workflow, child_id}`)은
    바꾸지 않는다. 소유 워크플로우 ID는 실행기가 이미 인자로 받는다(ADR 0021 결정 4). 그래서 이 두 호출은 태스크 ID까지는 보지
    않고 `parentWorkflowId`만 본다. 같은 부모의 다른 태스크의 자식을 가리키는 경우는 결정 1로 worker가 만들 수 없고, 부모 종료는
    어차피 모든 자식을 취소한다.
- **읽기는 쓰는 곳에서 거른다.** `Env.workflows`는 부모, 자식, 실패 워크플로우를 ID 하나로 담는 맵이므로 읽을 때 지우지 않는다
  (태스크의 대체값이 부모 ID와 같으면 부모 항목까지 지워져 `Step.Recover`의 고아 검사가 멈춘다). 대신 `Archon.Runtime.Step.Env`에
  `child/2`(태스크 T의 자식: 맵에 있고 `parentWorkflowId`가 P, `parentWorkflowTaskId`가 T의 taskId인 워크플로우, 아니면 `nil`)를
  두고, 자식을 쓰는 모든 곳(`Step.Async`, `Step.Lifecycle`의 되살림·형제 처리, `Step.Recover`의 종료 상태 검사, `Step.SubWorkflow`의
  붙이기 확인)이 이 도우미로만 자식을 꺼낸다. 맞지 않는 ID는 "자식을 읽을 수 없음"으로 본다(지금 그 경우의 규칙 그대로).
- **`resumeSubworkflowTasks` 하강.** `Lifecycle.last_failed/3`은 읽은 자식의 `parentWorkflowId`·`parentWorkflowTaskId`가 지금
  워크플로우와 태스크일 때만 내려간다. 맞지 않으면 upstream `NotFoundException` 경우처럼 그 위 워크플로우를 재시도한다.
- **자식 → 부모 알림은 바꾸지 않는다.** `child_revived`·`child_changed`의 주소(부모 ID와 부모 태스크 ID)는 자식 자신의
  `parentWorkflowId`·`parentWorkflowTaskId`에서 오므로 worker가 바꿀 수 없다. 부모가 그 태스크의 자식을 읽는 일은 위 `Env.child/2`를
  거친다.
- **시작의 소유자 확인과 자기 자신 가드는 그대로다.** `start_workflow_idempotent/1`의 소유자 확인(upstream
  `validateIdempotentWorkflowOwnership`), `SubWorkflows.start_child/1`의 "자기 자신을 시작" 절, `terminate_child/4`·`retry_child/2`의
  자기 자신 가드는 프로세스가 자기를 호출하지 않게 하는 마지막 방어로 남긴다.

### 3. 조상 우회 코드를 없앤다 (L6, L7)

결정 2로 자식 관계는 런타임이 만든 부모 사슬과 같아진다. 부모 사슬은 생성 때 이미 있는 워크플로우를 가리키므로 순환이
없고, 조상은 자기 자손의 자식이 될 수 없다. 그래서 다음을 없앤다.

- `SubWorkflows`의 `ancestor?/3`, `cancel_later/2`, `terminate_child/4`의 `in_process:` 옵션과 조상 분기, `Effects`가 그 옵션을 넘기는
  곳. 종료 경로 `pre`의 조상 취소 Task가 없어지므로 L6의 남은 빈틈도 없어진다.
- `retry_child/2`의 조상 건너뛰기.
- `Lifecycle.last_failed/3`의 `seen`은 결정 2로 필요 없어지지만, 저장소가 손상된 경우의 방어로 남겨도 된다(조각이 정한다).

L7은 서로를 자식으로 가리키는 워크플로우가 생길 수 없으므로 닫힌다. L8은 관계없는 워크플로우가 소유권 확인을 통과할 수
없으므로 닫힌다.

### 4. MVP REST는 인증 없이 열고, 기본 주소는 `127.0.0.1`이다

- Phase 5 MVP REST는 upstream OSS처럼 인증·인가가 없다. 도달할 수 있는 호출자는 모든 정의와 워크플로우를 다룰 수 있다
  (upstream과 같은 신뢰 모델. `DELETE /api/workflow/{id}`로 어떤 워크플로우든 종료할 수 있다). 결정 1~3은 이 모델 안에서도
  worker 갱신이나 정의 입력 하나가 그 워크플로우 트리 밖에 영향을 주지 않게 한다.
- `ArchonWeb.Endpoint`의 기본 주소는 `127.0.0.1`이고 포트는 8080이다. 다른 주소는 설정으로만 연다: `config/runtime.exs`의
  환경 변수 `ARCHON_HTTP_IP`(예: `0.0.0.0`)와 `PORT`. 외부에 열 때는 사설망이나 인증하는 역프록시 뒤에 둔다는 점을 README의
  호환성·배포 절에 적는다(조각 5f).
- 시작 REST는 `Archon.Runtime.start_workflow/1`의 입력 맵을 `StartWorkflowRequest`의 필드와 경로·쿼리 값으로만 만든다. 부모 필드는
  넣지 않는다(조각 5d, 시험 포함).
- 인증(예: Orkes 호환 `POST /api/token` + `X-Authorization`, 또는 고정 토큰)은 Later의 별도 ADR이다. 그 ADR은 stock SDK가 붙는
  방법, 권한 범위, 이 결정의 기본 주소를 다시 본다.

### 5. 구현과 시험 (조각 5b)

[ADR 0022](0022-phase5-rest.md) 결정 7의 조각 5b가 결정 1~3을 구현한다. 태스크 갱신 REST(조각 5e)는 5b가 머지된 뒤에 시작한다.

- 시험
  - worker가 SUB_WORKFLOW 태스크에 다른 워크플로우의 ID를 넣어 갱신해도 저장된 `subWorkflowId`와 출력이 바뀌지 않는다.
  - 부모 종료가 관계없는 워크플로우(L8), 부모 자신, 조상을 취소하지 않고 그 프로세스를 활성화하지 않는다.
  - 조부모 A를 종료할 때, 자식 P의 SUB_WORKFLOW 태스크(저장된 `subWorkflowId` 없음)의 `inputParameters.subWorkflowId`가
    `${workflow.parentWorkflowId}`(즉 A)여도 call timeout 없이 끝난다(지금 `cancel_later/2`가 막는 교착).
  - 순환을 이루도록 위조한 저장 데이터에서 종료가 call timeout 없이 끝난다(L7).
  - 형제 자식 재시도가 소유권이 맞지 않는 대상을 호출하지 않고 ack된다.
  - `resumeSubworkflowTasks`가 소유권이 맞지 않는 ID로 내려가지 않는다.
  - `Env.child/2`가 부모 ID와 같은 대체값에서 `nil`을 돌려주고, 그때도 `Step.Recover`의 고아 검사가 부모를 읽는다.
  - 기존 런타임 시험 전부를 두 백엔드에서 통과한다. 위조 ID를 전제로 한 기존 시험(자기·조상 취소 등)은 새 규칙의 기대값으로 바꾼다.
- 건드리는 파일: `lib/archon/runtime/step/{tasks,env,async,lifecycle,recover,sub_workflow}.ex`,
  `lib/archon/runtime/{sub_workflows,lifecycle,effects}.ex`, `test/archon/runtime/{sub_workflow,lifecycle,outbox,step_tasks,tasks,
  recovery,step}_test.exs`. `workflow_server.ex`(자식 읽기는 그대로)와 `step/terminate.ex`(취소 대상 선택은 그대로, 확인은
  `terminate_child/4`가 함)는 고치지 않는다. Effect·outbox 항목 모양을 바꾸지 않으므로 `Store.Postgres`의 인코딩과 `outbox.ex`도
  고치지 않는다.

## upstream과 의도적으로 다른 점

- **SUB_WORKFLOW 태스크 갱신의 `subWorkflowId`를 반영하지 않는다**(결정 1). upstream은 값을 그대로 저장하고, 비어 있으면 출력·입력의
  같은 키로 대신한다.
- **자식의 소유권을 확인한다**(결정 2). upstream은 태스크의 `subWorkflowId`가 가리키는 워크플로우를 확인 없이 취소·재시도하고
  읽는다.
- **기본 주소가 `127.0.0.1`이다**(결정 4). upstream Spring Boot는 모든 주소에서 듣는다.

## 대안

- **upstream 신뢰 유지(ADR 0018 결정 그대로):** 계약 차이가 없지만 L7·L8이 남고, ADR 0021의 출시 조건을 채우지 못한다.
- **대상 프로세스가 소유권을 확인:** 대상이 유일한 쓰기 주체라 깔끔해 보이지만, 종료 경로 `pre`에서 조상을 호출하면 조상이 이
  프로세스를 다시 호출하는 동안 확인할 수 없어 교착이 남는다. 메시지와 outbox 항목 모양도 바뀐다. 보내는 쪽 확인을 고른다.
- **소유권 확인만, `subWorkflowId` 반영은 유지:** 취소·재시도는 막지만 worker가 저장값을 바꾸면 부모가 자기 자식을 잃는다(읽기에서
  걸러져 "자식 없음"이 된다). 결정 1로 저장값을 지킨다.
- **`subWorkflowId` 고정만, 소유권 확인 없음:** worker 경로는 닫지만 정의의 `inputParameters.subWorkflowId` 대체값과 저장된 옛
  데이터가 남는다.
- **공유 토큰 인증 추가:** 설정하면 모든 `/api` 요청에 고정 토큰을 요구한다. stock SDK는 key/secret → 토큰 흐름만 있어 헤더를
  직접 넣는 클라이언트만 붙는다. BOSS가 Later로 미뤘다.
- **Orkes 호환 토큰과 애플리케이션별 권한:** stock SDK의 key/secret 설정으로 붙지만 OSS 계약·픽스처에 없는 경로이고 조각이 2~3개
  는다. BOSS가 Later로 미뤘다.

## 결과

- 조각 5b가 머지되면 `승인`으로 바꾸고, ADR 0018의 목록 상태에 "일부 0023이 대체"(결과 절의 `subWorkflowId` 신뢰 결정)를 적는다.
- ADR 0021의 L6 남은 부분, L7, L8은 이 ADR과 조각 5b로 닫힌다.
- 아직 범위 밖: REST 인증·인가(Later ADR), worker가 다른 워크플로우의 태스크를 taskId로 갱신하는 일(upstream과 같은 신뢰 모델 안).
