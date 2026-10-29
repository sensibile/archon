# ADR 0015: 스크립트 평가기를 격리된 QuickJS-ng 프로세스로 실행

- 상태: 제안
- 날짜: 2026-10-29
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`

## 맥락

[ADR 0014](0014-phase2-decider.md) 결정 6은 SWITCH의 `javascript`·`graaljs`·`python` 평가기, DECISION의
`caseExpression`, DO_WHILE의 `loopCondition`을 "JS 엔진을 어떻게 들일지 정하는 별도 ADR"로 미뤘다. 결정 7은
정의 등록 때 하는 스크립트 문법 검사도 이 ADR로 넘겼다. 이 결정이 없으면 Phase 2의 마지막 조각 2e(DO_WHILE)를
시작할 수 없다.

upstream은 `core/.../events/ScriptEvaluator.java`에서 GraalVM Polyglot 25.0.2(GraalJS·GraalPy)를 서버 JVM에
넣어 쓴다.

- 프로세스 전체가 `Engine` 하나를 공유하고, 스크립트 원문을 키로 `Source`를 캐시한다(기본 1,024개).
  `Context`는 호출마다 새로 만든다. 컨텍스트 풀은 옵션이고 기본은 꺼져 있다.
- 입력은 deep copy해서 JS 전역 `$`로 넘기고, 별도 스레드풀에서 실행한다. 기본 4초가 지나면
  `Script not evaluated within N seconds, interrupted.`로 실패한다. 설정은 환경 변수
  `CONDUCTOR_SCRIPT_MAX_EXECUTION_SECONDS` 등으로 한다.
- 결과는 `getObject`가 변환한다. 숫자는 `int`→`long`→`double` 중 들어맞는 것, 배열은 `List`, 객체는 `Map`이다.
  `evalBool`은 `Boolean`은 그대로, 숫자는 `> 0`이면 참, 그 밖은 거짓이다.
- 스크립트 오류는 ``Error evaluating the script `<메시지>` at line N``(위치가 없으면 줄 번호 없이)인
  `TerminateWorkflowException`이다.
- JS `Context`는 IO·환경 변수·프로세스·스레드·네이티브 접근·호스트 클래스 로딩을 막는다. 다만 호스트 접근은
  `HostAccess.ALL`에서 `Class`·`Runtime`·`System`·`Thread`·리플렉션 등을 빼는 블랙리스트이고, 메모리 제한은
  없으며, 스크립트가 서버와 같은 프로세스에서 돈다.
- `PythonEvaluator`는 `ScriptEvaluator`를 거치지 않는다. 기본 설정의 Python `Context`를 쓰고 실행 시간
  제한이 없다.

호출하는 곳과 실패할 때의 동작은 다음과 같다.

| 곳 | 호출 | 평가 실패 시 |
|---|---|---|
| SWITCH `javascript`·`graaljs` | `ScriptEvaluator.eval` | SWITCH 태스크가 `FAILED`, 이유는 예외 메시지 |
| DECISION `caseExpression` | `ScriptEvaluator.eval` | `Error while evaluating script: <expression>`로 워크플로우 종료 |
| DO_WHILE `loopCondition` | `ScriptEvaluator.evalBool` | 2e에서 upstream `DoWhile`을 따른다 |
| INLINE·LAMBDA 태스크, 이벤트 핸들러 조건 | `eval`·`evalBool` | 아직 Archon 범위 밖(ADR 0001) |
| 정의 등록 검사 | `validateScriptSyntax`(실행 없이 파싱) | `Expression is not well formatted: <메시지>` |

Archon은 JVM이 아니므로 GraalVM을 같은 프로세스에 넣을 이유가 없다. ADR 0003에 따라 바깥에서 보이는 결과는
upstream과 같게 하고, 실행 방식은 BEAM에 맞게 다시 설계한다. 스크립트는 워크플로우 정의를 등록한 사람이 서버에서
실행하는 코드이므로 격리 강도를 가장 큰 기준으로 삼는다.

## 결정

### 1. 스크립트는 BEAM 밖의 OS 프로세스에서 QuickJS-ng로 실행한다

- 엔진은 [QuickJS-ng](https://github.com/quickjs-ng/quickjs)(MIT)다. 작은 C 라이브러리이고, 메모리 상한
  (`JS_SetMemoryLimit`)·스택 상한·인터럽트 핸들러를 엔진이 직접 제공한다.
- `qjs` CLI는 쓰지 않는다. CLI는 모듈 로더와 `qjs:std`·`qjs:os`(파일·프로세스·환경 변수)를 등록하므로, 사용자
  스크립트가 동적 `import()`로 그 기능에 닿을 수 있다.
- 대신 QuickJS-ng 라이브러리를 링크한 Archon 전용 호스트 `archon_js`(C, `c_src/archon_js/`)를 둔다.
  - 모듈 로더를 등록하지 않는다. `import`·`import()`는 실패한다.
  - `std`·`os`를 비롯한 호스트 함수를 하나도 등록하지 않는다. 스크립트가 쓸 수 있는 것은 ECMAScript 내장
    객체와 `$`뿐이다.
  - 요청마다 새 `JSContext`(realm)를 만든다. 앞선 평가가 바꾼 전역 상태를 다음 평가가 보지 않는다.
  - 메모리 상한, 스택 상한, 인터럽트 핸들러에 의한 시간 상한을 건다.
  - 표준 입출력은 C 코드만 읽고 쓴다. 스크립트는 입출력에 닿을 수 없다.
- OS 수준 샌드박스(Linux seccomp·landlock, macOS `sandbox-exec`)는 2차 방어로 Phase 5 운영 하드닝에서 검토한다.

### 2. OTP 워커 풀이 프로세스를 관리한다

- `Archon.Script.Pool`이 supervisor 아래에 워커 N개를 두고, 워커마다 `archon_js` Port 하나를 연다.
  메시지는 `{:packet, 4}` 길이 접두 JSON이다.
  - 요청: `{"op": "eval" | "parse", "script": ..., "input": ...}`
  - 응답: `{"ok": value}` 또는 `{"error": kind, "message": ..., "line": ...}`
- 시간 상한은 두 겹이다. 엔진 안의 인터럽트 핸들러가 먼저 멈추고, 워커가 그보다 조금 긴 시간을 기다려도 응답이
  없으면 Port를 닫고 OS 프로세스를 kill한 뒤 새로 띄운다. 프로세스가 죽어도 같은 경로로 복구되며, BEAM은
  영향을 받지 않는다.
- 기본값은 시간 4초(upstream과 같음), 메모리 64MiB, 워커 수는 스케줄러 수다. 애플리케이션 설정으로 바꿀 수
  있다. upstream의 `Source` 캐시와 컨텍스트 풀은 두지 않는다. 표현식 컴파일 비용이 작고, 요청마다 새 realm을
  쓰는 것이 격리 조건이다.

### 3. Decider는 평가 함수를 주입받는다

- ADR 0014 결정 2의 `Context`에 `evaluate_script :: (op, script, input -> {:ok, json} | {:error, ScriptError.t()})`를
  더한다. `new_id`·`jitter`처럼 Decider가 받는 비결정적 입력이다. 기본값은 풀을 부르는 함수이고, 테스트는 실제
  풀이나 고정 함수를 넣는다.
- Decider와 매퍼는 프로세스를 직접 다루지 않는다. "부수효과 없음"의 의미(ADR 0014 결정 2)는 유지한다. 스크립트
  실행은 바깥 OS 프로세스에서 일어나지만 Decider의 결과는 주입한 함수의 결과에만 달려 있다.

### 4. upstream과 같게 지키는 것

- 입력은 JS 전역 `$`로 넘긴다. 평가 결과는 마지막 식의 값이다(upstream `context.eval(source)`).
- 결과 변환은 upstream `getObject`를 따른다. JS 숫자가 정수이고 `long` 범위면 정수, 아니면 실수다.
  `undefined`·`null`은 `null`, 배열은 목록, 그 밖의 객체는 맵이다.
- JSON이 표현하지 못하는 `NaN`·`Infinity`·`-Infinity`는 upstream에서 Java `Double`로 남아 결과에 영향을 준다
  (SWITCH는 `String.valueOf`로 `"NaN"`·`"Infinity"` 분기를 고르고, `evalBool`은 `Infinity`를 참으로 본다).
  그래서 `archon_js`는 이 값을 태그 `{"$archon_number": "NaN" | "Infinity" | "-Infinity"}`로 보내고, Elixir 쪽은
  평가 결과 안에서 `:nan`·`:infinity`·`:neg_infinity`로 받는다. 호출 지점은 이를 upstream처럼 쓴다. 문자열로는
  Java `Double#toString`(`"NaN"`, `"Infinity"`, `"-Infinity"`)이 되고, `evalBool`에서는 `Infinity`만 참이다.
  결과 맵이 태스크 출력으로 저장될 때는 upstream `ObjectMapper`가 이 값을 쓰는 방식을 구현 PR에서 확인해 따른다.
  이 경계 사례는 결정 7의 오라클 비교에 넣는다.
- `evalBool`은 upstream `toBoolean`을 따른다.
- 문구: 시간 초과 `Script not evaluated within <N> seconds, interrupted.`, 스크립트 오류
  ``Error evaluating the script `<메시지>` at line <N>``, 등록 검사 `Expression is not well formatted: <메시지>`,
  그리고 위 표의 호출 지점별 처리(SWITCH 태스크 실패, DECISION 종료).
- 평가기 타입 `javascript`와 `graaljs`는 같은 엔진을 쓴다(upstream도 둘 다 `ScriptEvaluator.eval`).

### 5. Python 평가기는 보류한다

`python`은 지금처럼 `No evaluator registered for type: python`으로 처리한다. upstream 구현은 시간 제한과
명시적 격리가 없고, GraalPy의 동작을 다른 엔진으로 맞추기 어렵다. 실제로 필요해지면 별도 ADR로 다룬다.

### 6. QuickJS-ng 소스는 고정 버전으로 vendoring한다

- 릴리스 태그의 소스를 `c_src/quickjs-ng/`에 넣는다. 버전·원본 URL·SHA256은 구현 PR에서 이 ADR의 "결과"와
  `c_src/quickjs-ng/VERSION`에 적는다. 빌드에는 네트워크가 필요 없고, 리뷰·감사 대상이 저장소 안에 있다.
- 빌드는 `elixir_make`(새 의존성)로 `mix compile` 때 `priv/archon_js`를 만든다. CI 러너에는 C 컴파일러만 있으면 된다.
- vendoring한 파일은 고치지 않는다. 버전을 올릴 때는 같은 방식으로 통째로 바꾸는 PR을 올린다. MIT 고지는
  `c_src/quickjs-ng/LICENSE`를 그대로 두고, 루트 `NOTICE`에 적는다.

### 7. 정답 기준

- 로컬 Gradle 캐시의 GraalJS 25.0.2 jar를 Java 프로브로 돌려 같은 스크립트·입력의 결과와 문구를 비교한다.
  날짜 해석(ADR 0014, 2d)에서 commons-lang3를 쓴 방식과 같다.
- upstream 테스트에서 옮긴다: `ScriptEvaluator`·평가기 테스트, `SwitchTaskMapperTest`의 JavaScript 사례,
  `DecisionTaskMapperTest#getEvaluatedCaseValueUsingExpression`, `WorkflowTaskTypeConstraintTest`의 스크립트 사례.
  `TestDoWhile`은 2e에서 옮긴다.
- 비유한 숫자(`1/0`, `0/0`, `-1/0`)의 SWITCH 분기·`evalBool`·출력 저장 결과를 오라클과 비교한다.
- 격리는 따로 테스트한다. `import()`, 무한 루프, 메모리 폭주, 앞선 평가가 남긴 전역 상태, 프로세스 kill 후
  복구를 시험한다.

## upstream과 의도적으로 다른 점

- `$`는 JS 일반 객체다. upstream은 Java `Map`을 호스트 객체로 넘기므로 `$.get('x')` 같은 Java 메서드 호출이
  되지만 Archon에서는 되지 않는다. 그 밖에 `Object.keys($)`·`JSON.stringify($)`처럼 호스트 객체와 일반 객체가
  다르게 동작하는 경우가 있다. GraalJS 오라클로 확인한 차이를 구현 PR에서 이 절에 더한다.
- 스크립트 오류 메시지 본문(`<메시지>` 부분)은 엔진마다 다르다. 감싸는 형식만 upstream과 같다.
- 지원하는 ECMAScript 판과 내장 객체 세부(날짜 문자열 해석, 정규식 확장, 숫자 출력)는 QuickJS-ng를 따른다.
- 메모리 상한이 있다. upstream은 메모리 제한이 없다.
- Python 평가기가 없다(결정 5).
- INLINE·LAMBDA·이벤트 핸들러 조건은 해당 기능을 들일 때 이 평가기를 쓴다. 이 ADR은 Decider가 쓰는 곳만 구현한다.

## 대안

- **GraalJS를 사이드카 JVM으로 띄우기:** upstream과 결과가 가장 가깝지만, 서버마다 JVM을 함께 운영해야 하고
  격리 문제(블랙리스트 호스트 접근)를 그대로 가져온다.
- **QuickJS를 NIF로 직접 바인딩:** 빠르지만 엔진 결함이나 메모리 오류가 BEAM 전체를 죽인다. 격리 목적과 맞지 않는다.
- **QuickJS를 Wasm으로 빌드해 Wasmtime NIF로 실행:** 바이너리 배포가 없고 연료(fuel)로 결정적으로 멈출 수
  있다. 하지만 같은 C 호스트 코드가 필요하고, Rust NIF 의존성과 wasi-sdk 빌드가 추가된다. 격리 경계가 OS
  프로세스보다 설명하기 어렵다.
- **Deno·Node 워커:** V8이라 호환성이 높고 Deno는 권한 샌드박스가 있지만, 런타임이 무겁고 서버마다 설치해야 한다.
- **stock `qjs` CLI:** 결정 1에 적은 이유로 격리가 되지 않는다.
- **QuickJS-ng 소스를 git submodule이나 빌드 시 다운로드로 들이기:** 저장소는 가볍지만, clone·CI 단계가 늘거나
  빌드마다 네트워크와 공급망 경로가 하나 더 생긴다(2026-10-29 BOSS가 vendoring 선택).

## 결과

- 아직 구현하지 않았다. 구현 PR은 결정 1~4·6·7과 SWITCH `javascript`·`graaljs`, DECISION `caseExpression`,
  등록 시 문법 검사를 연결하고, ADR 0014 결정 6·7의 해당 문장에 이 ADR 링크를 단다. DO_WHILE은 그 뒤 ADR 0014의 2e에서 이 평가기를 쓴다.
- C 코드(`archon_js`)가 저장소에 생긴다. `mix credo`·`dialyzer`가 보지 않으므로 구현 PR에서 C 쪽 검사
  (컴파일 경고를 오류로, 가능하면 AddressSanitizer 빌드 테스트)를 CI에 더한다.
- 서버를 배포할 때는 `priv/archon_js`가 대상 OS·CPU용으로 빌드되어야 한다. 릴리스 빌드 절차는 Phase 5에서 정한다.
