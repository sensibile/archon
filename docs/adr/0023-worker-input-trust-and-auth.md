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

- **쓰기.** `Archon.Runtime.Step.Tasks.result_task/3`가 갱신 결과의 `subWorkflowId`를 태스크 타입과 관계없이 태스크의
  `sub_workflow_id`와 `outputData["subWorkflowId"]`에 넣는다(upstream `WorkflowExecutorOps.updateTask`의
  `task.setSubWorkflowId(taskResult.getSubWorkflowId())`). worker는 SUB_WORKFLOW 태스크의 taskId를 조회 API로 알 수 있고,
  upstream처럼 시스템 태스크도 갱신할 수 있다(WAIT 등을 밖에서 끝내는 용도).
- **대체값.** `Archon.Domain.Task.sub_workflow_id/1`은 저장된 값이 비면 `outputData["subWorkflowId"]`, 그다음
  `inputData["subWorkflowId"]`를 쓴다(upstream `getSubWorkflowId`). 정의를 쓰는 쪽이 SUB_WORKFLOW 태스크의 `inputParameters`에
  `subWorkflowId`를 넣으면 자식이 시작되기 전의 종료(`Step.Terminate`)가 그 ID를 대상으로 삼는다.
- **사용처.** 부모 종료의 자식 취소(`Step.Terminate`, outbox의 `:terminate_sub_workflow`, `SubWorkflows.terminate_child/4`),
  형제 실패 자식 재시도(`:retry_sub_workflow`, `SubWorkflows.retry_child/2`), `resumeSubworkflowTasks` 하강
  (`Archon.Runtime.Lifecycle.last_failed/3`), 자식 상태 읽기와 반영(`WorkflowServer`가 `Env.workflows`에 읽는 자식, `Step.Async`,
  `Step.Lifecycle`의 되살림, 활성화 복구 검사).
- 이 때문에 런타임에는 자기 자신·조상을 자식으로 가리키는 경우를 위한 우회 코드가 있다: `SubWorkflows`의 `ancestor?/3`,
  `cancel_later/2`, `in_process:` 옵션, `retry_child/2`의 자기·조상 건너뛰기, `Lifecycle.last_failed/3`의 `seen`.

upstream OSS 문서는 인증이 없다고 밝힌다(`docs/devguide/how-tos/cicd-integration.md:112`, 서버를 사설망에 두라고 권한다).
Orkes 배포는 `POST /token`(keyId·keySecret)으로 받은 토큰을 `X-Authorization` 헤더로 보내지만, 이 경로는 OSS 계약과
OpenAPI 스냅샷(`priv/contract/openapi.json`)에 없다.

## 결정

### 1. SUB_WORKFLOW 태스크의 `subWorkflowId`는 런타임이 정한 값만 쓴다

- 태스크 갱신(`Tasks.update/1`, `Tasks.update_v2/1`)이 SUB_WORKFLOW 태스크에 닿으면 `TaskResult.subWorkflowId`를 반영하지 않고
  저장된 `sub_workflow_id`를 그대로 둔다. `outputData`의 `"subWorkflowId"` 키는 저장된 값이 있으면 그 값으로 덮고, 없으면 지운다.
  상태·출력·실패 이유 같은 나머지 필드는 지금처럼 반영한다(upstream처럼 SUB_WORKFLOW 태스크를 밖에서 끝내는 일은 막지 않는다).
- 다른 타입의 태스크는 지금처럼 저장한다. 런타임이 그 값을 자식으로 쓰는 곳은 SUB_WORKFLOW 태스크뿐이다.
- 런타임이 정하는 값은 자식을 시작할 때의 ID(`Step.SubWorkflow`의 `start_id`)다. 시작 전의 태스크는 값이 없다.

### 2. 자식으로 쓰는 워크플로우는 소유권을 확인한다

어떤 워크플로우 C를 워크플로우 P의 SUB_WORKFLOW 태스크 T의 자식으로 쓰려면 C의 `parentWorkflowId`가 P의 ID이고
`parentWorkflowTaskId`가 T의 taskId여야 한다. 두 필드는 런타임이 자식을 만들 때 정하고 바뀌지 않으며, 시작 REST
(`StartWorkflowRequest`)로는 정할 수 없다. 이 확인은 ID가 어디서 왔든(worker, 정의 입력, 저장된 옛 데이터) 적용한다.

- **상대 프로세스가 확인한다.** 취소와 재시도는 대상 워크플로우의 프로세스가 자기 기록으로 확인한다. 그 프로세스가 유일한
  쓰기 주체라서(ADR 0018 결정 1) 확인과 처리 사이에 기록이 바뀌지 않는다. `{:cancel_by_parent, ...}`와 재시도 요청은 보내는
  부모의 ID와 태스크 ID를 담고, 맞지 않으면 대상은 아무것도 하지 않고 `{:error, :not_owner}`로 답한다.
  - 자식 취소에서 `:not_owner`는 "자식 없음"과 같게 성공으로 본다(outbox는 ack). 부모 종료는 막히지 않는다.
  - 형제 자식 재시도에서 `:not_owner`는 기록하고 ack한다(ADR 0021 결정 4의 허용 목록에 더한다).
- **읽기는 걸러 낸다.** `WorkflowServer`가 자식을 `Env.workflows`에 읽을 때 소유권이 맞지 않는 워크플로우는 넣지 않는다. 그래서
  `Step`은 그런 ID를 "자식을 읽을 수 없음"으로 본다(지금 그 경우의 규칙 그대로). `Lifecycle.last_failed/3`의 하강도 소유권이
  맞는 자식으로만 내려간다(맞지 않으면 upstream `NotFoundException` 경우처럼 그 위 워크플로우를 재시도한다).
- **자식 → 부모 알림.** `child_revived`와 `child_changed`는 보내는 자식의 ID를 담고, 부모는 그 태스크의 `sub_workflow_id`가 그
  자식일 때만 처리한다. 지금의 세대 확인("그 태스크가 지금 그 자식에 붙어 있음", ADR 0018 결정 5)을 두 알림 모두에 적용한다.
  부모 쪽 주소는 자식의 `parentWorkflowId`(런타임이 정한 값)라서 worker가 바꿀 수 없다.
- 시작의 소유자 확인(`start_workflow_idempotent/1`, upstream `validateIdempotentWorkflowOwnership`)은 지금 그대로다.

### 3. 조상·순환 우회 코드를 없앤다 (L6, L7)

결정 2로 자식 관계는 런타임이 만든 부모 사슬과 같아진다. 부모 사슬은 생성 때 이미 있는 워크플로우를 가리키므로 순환이
없고, 조상은 자기 부모의 자식이 될 수 없다. 그래서 다음을 없앤다.

- `SubWorkflows`의 `ancestor?/3`, `cancel_later/2`, `terminate_child/4`의 `in_process:` 옵션과 조상 분기. 종료 경로 `pre`의 조상
  취소 Task가 없어지므로 L6의 남은 빈틈도 없어진다.
- `retry_child/2`의 자기·조상 건너뛰기(자기 자신은 결정 2의 확인에서 `:not_owner`가 된다).
- `Lifecycle.last_failed/3`의 `seen`은 결정 2로 필요 없어지지만, 저장소가 손상된 경우의 방어로 남겨도 된다(조각이 정한다).

L7은 서로를 자식으로 가리키는 워크플로우가 생길 수 없으므로 닫힌다. L8은 관계없는 워크플로우가 소유권 확인을 통과할 수
없으므로 닫힌다.

### 4. MVP REST는 인증 없이 열고, 기본 주소는 `127.0.0.1`이다

- Phase 5 MVP REST는 upstream OSS처럼 인증·인가가 없다. 도달할 수 있는 호출자는 모든 정의와 워크플로우를 다룰 수 있다
  (upstream과 같은 신뢰 모델. `DELETE /api/workflow/{id}`로 어떤 워크플로우든 종료할 수 있다). 결정 1~3은 이 모델 안에서도
  worker 갱신 하나가 그 태스크의 워크플로우 밖에 영향을 주지 않게 한다.
- `ArchonWeb.Endpoint`의 기본 주소는 `127.0.0.1`이고 포트는 8080이다. 다른 주소는 설정으로만 연다: `config/runtime.exs`의
  환경 변수 `ARCHON_HTTP_IP`(예: `0.0.0.0`)와 `PORT`. 외부에 열 때는 사설망이나 인증하는 역프록시 뒤에 둔다는 점을 README의
  호환성·배포 절에 적는다(조각 5f).
- 인증(예: Orkes 호환 `POST /api/token` + `X-Authorization`, 또는 고정 토큰)은 Later의 별도 ADR이다. 그 ADR은 stock SDK가 붙는
  방법, 권한 범위, 이 결정의 기본 주소를 다시 본다.

### 5. 구현과 시험 (조각 5b)

[ADR 0022](0022-phase5-rest.md) 결정 7의 조각 5b가 결정 1~3을 구현한다. 태스크 갱신 REST(조각 5e)는 5b가 머지된 뒤에 시작한다.

- 시험
  - worker가 SUB_WORKFLOW 태스크에 다른 워크플로우의 ID를 넣어 갱신해도 저장된 `subWorkflowId`와 출력이 바뀌지 않는다.
  - 부모 종료가 관계없는 워크플로우(L8), 부모 자신, 조상을 취소하지 않는다. 정의 `inputParameters.subWorkflowId`로 시작 전의
    태스크가 다른 워크플로우를 가리켜도 같다.
  - 순환을 이루도록 위조한 저장 데이터에서 종료가 call timeout 없이 끝난다(L7).
  - `resumeSubworkflowTasks`가 소유권이 맞지 않는 ID로 내려가지 않는다.
  - 형제 자식 재시도가 `:not_owner`로 ack되고, 자식 → 부모 알림이 다른 자식의 ID로는 처리되지 않는다.
  - 기존 런타임 시험 전부를 두 백엔드에서 통과한다. 위조 ID를 전제로 한 기존 시험(자기·조상 취소 등)은 새 규칙의 기대값으로 바꾼다.
- 건드리는 파일: `lib/archon/runtime/step/{tasks,terminate,async,lifecycle,sub_workflow}.ex`,
  `lib/archon/runtime/{workflow_server,sub_workflows,lifecycle,outbox}.ex`,
  `test/archon/runtime/{sub_workflow,lifecycle,outbox,step_tasks,tasks}_test.exs`.

## upstream과 의도적으로 다른 점

- **SUB_WORKFLOW 태스크 갱신의 `subWorkflowId`를 반영하지 않는다**(결정 1). upstream은 값을 그대로 저장하고, 비어 있으면 출력·입력의
  같은 키로 대신한다.
- **자식의 소유권을 확인한다**(결정 2). upstream은 태스크의 `subWorkflowId`가 가리키는 워크플로우를 확인 없이 취소·재시도하고
  읽는다.
- **기본 주소가 `127.0.0.1`이다**(결정 4). upstream Spring Boot는 모든 주소에서 듣는다.

## 대안

- **upstream 신뢰 유지(ADR 0018 결정 그대로):** 계약 차이가 없지만 L7·L8이 남고, ADR 0021의 출시 조건을 채우지 못한다.
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
