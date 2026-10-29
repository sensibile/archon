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
- 입력은 JS 전역 `$`로 넘기고 별도 스레드풀에서 실행한다. deep copy는 SWITCH 평가기
  (`JavascriptEvaluator`·`GraalJSEvaluator`)만 한다. DECISION은 태스크 입력 맵을, DO_WHILE은 실제 태스크 출력
  맵을 담은 입력을 그대로 넘기므로, 스크립트가 Java `Map` 메서드로 그 맵을 고치면 원래 데이터도 바뀐다. 기본 4초가 지나면
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
  - 응답: `{"ok": <타입 붙은 값>}` 또는 `{"error": kind, "message": ..., "line": ...}`
  - 요청의 `input`은 일반 JSON이다. 워크플로우 상태에는 비유한 숫자가 들어가지 않으므로(결정 4) 입력에도 없다.
  - 응답의 값은 모든 노드에 타입을 붙인 2원소 배열이다. `["null"]`, `["bool", true]`, `["int", "<10진수>"]`,
    `["float", <JSON 숫자>]`, `["nonfinite", "NaN" | "Infinity" | "-Infinity"]`, `["str", "..."]`,
    `["list", [값...]]`, `["map", [[키 값, 값]...]]`. 사용자 객체가 어떤 모양이든 태그와 겹치지 않고,
    정수는 문자열이라 `long` 범위 값이 JSON 실수로 뭉개지지 않는다.
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
- Decider와 매퍼는 프로세스를 직접 다루지 않는다.
- 기본 `evaluate_script`는 풀에 프로세스 메시지를 보내고 Port 응답을 기다린다. 이는 ADR 0014 결정 2의 "부수효과
  없음"(I/O·영속성·큐·프로세스 메시지 없음) 정의에 어긋나므로, 그 정의에 예외를 하나 둔다. 주입받은
  `evaluate_script` 호출은 허용한다. 이 호출은 영속 상태를 바꾸지 않는 계산 요청이고, 결과는 스크립트·입력·
  시간 상한으로만 정해진다. ADR 0014 결정 2에 이 예외를 연결한다.
- 평가를 Decider 밖으로 빼는 방식(평가가 필요하면 Decider가 멈추고 런타임이 평가한 뒤 다시 부르기)은 쓰지 않는다.
  SWITCH 안의 SWITCH처럼 매퍼가 이어서 예약하는 경로(ADR 0014 결정 5) 중간에서 평가가 일어나기 때문에, 그 방식은
  Decider를 재개 가능한 상태 기계로 바꿔야 한다.

### 4. upstream과 같게 지키는 것

- 입력은 JS 전역 `$`로 넘긴다. 평가 결과는 마지막 식의 값이다(upstream `context.eval(source)`).
- 결과 변환은 upstream `getObject`를 따른다. JS 숫자가 정수이고 `long` 범위면 정수, 아니면 실수다. 다만 `-0`은
  GraalJS에서 `fitsInInt`·`fitsInLong`이 거짓이므로 실수 `-0.0`이다(`["float", -0.0]`, 분기 키 `"-0.0"`).
  `undefined`·`null`은 `null`, 배열은 목록, 그 밖의 객체는 맵이다.
- 숫자·문자열 변환의 세부 경계는 이 ADR에 하나씩 적지 않는다. 구현 PR에서 GraalJS 25.0.2 오라클(결정 7)과 같은
  결과를 내는 것을 기준으로 삼고, 오라클과 다르게 두기로 한 사례만 아래 "upstream과 의도적으로 다른 점"에 더한다.
- JSON이 표현하지 못하는 `NaN`·`Infinity`·`-Infinity`는 upstream에서 Java `Double`로 남아 결과에 영향을 준다
  (SWITCH는 `String.valueOf`로 `"NaN"`·`"Infinity"` 분기를 고르고, `evalBool`은 `Infinity`를 참으로 본다).
  그래서 `archon_js`는 이 값을 결정 2의 `["nonfinite", ...]`로 보내고, Elixir 쪽은 평가 결과 안에서
  `:nan`·`:infinity`·`:neg_infinity`로 받는다. 같은 모양의 사용자 객체는 `["map", ...]`이므로 섞이지 않는다.
  호출 지점은 이를 upstream처럼 쓴다. 문자열로는
  Java `Double#toString`(`"NaN"`, `"Infinity"`, `"-Infinity"`)이 되고, `evalBool`에서는 `Infinity`만 참이다.
  결과 맵이 태스크 출력에 들어갈 때는 그 자리에서 upstream이 저장할 때 쓰는 형태로 바꾼다. Jackson 설정에 따라
  문자열 `"NaN"` 등이 될 것으로 보이며, 구현 PR에서 upstream `ObjectMapperProvider`의 실제 출력으로 확인한다.
  따라서 워크플로우 상태(태스크 출력, 이후 `${...}`로 참조되는 값)에는 비유한 숫자가 남지 않고, 다음 평가의
  입력도 일반 JSON으로 충분하다. 이 경계 사례는 결정 7의 오라클 비교에 넣는다.
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
- 비유한 숫자(`1/0`, `0/0`, `-1/0`)의 SWITCH 분기·`evalBool`·출력 저장 결과를 오라클과 비교한다. 태그와
  같은 모양의 사용자 객체(예: `({selectedCase: ["nonfinite", "NaN"]})`, `{"$archon_number": "Infinity"}`)가
  맵·목록 그대로 남는지도 시험한다.
- 격리는 따로 테스트한다. `import()`, 무한 루프, 메모리 폭주, 앞선 평가가 남긴 전역 상태, 프로세스 kill 후
  복구를 시험한다.

## upstream과 의도적으로 다른 점

- `$`는 JS 일반 객체다. upstream은 Java `Map`을 호스트 객체로 넘기므로 `$.get('x')` 같은 Java 메서드 호출이
  되지만 Archon에서는 되지 않는다(`TypeError`). GraalJS 오라클에서 `Object.keys($)`는 입력 키가 아니라
  `get`·`put`·`size` 같은 Java `Map` 메서드 이름 목록이고 `JSON.stringify($)`는 `"{}"`였다. Archon에서는
  각각 입력 키 목록과 입력 JSON이다. 입력 안의 배열은 두 곳 모두 `Array.isArray`가 참이다.
- 스크립트는 입력의 사본만 본다. upstream DECISION·DO_WHILE에서 스크립트가 Java `Map` 메서드로 입력 맵(DO_WHILE은
  실제 태스크 출력)을 고치면 원래 데이터가 바뀌지만, Archon에서는 프로세스 경계 때문에 바뀌지 않는다.
  스크립트가 워크플로우 상태를 고치는 경로는 막는 편이 맞으므로 재현하지 않는다.
- `$` 안의 숫자는 JS 숫자(double)다. upstream은 Java `Long`을 호스트 값으로 넘기므로 2^53을 넘는 정수
  (예: `9007199254740993`)를 그대로 돌려줄 수 있지만, Archon에서는 가장 가까운 double(`9007199254740992`)이 된다.
  정밀도를 지키려면 입력마다 BigInt 같은 별도 표현이 필요하고 스크립트의 산술 의미가 달라지므로, 따르지 않는다.
  이 사례는 오라클 비교에 차이로 기록한다.
- 비유한 숫자가 태스크 출력에 들어가면 바로 저장 형태로 바뀐다. upstream은 같은 decide 안에서는 메모리의
  `Double`을 쓰다가 저장 후 다시 읽을 때 바뀌므로, 같은 decide 안에서 그 값을 다시 참조하는 드문 경우만 다를 수 있다.
- 스크립트 오류 메시지 본문(`<메시지>` 부분)은 엔진마다 다르다. 감싸는 형식만 upstream과 같다. 예를 들어
  `null.x`는 GraalJS가 ``TypeError: Cannot read property 'x' of null``, QuickJS-ng가
  ``TypeError: cannot read property 'x' of null``이고, 문법 오류 본문은 GraalJS가 위치와 원문 줄을 덧붙인다.
- `at line N`은 QuickJS-ng가 아는 줄(`Error` 객체 스택의 가장 안쪽 스크립트 프레임)일 때만 붙인다. 엔진이
  던진 오류(`ReferenceError` 등)는 GraalJS와 같은 줄이 붙는다. 다르게 나오는 경우는 둘이다. GraalJS는
  `throw 'abc'`처럼 `Error`가 아닌 값을 던지면 `throw` 문의 줄을 붙이지만 QuickJS-ng는 그 위치를 모르므로
  줄을 붙이지 않는다. 반대로 스크립트가 만든 `Error` 객체(`throw new Error('x')`)와 `JSON.parse` 같은 내장
  함수 오류에는 GraalJS가 줄을 붙이지 않지만 Archon은 붙인다.
- 결과를 읽을 때 깊이(1,000단계)와 응답 크기(기본 16MiB)에 상한이 있다. 넘으면
  `Script result is nested too deeply`·`Script result is too large`로 실패한다. upstream은 순환 참조 결과
  (`var a = {}; a.self = a; a`)에서 `getObject`가 `StackOverflowError`를 낸다.
- 짝이 없는 UTF-16 서로게이트는 결과 문자열과 오류 메시지에서 U+FFFD로 바뀐다. Archon의 문자열은 UTF-8이고,
  upstream은 Java `String`에 그대로 담는다.
- JS `Map` 결과의 키는 Java 문자열로 바꾼 뒤 맵 키가 되므로, `1`과 `'1'`처럼 문자열이 같은 키는 하나만 남는다.
  upstream `HashMap`은 둘을 따로 갖고 저장할 때 같은 JSON 키를 두 번 쓴다.
- 평가 프로세스가 비정상 종료하면 `Script evaluator exited with status <N>`로, 응답이 깨지면
  `Script evaluator sent a malformed response`로 실패한다. upstream에는 해당하는 경로가 없다. 호출 지점의
  처리(SWITCH 태스크 실패, DECISION 종료)는 다른 평가 실패와 같다.
- 등록 검사 문구에서 upstream은 엔진 메시지를 `String.format`의 형식 문자열로 쓰므로, 메시지에 `%`가 있으면
  (GraalJS 문법 오류 본문은 원문 줄을 담으므로 `$.a % 2 ==` 같은 식) 검증 대신 예외가 난다. Archon은 메시지를
  그대로 넣는다.
- `expression`이 없는 `javascript`·`graaljs` SWITCH(등록 검사를 거치지 않은 정의)는 upstream에서
  `NullPointerException`으로 태스크가 실패한다. Archon도 태스크를 실패시키되 이유는
  `Script request rejected: expression is null`이다.
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

- 결정 1~4·6·7과 SWITCH `javascript`·`graaljs`, DECISION `caseExpression`, 등록 시 문법 검사를 구현했다.
  ADR 0014 결정 2·6·7의 해당 문장에 이 ADR 링크를 달았다. DO_WHILE은 ADR 0014의 2e에서 이 평가기를 쓴다.
  - `archon_js`(`c_src/archon_js/archon_js.c`)는 요청마다 새 `JSRuntime`과 `JSContext`를 만든다(결정 1의 새
    realm보다 한 단계 더 나눴다). `JS_NewContextRaw`에 ECMAScript 내장 객체만 더하고, `JS_NewContext`가
    더하는 `performance`(시계)와 `atob`·`btoa`는 넣지 않는다. GraalJS 오라클에서도 `console`·`print`·
    `performance`·`setTimeout`·`require`는 없다. 결과를 읽는 데 쓰는 `Map` 순회와 원시 래퍼의 `valueOf`는
    스크립트 실행 전에 잡아 두므로, 스크립트가 내장 객체를 바꿔도 변환 방식은 바뀌지 않는다. typed array는
    `length` 속성이 아니라 내부 길이로 읽는다.
  - 스크립트가 예약한 Promise 작업(`then`, `async` 함수의 `await` 뒤)은 결과를 읽기 전에 같은 시간·메모리
    상한 안에서 모두 실행한다. GraalJS 오라클과 같다. `import()`는 모듈 로더가 없어 거부되는 Promise다.
  - 등록 검사는 파서가 낸 `SyntaxError`만 문법 오류로 본다. 깊은 괄호 중첩처럼 스택·메모리 상한으로 파싱이
    멈춘 경우는 upstream처럼 통과시킨다.
  - 오류 종류는 `syntax`·`runtime`·`timeout`·`conversion`(결과를 읽다가 getter·프록시가 던진 예외. upstream처럼
    감싸지 않은 메시지를 쓴다)·`limit`·`request`다. Elixir 쪽 `Archon.Script.Error`가 결정 4의 문구를 만든다.
  - `Archon.Script.Pool`은 디스패처와 워커 감독자를 `:rest_for_one`으로 둔다. 요청은 디스패처 큐에서
    기다리다 빈 워커로 가고, 워커가 호출자에게 직접 답한다. 바쁜 워커가 죽으면 디스패처가 대신 오류로 답한다.
    워커는 엔진 상한 뒤 `grace`(기본 1초)까지 응답이 없으면 OS 프로세스를 `kill -KILL`하고 새로 띄운다.
    설정은 `config :archon, Archon.Script.Pool`의 `timeout`·`grace`·`memory_limit`·`stack_limit`(기본
    1MiB)·`max_output`·`workers`다.
  - 비유한 숫자의 저장 형태는 Jackson 2.18.8(upstream이 고정한 버전)에 upstream `ObjectMapperProvider` 설정을
    준 오라클에서 `"NaN"`·`"Infinity"`·`"-Infinity"` 문자열로 확인했다(`Archon.Script.storable/1`).
- QuickJS-ng는 v0.17.0(태그 커밋 `6d46d07d04041b40f4f49eaa7fdebe44c314c699`)을
  `https://codeload.github.com/quickjs-ng/quickjs/tar.gz/refs/tags/v0.17.0`에서 받았다. tarball SHA256은
  `559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9`(905,393바이트)다. 라이브러리 빌드에
  필요한 19개 파일만 고치지 않고 `c_src/quickjs-ng/`에 넣었고, 파일별 SHA256은 `c_src/quickjs-ng/VERSION`에
  있다. `quickjs-libc.c`(`std`·`os`)와 `qjs.c`(CLI)는 넣지 않았다(2026-10-29 BOSS 확인). MIT 고지는 루트
  `NOTICE`에 적었다.
- 정답 기준: GraalJS 25.0.2(Gradle 캐시의 polyglot·js-language·truffle jar)에 upstream `ScriptEvaluator`의
  `createNewContext`·`getObject`·`handlePolyglotException`·`validateScriptSyntax`를 그대로 옮긴 Java 프로브로
  같은 스크립트를 돌려 비교했다. 값 변환은 숫자 경계(정수·`long`·`-0`·비유한 수·BigInt), 원시 래퍼,
  `arguments`, 프록시, `Map`·`Set`, 태그와 같은 모양의 사용자 객체를 포함해 오라클과 같다. 다른 사례는 위
  "upstream과 의도적으로 다른 점"에 적었다. 기대값은 `test/archon/script_test.exs`에 있다.
- CI: 모든 잡의 `mix compile`이 `archon_js`를 경고를 오류로 빌드한다. `c-sanitize` 잡이 AddressSanitizer·
  UndefinedBehaviorSanitizer·LeakSanitizer 빌드(`make ARCHON_JS_SANITIZE=1`)로 스크립트 관련 테스트를 돌린다.
  필수 체크에는 넣지 않았다.
- 서버를 배포할 때는 `priv/archon_js`가 대상 OS·CPU용으로 빌드되어야 한다. 릴리스 빌드 절차는 Phase 5에서 정한다.
