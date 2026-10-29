# ADR 0011: Codex 리뷰 게이트를 없애고 push 전 로컬 리뷰 후 auto-merge

- 상태: 승인 (결정 3의 리뷰 순서와 모델·effort는 [ADR 0016](0016-taeguk-review-order-and-model.md)이 대체)
- 날짜: 2026-10-29
- 대체: [ADR 0010](0010-codex-gate-status-only.md) 전체, [ADR 0008](0008-codex-review-gate-hardening.md) 전체,
  [ADR 0006](0006-merge-policy.md) 결정 2의 필수 체크 중 `codex-review`와 결정 5의 "머지 게이트는 필수 체크와 Codex 리뷰".
  ADR 0006의 나머지 결정은 그대로 유효하다.
- 출처: 태극(sensibile/taeguk) #21 `6162cba`의 `taeguk-codex-local-review` 스킬, #22 `3876ffe`의 gate 제거와
  `docs/repository-operations.md` PR 플로우, #28의 archon 전송 권한 기록

## 맥락

ADR 0010 게이트는 GitHub의 Codex 응답에 머지가 묶였다. 판정이 오지 않으면 pending으로 멈췄다(archon PR #9, #12, 태극 PR #3, #6, #17).
2026-10-28 태극은 이 gate를 없앴다. 리뷰는 push 전에 로컬 Codex CLI로 하고, 머지 조건은 CI 검증으로 바꿨다(태극 #22).

2026-10-29 BOSS가 conductor 포팅(archon)과 함께 태극을 강화하기로 했다. 같은 자리의 질문에서 archon gate에 대해
"태극처럼 로컬 리뷰로 전환"을, archon 작업의 Codex 전송에 대해 "archon도 상시 허용"을 골랐다.

## 결정

1. **GitHub Codex 리뷰 gate를 없앤다.** `.github/workflows/codex-review-gate.yml`, `scripts/codex_review_gate.py`,
   `scripts/tests/test_codex_review_gate.py`와 CI의 스크립트 테스트 단계를 지운다.
2. **ruleset 필수 체크는 `test`, `credo`, `dialyzer`, `audit`이다.** strict 최신 base 요구, 리뷰 thread 해소,
   squash만 허용, Credo code scanning 규칙은 유지한다. `codex-review`는 이 PR 머지 전에 ruleset에서 뺀다.
   빼지 않으면 workflow가 사라진 이 PR이 status를 받지 못해 머지되지 않는다.
3. **리뷰는 push 전에 로컬에서 한다.** PR 누적 범위를 태극 `taeguk-codex-local-review` 절차로 리뷰한다.
   설정은 read-only sandbox, `gpt-6-astra`, `medium` effort이다. 교차 리뷰는 항상 하고,
   보안 리뷰는 실행 동작에 영향을 주는 변경에 한다. 전송 권한 근거는 태극 저장소의 승인 기록(Approval-2026-10-29)과
   태극 `docs/architecture.md`의 로컬 Codex 검토 절이다.
4. **auto-merge는 리뷰한 head에 고정한다.** 절차는 AGENTS.md "PR과 머지"에 둔다.
   - 리뷰가 NOT_RUN이나 UNKNOWN이면 켜지 않는다.
   - head를 바꾸기 전에는 끄고, 다시 리뷰한 뒤 켠다.
   - 갱신 전에는 끄고 꺼졌는지 확인한다.
5. **GitHub의 Codex 자동 리뷰는 막지 않는다.** Codex 설정에서 켜져 있어 계속 댓글을 달 수 있다. 머지 조건은 아니다.
   다만 ruleset이 thread 해소를 요구하므로 판정해 반영하거나 이유를 답한 뒤 해소한다.

## 대안

- **ADR 0010 gate 유지:** 응답 지연에 머지가 계속 묶이므로 채택하지 않았다.
- **gate와 로컬 리뷰를 함께 운영:** 같은 변경을 두 번 리뷰하게 되고, 멈춤 문제도 그대로 남아 채택하지 않았다.

## 결과

- 로컬 리뷰 실행 여부는 GitHub가 강제하지 않는다. 세션이 지키는 절차다.
- 이 PR을 머지할 때 archon에 설치된 태극 번들은 `8dbf626`이라 로컬 리뷰 스킬과 역할이 아직 없다.
  이 PR의 리뷰는 태극 저장소의 스킬 절차로 수행했다. 번들 갱신은 별도 PR에서 한다.
- `scripts/tests/`가 비어 CI의 Python 단계가 사라진다. `scripts/contract/`는 영향이 없다.
