---
name: taeguk-plan-cross-verification
description: "Select checks and cross-observations by change attributes; use when preparing or reviewing a verification plan."
---

# taeguk-plan-cross-verification

Identify behavior, state, concurrency, contract, resource, security and delivery attributes actually changed. Select a primary check and a different observation where needed. Explain independence and exclusions. Contract plus stored effect, model plus real parallel execution, or load plus resource evidence are examples. Do not require every tool for every task.

When planning a software change, read the original request and design before implementation. Give the plan an exact version and connect each check to its requirement, approved oracle, expected result source, method (tool, LLM or mixed), owner, artifact/environment, scope, evidence location, gaps and status. Mixed claims that arise from inference need a separate observation or reproduction. Keep checks NOT_RUN until executed. The implementer and reviewers use the same plan version; after a repair, name the affected checks for re-verification. Do not infer acceptance criteria from implementation output or create new global thresholds.

Read [evidence packet](references/evidence-packet.md) when exchanging results or resuming work. Apply within the user's existing scope and authority; this skill does not authorize external effects or criteria changes.

For repairs or shared-resource execution, use [re-verification and handoff](references/reverification.md). Keep fixed criteria while selecting affected checks, documenting evidence reuse and returning resources promptly.

Use [check selection](references/check-selection.md) to choose applicable observation pairs and return an executable plan.

분석·제품 과업에서는 원래 질문에 대한 답, 처리·계산 정확성, 전달과 실제 사용 효과 중 어떤 부분을 각 검사가 확인하는지 나눈다. 목적에 대한 완료 검토는 $taeguk-work-contract의 참고를 사용한다. 같은 원본의 합계 일치로 해석의 타당성이나 사용자 부담 감소까지 확인했다고 보고하지 않는다.

## 설계 단계의 검증 도구 계획

설계자는 설계 인계에 검증 계획 초안을 포함하고 verifier가 구현 전에 검토·확정한다. verification_builder는 필요한 검증 수단의 설계와 제작을 담당한다. 역할은 책임 구분이며 별도 에이전트 호출을 강제하거나 허가하지 않는다.

검사마다 요구·검사 ID, 기대값 출처, 입력·실패/경계 상황, 관측 지점과 판정 조건을 연결한다. 기존 도구로 가능한지 확인하고 `reuse`, `adapt`, `build`, `unavailable`을 구분한다. 부족한 도구는 담당자, 입출력, 환경·권한, 의존 작업, 실행 방법, 증거 위치와 도구 자체 검증 사례를 제작 범위로 기록한다. 필요한 경우에만 fixture·probe·simulator·checker를 만든다. 새 프레임워크나 의존성을 기본 요구로 삼지 않는다.

도구는 출처가 있는 정상 사례와 알려진 실패 또는 의도적으로 깨뜨린 사례, 관련 경계 사례로 점검한다. 제품 위반과 도구/환경 오류를 구분한다. 도구 자체 점검의 통과는 제품 검증 통과가 아니다. 같은 구현에서 복제한 기대값이나 같은 모델의 동의는 독립 증거가 아니다. oracle 미정은 UNKNOWN, 미제작·미실행 검사는 NOT_RUN으로 남긴다.

계획 확정 후 제품 구현과 도구 제작은 의존 관계가 허용하는 범위에서 병행할 수 있다. tool_verifier는 버전과 자체 검증 증거를 인계받아 제품 검사를 실행하고 verifier는 증거의 충분성과 한계를 판단한다. 필수 도구가 없으면 해당 완료 판정을 보류한다. 장애 주입은 승인된 격리 환경에서만 수행한다.
