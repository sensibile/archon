# ADR 0003: 포팅 기준과 단계 순서

- 상태: 승인
- 날짜: 2026-10-25
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`
- 비고: 2026-10-25 프로젝트 시작 논의에서 합의했다. 기록은 결정 이후에 보충했다.

## 맥락

워크스페이스에는 Netflix 원본 `conductor`(아카이브)와 현재 관리되는 `conductor-oss`가 있다.
conductor-oss는 Gradle 모듈이 60개가 넘지만, 대부분은 영속성 백엔드·이벤트 큐·외부 저장소 플러그인이다.
엔진의 핵심은 `core`(Java 192개 파일, 약 3.1만 줄)와 `common`(119개 파일, 약 1.3만 줄)이다.
상태 전이는 `WorkflowExecutorOps.java`(2,985줄)와 `DeciderService.java`(1,059줄)에 몰려 있고,
락·재시도·상태 전이가 한데 얽혀 있다.

## 결정

1. **기준 upstream은 conductor-oss다.** 원본 `conductor`는 참고만 한다.
2. **외부 계약은 유지하고 내부는 다시 설계한다.** REST 경로와 JSON 형태는 upstream과 같게 해서
   기존 워커·SDK·UI가 그대로 붙게 한다. 내부 구조는 Java 클래스를 한 줄씩 옮기지 않고, 의미를 추출해
   OTP 모델로 다시 설계한다.
3. **단계는 계약부터 시작한다.**

   | 단계 | 내용 | 기록 |
   |---|---|---|
   | Phase 0 | 계약 고정: JSON 스키마, OpenAPI 스냅샷, 범위 분류, 골든 픽스처 | [ADR 0001](0001-api-contract-scope.md) |
   | Phase 1 | 도메인 모델: 계약을 통과하는 struct와 JSON 코덱 | [ADR 0002](0002-domain-model-representation.md) |
   | Phase 2 | Decider를 부수효과 없는 순수 함수로 | 미작성 |
   | Phase 3 | OTP 런타임: 워크플로우 인스턴스당 GenServer, 레지스트리, DynamicSupervisor | 미작성 |
   | Phase 4 | 영속성과 큐: PostgreSQL 우선 | 미작성 |
   | Phase 5 | Phoenix REST: MVP 엔드포인트부터 | 미작성 |

4. **MVP 태스크 타입은 SIMPLE, SWITCH, FORK_JOIN, JOIN, DO_WHILE, SUB_WORKFLOW, WAIT로 제한한다.**
   AI, HTTP, JQ, Event 같은 나머지 타입은 그 뒤에 붙인다.
5. **다른 영속성 백엔드는 MVP 이후 플러그인으로 다룬다.** Redis, Elasticsearch, Cassandra 등이 해당한다.

## 대안

- **도메인 모델부터 시작:** 처음 제안된 순서였으나 채택하지 않았다. 계약 없이 모델을 만들면 Java 클래스
  구조를 따라가게 되고, 모델이 맞는지 판단할 기준이 없다. 사용자가 계약을 먼저 잡도록 순서를 정했다.
- **모듈 단위 직역:** `WorkflowExecutorOps`의 락·재시도 구조가 GenServer 모델과 충돌하므로 채택하지 않았다.
- **원본 `conductor` 기준:** 아카이브 상태라 채택하지 않았다.

## 결과

- 각 단계는 앞 단계의 계약 테스트를 통과해야 한다. 골든 픽스처가 단계 사이의 회귀 기준이다.
- Phase 2부터는 단계를 시작할 때 설계 결정을 별도 ADR로 남긴다.
- Phase 2~5는 아직 구현되지 않았다.
