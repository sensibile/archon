# ADR 0009: Codex 판정이 오지 않을 때의 시간 기준 규칙

- 상태: 대체됨 ([ADR 0010](0010-codex-gate-status-only.md))
- 날짜: 2026-10-25
- 관련 PR: sensibile/archon#13
- 보완: [ADR 0008](0008-codex-review-gate-hardening.md). 결과 섹션의 "멈춘 리뷰 재요청은 넣지 않았다(제안)"를 이 ADR이 대체한다.
- 출처: 태극(sensibile/taeguk) #13 `f8c7b9b`의 `scripts/codex_review_gate.py`, `tests/test_codex_review_gate.py`,
  `.github/workflows/codex-review-gate.yml`과 `docs/repository-operations.md` PR 플로우 4단계. 운영 보완은 태극 #14(병합 전)의 6단계.

## 맥락

ADR 0008 게이트에는 Codex 리뷰가 멈췄을 때 게이트를 깨울 이벤트가 없다. archon PR #9는 리뷰가 약 50분 `running`에
멈췄다. PR #12에서는 gate가 `github-actions[bot]`으로 단 `@codex review`를 Codex가 무시했고, BOSS가 직접 단 댓글에는
바로 리뷰를 시작했다. 태극 PR #3에서도 같은 일이 있었다. BOSS는 2026-10-25 태극에서 "10분 동안 답없으면 댓글을
추가하고 반복해서 3번 무시당하면 병합"으로 정했고, 태극 #13이 이를 구현했다. BOSS는 archon에도 태극 구현을 받아
적용하라고 지시했다.

## 결정

1. **태극 #13 구현을 그대로 가져온다.**
   - 대상: 현재 head에 Codex 판정이 없는 경우. 리뷰가 시작되지 않았거나(이전 head만 리뷰된 경우 포함),
     `running`에 멈췄거나, `completed`이고 `has_unresolved_findings: null`인데 결과 댓글이 없는 경우다.
     그 head에 Codex 결과 댓글이 하나라도 있거나, 상태를 읽을 수 없으면 대상이 아니다.
   - gate가 그 head에 처음 status를 게시한 시각이나 마지막 요청에서 10분 이상 지나도 판정이 없으면
     `@codex review`를 다시 요청한다. 요청 횟수는 head 표식이 붙은 `github-actions[bot]` 댓글로 세고,
     무효 표시 이후의 요청만 센다.
   - 3번째 요청 뒤에도 10분 이상 판정이 없으면, Codex가 시작한 미해결 리뷰 thread가 0개일 때
     "No Codex verdict after 3 requests; passed by the time rule"로 success를 게시하고 auto-merge로 이어간다.
     미해결 thread가 있으면 failure, thread를 확인할 수 없으면 pending이다. 새 head가 오면 처음부터 다시 센다.
   - workflow가 10분마다 `schedule`로 열린 같은 저장소 PR을 확인한다. 이벤트 gate와 같은 PR별 직렬화 그룹을 쓴다.
   - 같은 status를 다시 게시하지 않는다(최신 gate status와 같으면 건너뜀).
2. **archon 차이는 ADR 0008과 같다.** 머지 호출에만 `AUTO_MERGE_TOKEN`을 쓰고, schedule job에도 같은 env를 준다.
   `actions/checkout@v7`을 쓴다.
3. **운영 보완(태극 #14와 같은 BOSS 결정).** Claude Code 세션이 PR을 맡고 Auto-fix가 켜져 있으면, Auto-fix가 gate의
   요청 댓글을 세션에 전달할 때 세션이 BOSS 계정(`gh` 인증 계정)으로 같은 PR에 `@codex review`를 다시 단다.
   gate 요청 댓글 하나당 한 번만 달고, 그 head의 Codex 결과 댓글이 이미 있거나 리뷰가 `running`이면 달지 않는다.
   gate의 판정과 횟수 계산은 바꾸지 않는다.

## 대안

- **요청을 사용자 토큰(PAT)으로 달기:** Codex가 응답할 가능성이 높지만 시크릿을 추가해야 하고, 표식 작성자 확인을
  바꿔야 한다. BOSS가 태극에서 github-actions 요청 유지를 택했고 archon도 따른다.
- **3회 뒤 요청만 멈추고 pending 유지:** 사람이 개입하기 전까지 머지가 멈춘다. BOSS 결정은 통과다.

## 결과

- bot 요청이 계속 무시되면 이 규칙은 사실상 "판정이 멈추면 약 40분 뒤 리뷰 없이 통과"가 된다. 결정 3의 세션 보완이
  있는 PR에서만 실제 재리뷰를 기대할 수 있다. Auto-fix가 bot 댓글을 세션에 전달하는 것은 관측된 동작이며
  보장된 기능이 아니다.
- GitHub는 schedule을 늦게 실행할 수 있어 간격은 최소 10분이다. 저장소에 60일 동안 활동이 없으면 GitHub가
  schedule workflow를 자동으로 끈다.
- schedule·`issue_comment`·`pull_request_target` workflow는 기본 브랜치 파일로 돌기 때문에 이 ADR을 담은 PR 안에서는
  새 규칙이 실행되지 않는다. 머지 후 다음 PR에서 확인한다.
