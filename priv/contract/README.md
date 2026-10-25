# Upstream contract

Archon의 REST/JSON 호환 기준이 되는 Conductor OSS 계약 자료다. 이 디렉터리의 파일은 손으로
고치지 않는다. 갱신은 아래 절차로 upstream에서 다시 가져오고, 차이는 PR에서 검토한다.

## 출처

- upstream: <https://github.com/conductor-oss/conductor>
- 기준 커밋: `1488804170d159021c7e62dce61514b8f31ef9ff` (`main`, 2026-10-23,
  "Merge pull request #1746 from RizaFarheen/js-sdk-log-level")
- 서버 버전: `conductor-server-3.30.2-SNAPSHOT`
- 라이선스: Apache License 2.0, Copyright Conductor Authors. 저장소 루트의
  [LICENSE](../../LICENSE)와 [NOTICE](../../NOTICE)를 따른다.

| 파일 | upstream 경로 | 가공 |
|---|---|---|
| `WorkflowDef.json` | `schemas/WorkflowDef.json` | 없음(바이트 동일) |
| `Workflow.json` | `schemas/Workflow.json` | 없음(바이트 동일) |
| `TaskDef.json` | `schemas/TaskDef.json` | 없음(바이트 동일) |
| `Task.json` | `schemas/Task.json` | 없음(바이트 동일) |
| `openapi.json` | 실행 중인 서버의 `GET /api-docs` 응답 | `servers` 제거, 키 정렬 |

`schemas/` 디렉터리의 마지막 변경 커밋은 `9e4506ba07b8bcf626e4bf427abf526448cc1997`
(2025-10-21)이다. JSON은 주석을 넣을 수 없어 파일 안에 저작권 헤더를 달지 않았고, 이 README가
출처와 라이선스 표기를 대신한다.

스키마는 JSON Schema draft-07이며 `$ref`는 모두 파일 내부(`#/definitions/...`)만 가리킨다.

## OpenAPI 스냅샷 만들기

springdoc 경로는 upstream `server/src/main/resources/application.properties`의
`springdoc.api-docs.path=/api-docs`에서 확인했다. 같은 파일의 기본값이 SQLite
(`conductor.db.type=sqlite`, `conductor.queue.type=sqlite`, `conductor.indexing.type=sqlite`)라서
Redis·Elasticsearch·Postgres 같은 외부 인프라 없이 띄울 수 있다.

```bash
# conductor-oss 체크아웃(기준 커밋)에서. 빌드 툴체인은 JDK 21.
JAVA_HOME=<jdk-21> ./gradlew :conductor-server:bootJar -x test \
  -Dorg.gradle.java.installations.paths=<jdk-21>

# 빈 디렉터리에서 실행한다. 작업 디렉터리에 SQLite 파일 c123.db가 생긴다.
java -jar server/build/libs/conductor-server-3.30.2-SNAPSHOT-boot.jar --server.port=18080

curl -s localhost:18080/api-docs | jq -S 'del(.servers)' > priv/contract/openapi.json
```

`servers`에는 실행 포트가 들어간 `Generated server url`만 있어 제거했다.

스냅샷에는 기본 설정으로 켜지는 모든 컨트롤러가 들어 있다(경로 141개, 연산 160개). 핵심 REST
모듈(`rest/.../rest/controllers/`)의 92개 경로는 소스 어노테이션에서 뽑은 목록과 일치했고,
`conductor.workflow-message-queue.enabled=false`가 기본값이라 `POST /api/workflow/{workflowId}/messages`
하나만 빠져 있다. 나머지는 scheduler, schema, AI/agentspan 모듈 컨트롤러다. 범위 분류는
[ADR 0001](../../docs/adr/0001-api-contract-scope.md)을 본다.
