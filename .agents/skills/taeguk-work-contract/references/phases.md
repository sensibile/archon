# 작업 단계

작업은 Phase 0~4로 진행한다. 2026-10-28 BOSS가 Phase 0~3 흐름을 제안했고, Phase 3 뒤 재검증, 반복 종료·상향 조건, Phase 4를 보완한 안을 확인했다. 단계 판단은 `taeguk_coordinator`가 맡는다. 표의 역할은 해당 작업에서 필요한 것만 선택하며, 역할 정의가 위임을 허용하지는 않는다.

| 단계 | 내용 | 역할 | 끝나는 조건 |
|---|---|---|---|
| Phase 0 아이디어 | 목적 가설과 의도·요구사항 기록(REQ-001, REQ-007) | `taeguk_coordinator` | 요구사항 의미를 BOSS가 확정 |
| Phase 1 계획 강화 (반복) | 설계와 검증 방안 확보, 부족한 검증 도구의 제작 범위(VER-004) | `taeguk_designer`, `taeguk_verification_builder`, `taeguk_verifier` | verifier가 모든 요구사항을 oracle·검사에 연결한 계획 버전을 확정 |
| Phase 1.5 구현 | 확정한 계획 버전에 맞춘 구현과 필요한 검증 도구 제작 | `taeguk_implementer`, `taeguk_verification_builder` | 정확한 산출물 버전을 검증·리뷰 역할에 인계 |
| Phase 2 검증·다각화 리뷰·수정 (반복) | 도구 검사, LLM 리뷰, 로컬 Codex 교차·보안 리뷰, 지적 수정과 영향 검사 재검증 | `taeguk_tool_verifier`, `taeguk_llm_reviewer`, `taeguk_codex_cross_reviewer`, `taeguk_codex_security_reviewer`, `taeguk_implementer` | 필수 검사 PASS, P0·P1 지적 0건, P2 이하는 반영하거나 반영하지 않은 이유를 기록 |
| Phase 3 변경 범위 정리 (반복) | 이번 변경이 만든 임시 코드, 디버그 출력, 이번 변경으로 쓰이지 않게 된 코드와 중복만 정리. 범위 밖 정리와 구조 개선 거리는 후보로 기록(DEV-002) | `taeguk_implementer` | 변경이 생기면 Phase 2로 돌아가 영향받는 검사를 재검증한 뒤 종료 |
| Phase 4 전달·효과 관측 | 머지·설치 등 전달 뒤 실제 사용자 효과를 목적 가설과 비교(REL-005), 규칙 개정 거리는 제안으로 분리 | `taeguk_outcome_observer`, `taeguk_rule_reviewer` | 관측 결과와 미확인 효과를 기록하고, 새 작업은 Phase 0에서 시작 |

## 반복과 되돌아가기

반복 단계에는 종료 조건과 함께 상향 조건을 둔다. 같은 지적이 두 번 되풀이되거나 수정이 다른 지적을 계속 낳으면 반복을 멈추고 BOSS에게 상황과 선택지를 보고한다. Phase 2의 종료 조건(P0·P1 0건, P2 이하는 반영 또는 이유 기록)과 이 상향 조건은 2026-10-28 BOSS가 공통 기준으로 확정했다. 작업 계약의 승인된 수용 기준이 더 엄격하면 그 기준을 따른다. 이 기준을 바꾸려면 BOSS 확인이 필요하다. Phase 3의 정리는 Phase 2 증거를 이전 버전의 것으로 만들므로(REQ-006), 재검증 없이 전달하지 않는다. Phase 1 이후 요구사항 의미가 바뀌면 Phase 0으로 돌아가 BOSS 확인을 다시 받는다.

Phase 2의 종료 조건과 상향 조건은 2026-10-28 승인된 VER-005 1.0이다. 작업 계약에는 이 reference가 아니라 규칙 ID와 버전을 기준 출처로 적는다. 본문이 다르면 `.taeguk/rules`(Taeguk 저장소에서는 `docs/rules`)의 VER-005가 우선한다.

## 주기 작업

작업 하나의 Phase 3은 그 변경 범위만 본다. 여러 작업에 걸쳐 쌓이는 정리 거리와 구조 문제는 작업 밖의 주기 작업으로 다룬다. 2026-10-29 BOSS가 "정리와 구조개선을 나눠서 진행하자. 정리는 데일리로 하는게 맞을 거 같고, 구조개선은 시그널이 나타날 때가 맞을 거 같아"라고 정했다.

| 작업 | 시작 | 실행 권한 | 절차 |
|---|---|---|---|
| 데일리 정리 | 로컬 예약 작업이 매일 시작 | Codex가 필요하다고 동의한 항목만 PR 플로우로 머지까지 자율 진행 | `$taeguk-daily-cleanup` |
| 구조 개선 | 구조 개선 시그널 관측 | BOSS에게 보고하고 승인을 받은 뒤 Phase 0부터 진행 | `$taeguk-inspect-changeability`, `taeguk_structure_reviewer` |

정리는 동작, 계약, 책임 경계를 바꾸지 않는 변경이다. 이를 바꾸면 구조 개선으로 분류한다. 구조 개선 시그널의 측정 방법은 아직 정하지 않았다. 연구 과제는 [구조 개선 시그널 연구](https://github.com/sensibile/taeguk/blob/main/docs/research/structure-signal.md)에 있다. 확정 전에는 작업 리뷰, 데일리 정리, 일반 작업에서 DEV-002의 실제 동반 수정 근거가 관측될 때 시그널로 보고한다. 주기 작업도 각자의 작업 계약과 Phase 2 종료·상향 조건(VER-005)을 따른다.
