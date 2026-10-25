# Architecture Decision Records

Archon의 합의된 기술·운영 결정을 누적합니다. 파일 이름은 `NNNN-short-title.md` 형식이고, 각 문서는
상태, 날짜, 맥락, 결정, 대안, 결과를 기록합니다. upstream 코드에 근거한 결정은 기준 upstream 커밋 SHA를 적습니다.

## 규칙

- 다음에 해당하면 ADR을 씁니다: 단계의 설계 선택, 외부 계약(REST·JSON) 범위, 의존성·도구 채택,
  저장소 운영 정책(CI, ruleset, 머지), upstream과 의도적으로 다르게 가는 동작.
- ADR은 그 결정을 구현하는 PR에 함께 넣습니다. 결정만 먼저 합의한 경우에는 ADR만 담은 PR을 먼저 올립니다.
- 상태는 `제안` → `승인` → `대체됨`(대체 ADR 링크) 순서입니다. 구현 PR이 머지되면 `승인`으로 바꿉니다.
- 과거 결정을 고쳐 쓰지 않습니다. 결정이 바뀌면 새 ADR을 추가하고, 이전 문서에 대체 문서를 연결합니다.
- 결정 이후에 보충한 기록은 비고에 그 사실을 적습니다.
- ADR은 구현 완료의 증거가 아닙니다. 아직 구현하지 않은 부분은 결과 섹션에 적습니다.

## 목록

| 번호 | 제목 | 상태 |
|---|---|---|
| [0001](0001-api-contract-scope.md) | API 계약 범위 | 승인 |
| [0002](0002-domain-model-representation.md) | 도메인 모델 표현과 JSON 코덱 | 승인 |
| [0003](0003-porting-strategy.md) | 포팅 기준과 단계 순서 | 승인 |
| [0004](0004-license-and-attribution.md) | 라이선스와 upstream 출처 표기 | 승인 |
| [0005](0005-static-analysis.md) | CodeQL 대신 쓰는 정적 분석 | 승인 |
| [0006](0006-merge-policy.md) | 머지 정책과 Codex 리뷰 게이트 | 승인 |
| [0007](0007-taeguk-adoption.md) | 태극 개발 구성 채택 | 제안 |
