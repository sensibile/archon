# Taeguk 현행 규칙

Taeguk 저장소의 `docs/rules`가 규칙의 원본이다. 프로젝트에 설치된 `.taeguk/rules`는 특정 커밋의 사본이며, 그 커밋은 `.taeguk/receipts/rules.json`의 `source_version`으로 확인한다. 사본을 직접 고치지 않고 원본을 바꾼 뒤 다시 설치한다. 규칙 본문은 Markdown, ID·버전·상태·본문 위치·승인 참조는 [registry.toml](registry.toml)에 보관한다. AGENTS.md와 스킬은 적용 진입점과 절차를 제공한다. 문서 지침은 실행 권한을 강제하는 보안 장치가 아니다.

## 적용 범위와 우선순위

현재 규칙은 Taeguk 개발과 이 구성을 사용하는 명시적으로 지정된 작업에 적용한다. 다른 프로젝트에 전역 강제하지 않는다. 사용자 지시와 실행 환경 권한이 우선한다. 프로젝트별 수용 기준·수치 임계값·운영 권한은 해당 작업에서 별도로 정한다.

- [권한과 규칙 변경](governance.md): GOV-001, GOV-002, GOV-004
- [검증과 측정](verification.md): REQ-001, REQ-006, REQ-007, VER-003, VER-004, VER-005, MET-001, DEV-002
- [전달과 실제 효과](delivery.md): REL-005
- [승인 근거](approvals.md)
- [미승인 후보](proposals/index.md)
- [기계 검사와 확장 계획](mechanical-checks.md)

직전 제안의 공통 원칙 8개는 2026-10-11 사용자 요청에 따라 등록했다. 기존 합의 GOV-001·002와 구분해 승인 근거를 남겼다. archive의 모든 후보를 승인한 것은 아니다. 2026-10-16 사용자 요청으로 VER-004와 DEV-002를 1.1로 개정했다. 설계 단계의 검증 도구 제작 계획과 검증된 영역 재사용 관점을 추가했으며 승인 범위는 승인 기록을 따른다. 2026-10-23 BOSS 확인으로 REQ-001을 1.1로 개정하고 REQ-007을 추가했다. 의도·요구사항 기록은 시험 프로젝트에 두며 근거는 [의도·요구사항 기록 개정안](proposals/intent-requirement-records.md)과 승인 기록에 있다. 2026-10-28 BOSS 확인으로 VER-005를 추가했다. 리뷰 반복의 종료·상향 기준이며 근거는 [리뷰 반복 종료·상향 기준 개정안](proposals/review-loop-exit.md)과 승인 기록에 있다. 2026-10-29 BOSS 확인으로 REQ-001을 1.2, REQ-007을 1.1로 개정해 archon을 시험 프로젝트에 추가했다. 근거는 [archon 시험 프로젝트 추가 개정안](proposals/archon-pilot.md)과 승인 기록에 있다.

## 사용

작업 계약에 적용 규칙 ID·버전을 기록한다. 조건에 따라 관련 규칙을 선택하되 필수 수용 기준을 임의 생략하지 않는다. 결과는 실제 실행·관측 증거와 연결한다. 변경안은 Taeguk 저장소의 proposals에 보관하고 BOSS 확인 이후 본문·registry·승인 기록을 함께 갱신한다. Git으로 이전 상태를 보존한다.

Taeguk 저장소에서는 다음 검사를 실행한다.

```sh
python3 scripts/check_rules.py
python3 -m unittest discover -s tests -v
```

설치된 프로젝트에는 이 검사기가 없다. 사본이 설치 시점과 같은지는 Taeguk 저장소의 `scripts/taeguk_install.py project --root <프로젝트> --check`로 확인한다.

기계 검사 통과는 문서 구조의 일치만 뜻한다. 내용의 타당성, 사용자 승인 진실성, 실제 제품 품질은 별도 판단이다.
