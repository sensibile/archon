# ADR 0004: 라이선스와 upstream 출처 표기

- 상태: 승인
- 날짜: 2026-10-25
- 비고: 2026-10-25 저장소 생성 때 합의했다. 기록은 결정 이후에 보충했다.

## 맥락

Archon은 Apache License 2.0인 conductor-oss의 코드와 구조에서 출발한다. Java 코드를 Elixir로 옮긴 것도
언어만 바꾼 번역이라 2차 저작물이다. conductor-oss에는 `NOTICE` 파일이 없고, 소스 헤더는
`Copyright $YEAR Conductor Authors.`(`licenseheader.txt`)다.

## 결정

1. **라이선스는 Apache 2.0을 그대로 쓴다.** `LICENSE`는 upstream 원문을 복사한다.
2. **`NOTICE`를 둔다.** upstream에는 없지만, Conductor OSS에서 파생했다는 사실과 원 개발처(Netflix)를
   적는다. 법적 의무라기보다 출처를 확인하기 쉽게 하려는 것이다.
3. **upstream에서 파생한 파일의 헤더에는 두 저작권을 모두 적는다.** 원래 있던 `Copyright Conductor Authors`는
   지우지 않고 `Copyright 2026 sensibile`를 추가하며, 원본을 수정했다는 표시를 붙인다(Apache 2.0 §4(b)).
4. **원본에서 파생한 부분이 남아 있는 동안은 표기를 유지한다.** 사용자는 표기가 남는 것을 문제로 보지 않으며,
   upstream에서 출발하는 방식을 택했다.
5. **이름은 Archon으로 한다.** "Conductor"는 Apache 2.0이 상표권을 허락하지 않으므로(§6) 제품명으로 쓰지 않는다.
   README에서는 호환성을 설명하는 용도("Conductor-compatible")로만 쓰고, Conductor 프로젝트나 Netflix와
   무관하다고 밝힌다.
6. **PR에는 참조한 upstream 소스와 커밋 SHA를 적는다.** PR 템플릿의 "upstream 대응" 섹션이 이 기록을 받는다.

## 대안

- **처음부터 새로 쓰는 방식:** 원본 표기 의무는 줄지만, 직역과 새 작성의 경계가 애매하고 시간이 많이 든다.
  사용자가 upstream에서 출발하기로 정했다.
- **"Conductor"가 들어간 이름(예: `conductor-ex`):** 상표 문제를 피하기 위해 채택하지 않았다.

## 결과

- 처음부터 새로 설계한 모듈(예: OTP 런타임)에는 upstream 헤더를 붙이지 않는다.
  어느 파일이 파생인지는 PR의 upstream 대응 섹션으로 추적한다.
- 공개 배포나 상업적 사용 전에는 법률 검토가 필요하다. 이 ADR은 법률 자문이 아니다.
