# ADR 0007: 태극 개발 구성 채택

- 상태: 승인 (결정 4의 시험 프로젝트 제외는 [ADR 0012](0012-taeguk-pilot-and-bundle-update.md)가, 결정 2의 같은 문구와
  결정 4의 명시 작업 한정 중 DEV-003 적용 범위는 [ADR 0017](0017-taeguk-dev003-worktree.md)이 대체)
- 날짜: 2026-10-25
- 태극 원본: sensibile/taeguk `8dbf62681faf14771c86b86dddc2d1b5f0378d33`

## 맥락

sensibile 저장소 중 hoplites와 thesmothetai는 태극(sensibile/taeguk) 프로젝트 번들을 설치하고, AGENTS.md에서
태극 규칙을 읽도록 한다. 태극은 작업 계약, 교차 검증, 효과 확인, 회고를 연결하는 에이전트 개발 구성이다.
사용자는 archon에도 태극을 설치하고 그 작업 지침을 따르라고 지시했다(2026-10-25).

## 결정

1. **태극 프로젝트 번들을 Claude Code와 Codex용으로 설치하고 저장소에 커밋한다.** hoplites·thesmothetai와 같은 구성이다.

   | 구성요소 | 위치 | 파일 수 |
   |---|---|---|
   | rules | `.taeguk/rules/` (태극 `docs/rules` 스냅샷) | 9 |
   | claude | `.claude/agents/taeguk-*.md`, `.claude/skills/taeguk-*/` | 38 |
   | codex | `.codex/agents/taeguk_*.toml`, `.agents/skills/taeguk-*/` | 49 |

   설치 영수증은 `.taeguk/receipts/`에 있고, 설치 버전은 위 태극 원본 커밋이다.
2. **AGENTS.md에 태극 규칙을 읽도록 하는 한 줄을 넣는다.** 문구는 다른 저장소와 같다. 기존 지침은 덮어쓰지 않는다.
3. **설치된 사본은 직접 고치지 않는다.** 규칙을 바꾸려면 태극 저장소의 원본을 고친 뒤 다시 설치한다.
4. **적용 범위는 태극 규칙의 정의를 따른다.** 규칙은 명시적으로 지정된 작업에 적용하고, 사용자 지시와 실행 환경
   권한이 우선한다. archon은 태극 규칙이 정한 시험 프로젝트(hoplites, acropolis, thesmothetai)가 아니므로,
   REQ-001 1.1의 의도 기록과 REQ-007 요구사항 기록 의무는 적용하지 않는다. REQ-001 1.0의 작업 계약,
   VER-003의 결과 상태 구분, VER-004의 교차 검증 선택, DEV-002의 한 의도 단위 변경은 적용한다.
5. **archon 자체의 결정 기록은 이 저장소의 ADR로 남긴다.** 태극 REQ-007도 설계 결정은 ADR을 참조하도록 정한다.

## 대안

- **Claude Code용만 설치:** archon은 Codex를 PR 리뷰 게이트로 쓰고([ADR 0006](0006-merge-policy.md)) 다른 저장소도
  두 에이전트를 모두 설치하므로 채택하지 않았다.
- **사용자 레벨 전역 설치:** 2026-10-23 태극 결정으로 사용자 레벨에는 `taeguk-init`과 CLI만 두고 나머지는
  프로젝트에 설치한다.

## 결과

- 설치 확인은 태극 저장소의 `scripts/taeguk_install.py project --root <archon> --check`로 한다. 설치 직후 rules·claude·codex
  모두 `verified`였다.
- 태극을 갱신하면 같은 명령의 `--apply`로 다시 설치하고, 영수증 버전을 이 ADR 또는 후속 ADR에 기록한다.
- 설치 성공은 파일 배치와 hash 일치만 뜻한다. 새 세션에서 역할·스킬이 실제로 발견되는지는 아직 확인하지 않았다.
- archon을 태극 시험 프로젝트에 넣을지는 태극 규칙 변경(GOV-002)이라 이 ADR에서 정하지 않는다.
