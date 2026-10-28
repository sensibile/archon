# archon 시험 프로젝트 추가 개정안

상태: 2026-10-29 BOSS 확인으로 승인. 현행 본문은 [검증과 측정](../verification.md#req-001)의 REQ-001 1.2와 REQ-007 1.1이며 승인 범위는 [승인 기록](../approvals.md#approval-2026-10-29)을 따른다. 이 문서는 개정 근거로 보존하며 실행 권한을 부여하지 않는다.

작성: 2026-10-29. 근거: 같은 날 BOSS가 "일단 태극을 단단하게 만들어가면서 conductor라는 전환 프로젝트와 함께 태극 강화를 먼저 진행해두려고"라고 했고, conductor를 "archon이라는 elixir 프로젝트로 포팅하는거"라고 밝혔다. archon을 태극 시험 프로젝트로 등록하는 안에 "등록하고 진행"이라고 답했다. 시험 프로젝트 목록은 REQ-001 1.1과 REQ-007 1.0 본문의 적용 대상이므로, 등록은 GOV-002에 따른 규칙 개정이다.

## 현행 규칙과 공백

- REQ-001 1.1: 의도 기록 의무는 시험 프로젝트(hoplites, acropolis, thesmothetai)에서 2026-10-23 이후 새로 시작한 작업에만 적용한다.
- REQ-007 1.0: 요구사항 기록 의무도 같은 세 프로젝트에만 적용한다.
- archon [ADR 0007](https://github.com/sensibile/archon/blob/main/docs/adr/0007-taeguk-adoption.md)(상태 "제안")은 이 정의를 근거로 archon에 REQ-001 1.1과 REQ-007을 적용하지 않는다고 적었다.

태극 강화를 archon과 함께 하려 해도, 현행 규칙으로는 archon에서 의도·요구사항 기록을 관측할 수 없다.

## archon의 성격

archon(`sensibile/archon`)은 Conductor OSS(Java/Spring)를 Elixir/OTP로 포팅한다. 외부 계약(REST·JSON)은 upstream과 같게 유지하고 내부는 OTP 모델로 다시 설계한다. upstream 소스와 `priv/contract/`가 외부 oracle 역할을 하므로, 요구사항이 구현에서 거꾸로 만들어지는지(REQ-007이 막는 것)를 다른 시험 프로젝트보다 분명하게 판정할 수 있다. 2026-10-29 관측 기준으로 태극 `8dbf626`(2026-10-25) 번들을 설치했다.

## 개정안

- REQ-001 1.1 → 1.2: 적용 대상 목록에 archon을 추가한다. 다른 문장은 바꾸지 않는다.
- REQ-007 1.0 → 1.1: 적용 대상 목록과 registry `scope`에 archon을 추가한다. 다른 문장은 바꾸지 않는다.
- 같은 목록을 쓰는 스킬 문서(`taeguk-work-contract`의 SKILL.md, intent-requirement-records.md)를 함께 맞춘다.
- archon의 적용 시작 시점은 승인된 규칙 스냅샷이 archon `main`에 머지된 때다. 그 전에 시작한 archon 작업은 승인 이후에 시작했더라도 소급하지 않는다. 2026-10-23은 기존 세 프로젝트의 시작일로 남긴다.

## 변경 전후 판정

| 사례 | 현행 | 개정 후 |
|---|---|---|
| 스냅샷 머지 뒤 archon에서 새 REST 엔드포인트 묶음 포팅을 시작함(여러 변경에 걸친 작업) | 작업 계약만 작성. 의도·요구사항 기록 의무 없음 | 의도 기록을 남기고, accepted 의도에서 요구사항 기록을 만든다. 요구사항의 기대값은 upstream 계약을 출처로 적는다 |
| archon에서 오타 수정 같은 근거가 분명한 작은 변경 | 작업 계약만 | 작업 계약만(변화 없음) |
| 스냅샷 머지 전에 시작한 archon 작업(승인과 머지 사이에 시작한 것 포함) | 기록 의무 없음 | 소급하지 않음(변화 없음) |
| hoplites, acropolis, thesmothetai의 작업 | 현행 의무 | 변화 없음 |
| Taeguk 자체 작업 | 기록 의무 없음 | 변화 없음 |

## 영향과 비용

- archon 작업에 의도·요구사항 기록 비용이 생긴다. 포팅 요구의 대부분은 upstream 계약이므로, 요구사항 기록이 `priv/contract/`나 ADR과 중복될 수 있다. 이 중복은 관측 대상이다.
- MET-001 절차로 정의한 저장소별 집계 대상에 archon이 들어간다. 임계값은 정하지 않는다.
- 규칙 스냅샷은 다음 설치 갱신 때 archon에 전달한다. 설치는 dry-run 확인과 BOSS 승인을 거친다.
- 실행 권한은 바뀌지 않는다. archon에 대한 로컬 Codex 전송 권한, 번들 업그레이드 적용, archon의 GitHub Codex gate 변경은 이 개정안에 포함하지 않으며 각각 BOSS 확인이 필요하다.

## 전환과 되돌림

- 적용: 승인된 규칙 스냅샷이 archon `main`에 머지된 뒤 새로 시작하는 작업부터 적용한다. 그 전에 시작한 작업에는 소급하지 않는다. archon ADR 0007의 제외 문구는 archon 저장소에서 ADR로 갱신한다.
- 되돌림 신호: 요구사항 기록이 upstream 계약 참조를 반복할 뿐 재작업 감소가 없음, 포팅 속도 대비 기록 비용 과다, ADR과의 충돌 반복. 자동 되돌림 조건은 아니다.
- 되돌릴 때: REQ-001 1.1, REQ-007 1.0의 적용 대상으로 복원하고, archon에 남은 기록은 보존한다.

## BOSS 확인 사항

1. REQ-001 1.2와 REQ-007 1.1로 archon을 적용 대상에 추가한다.
2. archon의 적용 시작 시점을 승인된 규칙 스냅샷이 archon `main`에 머지된 때로 한다.
