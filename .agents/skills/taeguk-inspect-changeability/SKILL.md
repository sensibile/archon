---
name: taeguk-inspect-changeability
description: "Assess a concrete change burden and choose bounded tidying; use for repeated cochanges or blocked testable boundaries."
---

# taeguk-inspect-changeability

Start from an actual change need or repeated cost. Compare maintain, move responsibilities and narrow contract. Choose first, after, later or no tidying. Keep behavior changes separate from structural intent. State minimum scope, preservation evidence and stopping condition. Avoid numeric complexity gates and speculative future options.

Read [evidence packet](references/evidence-packet.md) when exchanging results or resuming work. Apply within the user's existing scope and authority; this skill does not authorize external effects or criteria changes.

## 검증된 영역을 재사용하기 위한 스멜

읽기 어려움보다 새 요구가 이미 검증된 영역까지 다시 수정하게 만드는 실제 변경 부담을 찾는다. 최근 diff·변경 이력 또는 현재의 구체적 요구에서 변하는 판단/정의와 유지할 실행 계약을 구분한다. LLM이 읽거나 수정하기 어렵다는 추정, 줄 수, 가상의 미래 요구만으로 개선을 제안하지 않는다.

먼저 무엇이 변하고 무엇이 유지되는지, 어느 계약을 독립적으로 검증할 수 있는지 찾는다. 다음은 비한정적인 예시이며 분류 목록이나 필수 도입 대상이 아니다. 표에 없는 경계도 실제 변화에 적합하면 제안한다. 패턴 이름보다 책임·입출력·불변 조건을 먼저 설명한다.

| 후보 경계 | 관측할 시그널 | 주로 변할 부분 |
| --- | --- | --- |
| Policy Engine | 동일한 실행에서 허용 조건만 반복 변경되거나 판단이 중복됨 | 정책·결정 테이블 |
| Workflow | 같은 작업의 순서·분기·승인 조합 변경이 내부 실행 코드까지 전파됨 | 흐름 정의 |
| Executor | 여러 흐름에서 타임아웃·취소·재시도·실행 기록을 중복 구현함 | 작업과 실행 옵션 |
| Adapter | 외부 연동 변경이 업무 판단과 흐름까지 전파됨 | 연동 구현 |
| State machine | 상태·전이 변경마다 여러 진입점의 상태 판단을 함께 수정함 | 상태와 전이 정의 |
| Parser / Validator | 입력 형식·제약 변경이 핵심 처리까지 전파됨 | 파싱·검증 규칙 |
| Transformation pipeline | 변환 단계의 추가·교체마다 다른 검증된 변환을 수정함 | 변환 단계와 조합 |
| Storage boundary | 저장 기술·조회 방식 변경이 업무 규칙까지 전파됨 | 저장·조회 구현 |
| Strategy | 계산·선택 방식의 변형마다 공통 처리 절차를 수정함 | 알고리즘 구현 |
| UI component | 화면별 요구 변경이 공통 상호작용 구현을 반복 수정하게 함 | 화면별 구성과 데이터 |

이 표는 엔진 도입 명령이 아니다. 현상 유지, 함수/테이블 분리, 좁은 계약, 기존 도구 재사용을 비교하고 현재 문제를 해결하는 최소 범위를 선택한다. 이름이 같은 기능도 변경 이유나 계약이 다르면 무리하게 통합하지 않는다. 분리의 이득과 계약 유지·조합·이행·검증 비용을 비교한다. 증거가 없으면 관측 후보로만 남긴다.

검토 결과에는 변경 시그널과 근거, 변하는 부분, 보존할 영역과 계약 버전, 기존 검증 증거, 대안·비용, 필요한 계약/조합 검사, 중단 조건을 담는다. 새 조합은 부품 테스트만으로 통과시키지 않는다. 계약·구현·환경 변경 시 영향 검사를 다시 선택하고, 기존 증거 재사용의 근거와 한계를 기록한다. 검증된 영역도 영구 불변이 아니며 결함 수정이나 계약 변화가 있으면 수정할 수 있다.
