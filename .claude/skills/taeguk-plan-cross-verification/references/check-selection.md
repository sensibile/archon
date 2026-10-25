# Select checks by changed properties

Start with the approved user outcome, exact artifact and failure modes. Choose only applicable rows. Tools below are candidates, not installed capabilities or mandatory dependencies. Record command, environment, oracle, raw evidence and limitations for each chosen check. Never invent a passing threshold.

For a software change, prepare this plan from the original request and design before implementation. Identify the plan by a commit/blob or another stable version. For each chosen check, connect the requirement and claim to the oracle source, expected result, tool/LLM/mixed method, responsible role, exact artifact and environment, scope/exclusions, raw evidence location, gaps and current status. Mixed claims require actual observation for the inferred part. Keep unexecuted work NOT_RUN. The implementer and later reviewers share this plan version; repairs point back to affected check IDs and trigger verifier-selected re-checks. The plan records approved criteria and must not reverse-engineer them from the implementation.

| Changed property | Primary evidence | Cross-observation | Candidate tool surface |
| --- | --- | --- | --- |
| User flow or UI | Execute acceptance examples through the real browser | Observe API result and durable effect; keyboard/accessibility where relevant | Browser automation, accessibility checks, HTTP client |
| API contract | Valid/invalid and boundary requests against the real server | Consumer contract plus resulting state or external call | Contract runner, schema validator, HTTP client |
| Database/state | Transaction and invariant checks using the actual database | Read committed state after failure/retry; migration restore rehearsal | ExUnit integration tests, PostgreSQL SQL and query plans |
| Concurrency/retries | Real parallel calls and injected failure at transaction/external-call boundaries | Final invariant, duplicate effect and lock/timeout observations | Parallel test runner, fault injection, event/DB evidence |
| Performance/resources | Representative load with latency distribution and error denominator | CPU/memory/pool saturation and query/trace evidence under the same load | Load generator, runtime telemetry, PostgreSQL EXPLAIN |
| Security/isolation | Negative authorization and cross-tenant scenarios | Static/data-flow evidence or a separate reproduction | Security scanner, explicit HTTP/DB scenarios |
| Structure/changeability | Identify an observed change hotspot or dependency impact | Reproduce the change cost, behavior preservation and relevant history | Git history, dependency graph, compile/static checks |
| Delivery/recovery | Identify exact build artifact and deployment target; smoke the real target | Verify artifact identity, external user effect and rollback/recovery | Build manifest, deployment API/CLI, external probe |
| Operations/user effect | Compute an approved metric for a stated population/window | Compare independent source or raw event reconciliation | Telemetry queries, traces/logs, SQL, bounded CLI calculation |

A second test written from the same assumption is not independent evidence. Independence can come from a different oracle, observation layer, implementation or data source. Declare correlations. Broad scanners cannot replace a specific acceptance example. A clean scan does not prove safety.

For each row return: property, risk, expected result and source, primary check, cross-check, independence limits, artifact/version, result status, missing observation and next action. If a required environment or oracle is unavailable, record NOT_RUN or UNKNOWN rather than simulating a pass.
