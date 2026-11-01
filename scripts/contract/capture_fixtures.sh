#!/usr/bin/env bash
# Captures golden request/response fixtures from a running upstream Conductor OSS server.
#
# Usage: BASE_URL=http://localhost:8080 scripts/contract/capture_fixtures.sh [out_dir]
#
# The server must start empty (fresh SQLite file). Each exchange is written as one JSON file:
#   {"request": {"method", "path", "body"}, "response": {"status", "content_type", "body"}}
# JSON bodies are stored parsed, other bodies (text/plain responses, a request body that is not
# a JSON object, array, number or boolean: empty, `null`, a JSON string, not JSON) as strings,
# absent bodies as null.
# Fixtures are written verbatim except that the server hostname in error bodies is redacted;
# volatile fields are documented in test/fixtures/contract/README.md.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
OUT="${1:-test/fixtures/contract}"
WORKER="archon-contract"
mkdir -p "$OUT"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# call NAME METHOD PATH [BODY]
# Writes $OUT/NAME.json and leaves the response body in $tmp/body, status in $tmp/status.
# A BODY argument is sent as JSON even when it is empty ('' sends an empty body).
call() {
  local name="$1" method="$2" path="$3" body="${4:-}" has_body=$(($# >= 4))
  local args=(-sS -X "$method" -o "$tmp/body" -D "$tmp/headers" -w '%{http_code}')
  if ((has_body)); then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  curl "${args[@]}" "$BASE_URL$path" >"$tmp/status"

  local req_body='null'
  if ((has_body)); then
    if [[ -n "$body" ]] &&
      jq -e 'type | IN("object", "array", "number", "boolean")' >/dev/null 2>&1 <<<"$body"; then
      req_body="$body"
    else
      req_body="$(jq -n --arg b "$body" '$b')"
    fi
  fi

  local status ctype
  status="$(cat "$tmp/status")"
  ctype="$(grep -i '^content-type:' "$tmp/headers" | tail -1 | cut -d' ' -f2- | tr -d '\r' || true)"

  local resp_body
  if [[ ! -s "$tmp/body" ]]; then
    resp_body='null'
  elif [[ "$ctype" == application/json* ]]; then
    resp_body="$(cat "$tmp/body")"
  else
    resp_body="$(jq -Rs . <"$tmp/body")"
  fi

  jq -n \
    --arg method "$method" --arg path "$path" \
    --argjson req_body "$req_body" \
    --argjson status "$status" --arg ctype "$ctype" \
    --argjson resp_body "$resp_body" \
    '{request: {method: $method, path: $path, body: $req_body},
      response: {status: $status, content_type: (if $ctype == "" then null else $ctype end),
                 body: $resp_body}}
     # Error bodies carry the server hostname in "instance"; keep the key, drop the value.
     | if (.response.body | type) == "object" and (.response.body | has("instance"))
       then .response.body.instance = "<redacted-hostname>" else . end' >"$OUT/$name.json"

  echo "$status $method $path -> $OUT/$name.json" >&2
}

body() { cat "$tmp/body"; }

# poll_until NAME TASK_TYPE: polls until a task is returned (the queue push is asynchronous).
poll_until() {
  local name="$1" type="$2"
  for _ in $(seq 1 40); do
    call "$name" GET "/api/tasks/poll/$type?workerid=$WORKER"
    [[ "$(cat "$tmp/status")" == "200" ]] && return 0
    sleep 0.25
  done
  echo "no task of type $type after polling" >&2
  exit 1
}

# wait_status ID STATUS: waits until the workflow reaches STATUS (decisions run asynchronously).
wait_status() {
  local id="$1" want="$2"
  for _ in $(seq 1 40); do
    local got
    got="$(curl -sS "$BASE_URL/api/workflow/$id?includeTasks=false" | jq -r .status)"
    [[ "$got" == "$want" ]] && return 0
    sleep 0.25
  done
  echo "workflow $id did not reach $want" >&2
  exit 1
}

task_result() { # workflowId taskId status output_json
  jq -nc --arg w "$1" --arg t "$2" --arg s "$3" --arg worker "$WORKER" --argjson o "$4" \
    '{workflowInstanceId: $w, taskId: $t, status: $s, workerId: $worker, outputData: $o}'
}

# --- metadata ------------------------------------------------------------------------------

call metadata_register_taskdefs POST /api/metadata/taskdefs '[
  {"name": "archon_task_a", "retryCount": 0, "timeoutSeconds": 300, "responseTimeoutSeconds": 60,
   "timeoutPolicy": "TIME_OUT_WF", "inputKeys": ["x"], "outputKeys": ["y"]},
  {"name": "archon_task_b", "retryCount": 1, "retryLogic": "FIXED", "retryDelaySeconds": 1,
   "timeoutSeconds": 300, "responseTimeoutSeconds": 60}
]'
call metadata_get_taskdef GET /api/metadata/taskdefs/archon_task_a
call metadata_get_taskdef_not_found GET /api/metadata/taskdefs/archon_missing

call metadata_register_workflow_simple POST /api/metadata/workflow '{
  "name": "archon_simple", "version": 1, "schemaVersion": 2,
  "description": "Two sequential SIMPLE tasks",
  "inputParameters": ["x"],
  "outputParameters": {"y": "${task_b_ref.output.y}"},
  "timeoutPolicy": "ALERT_ONLY", "timeoutSeconds": 0,
  "tasks": [
    {"name": "archon_task_a", "taskReferenceName": "task_a_ref", "type": "SIMPLE",
     "inputParameters": {"x": "${workflow.input.x}"}},
    {"name": "archon_task_b", "taskReferenceName": "task_b_ref", "type": "SIMPLE",
     "inputParameters": {"a": "${task_a_ref.output.y}"}}
  ]
}'

call metadata_register_workflow_switch POST /api/metadata/workflow '{
  "name": "archon_switch", "version": 1, "schemaVersion": 2,
  "description": "SWITCH on workflow input",
  "timeoutPolicy": "ALERT_ONLY", "timeoutSeconds": 0,
  "tasks": [
    {"name": "route", "taskReferenceName": "route_ref", "type": "SWITCH",
     "evaluatorType": "value-param", "expression": "route",
     "inputParameters": {"route": "${workflow.input.route}"},
     "decisionCases": {
       "a": [{"name": "archon_task_a", "taskReferenceName": "case_a_ref", "type": "SIMPLE"}],
       "b": [{"name": "archon_task_b", "taskReferenceName": "case_b_ref", "type": "SIMPLE"}]
     },
     "defaultCase": []}
  ]
}'

call metadata_register_workflow_fork POST /api/metadata/workflow '{
  "name": "archon_fork", "version": 1, "schemaVersion": 2,
  "description": "FORK_JOIN with two branches and a JOIN",
  "timeoutPolicy": "ALERT_ONLY", "timeoutSeconds": 0,
  "tasks": [
    {"name": "fork", "taskReferenceName": "fork_ref", "type": "FORK_JOIN",
     "forkTasks": [
       [{"name": "archon_task_a", "taskReferenceName": "branch_a_ref", "type": "SIMPLE"}],
       [{"name": "archon_task_b", "taskReferenceName": "branch_b_ref", "type": "SIMPLE"}]
     ]},
    {"name": "join", "taskReferenceName": "join_ref", "type": "JOIN",
     "joinOn": ["branch_a_ref", "branch_b_ref"]}
  ]
}'

call metadata_register_workflow_conflict POST /api/metadata/workflow \
  "$(jq -c .request.body "$OUT/metadata_register_workflow_simple.json")"
call metadata_get_workflow GET '/api/metadata/workflow/archon_simple?version=1'
call metadata_get_workflow_switch GET /api/metadata/workflow/archon_switch
call metadata_get_workflow_fork GET /api/metadata/workflow/archon_fork
call metadata_get_workflow_not_found GET /api/metadata/workflow/archon_missing

# --- SIMPLE: start, poll, update, complete -------------------------------------------------

call workflow_start_simple POST '/api/workflow/archon_simple?correlationId=archon-corr-1' '{"x": 1}'
simple_id="$(body)"

poll_until task_poll_simple_a archon_task_a
task_a="$(body | jq -r .taskId)"
call workflow_get_running GET "/api/workflow/$simple_id"

call task_update_simple_a POST /api/tasks "$(task_result "$simple_id" "$task_a" COMPLETED '{"y": 2}')"

poll_until task_poll_simple_b archon_task_b
task_b="$(body | jq -r .taskId)"
call task_update_v2_simple_b POST /api/tasks/update-v2 \
  "$(task_result "$simple_id" "$task_b" COMPLETED '{"y": 3}')"

wait_status "$simple_id" COMPLETED
call workflow_get_completed_simple GET "/api/workflow/$simple_id"
call workflow_get_without_tasks GET "/api/workflow/$simple_id?includeTasks=false"
call workflow_get_status GET "/api/workflow/$simple_id/status?includeOutput=true"
call task_get GET "/api/tasks/$task_a"
call task_poll_empty GET "/api/tasks/poll/archon_task_b?workerid=$WORKER"

# --- SWITCH: start with StartWorkflowRequest ------------------------------------------------

call workflow_start_request_switch POST /api/workflow \
  '{"name": "archon_switch", "version": 1, "correlationId": "archon-corr-2", "input": {"route": "b"}}'
switch_id="$(body)"
poll_until task_poll_switch_b archon_task_b
call task_update_switch_b POST /api/tasks \
  "$(task_result "$switch_id" "$(body | jq -r .taskId)" COMPLETED '{"picked": "b"}')"
wait_status "$switch_id" COMPLETED
call workflow_get_completed_switch GET "/api/workflow/$switch_id"

# --- FORK_JOIN / JOIN ------------------------------------------------------------------------

call workflow_start_fork POST /api/workflow/archon_fork '{}'
fork_id="$(body)"
for _ in $(seq 1 40); do
  call task_batch_poll_fork_a GET "/api/tasks/poll/batch/archon_task_a?workerid=$WORKER&count=2&timeout=500"
  [[ "$(body | jq length)" -gt 0 ]] && break
done
call task_update_fork_a POST /api/tasks \
  "$(task_result "$fork_id" "$(body | jq -r '.[0].taskId')" COMPLETED '{"branch": "a"}')"
poll_until task_poll_fork_b archon_task_b
call task_update_fork_b POST /api/tasks \
  "$(task_result "$fork_id" "$(body | jq -r .taskId)" COMPLETED '{"branch": "b"}')"
wait_status "$fork_id" COMPLETED
call workflow_get_completed_fork GET "/api/workflow/$fork_id"

# --- terminate ------------------------------------------------------------------------------

call workflow_start_to_terminate POST /api/workflow/archon_simple '{"x": 9}'
term_id="$(body)"
call workflow_terminate DELETE "/api/workflow/$term_id?reason=archon-contract-terminate"
call workflow_get_terminated GET "/api/workflow/$term_id"
call workflow_get_not_found GET /api/workflow/00000000-0000-0000-0000-000000000000

# --- health (ADR 0023, decision 6: the fixtures below were added for Phase 5) ----------------

call health GET /health
call health_api GET /api/health

# --- metadata: list, single update, overwrite, bulk update, validation ----------------------

call metadata_list_taskdefs GET /api/metadata/taskdefs
# A single object where the array is expected: Jackson reads it as a one-element list.
call metadata_register_taskdefs_single POST /api/metadata/taskdefs \
  '{"name": "archon_task_c", "retryCount": 0, "timeoutSeconds": 300, "responseTimeoutSeconds": 60}'
call metadata_update_taskdef PUT /api/metadata/taskdefs \
  '{"name": "archon_task_c", "description": "updated", "retryCount": 0, "timeoutSeconds": 600,
    "responseTimeoutSeconds": 60}'
call metadata_get_taskdef_updated GET /api/metadata/taskdefs/archon_task_c
call metadata_update_taskdef_not_found PUT /api/metadata/taskdefs \
  '{"name": "archon_missing", "timeoutSeconds": 300, "responseTimeoutSeconds": 60}'
call metadata_register_taskdefs_empty POST /api/metadata/taskdefs '[]'
call metadata_register_taskdefs_no_name POST /api/metadata/taskdefs '[{"retryCount": 1}]'
# invalidValue of a string, of a primitive given null (0) and of an integer given a fraction (-1).
call metadata_register_taskdefs_blank_name POST /api/metadata/taskdefs '[{"name": ""}]'
call metadata_register_taskdefs_coerced POST /api/metadata/taskdefs \
  '[{"name": "archon_coerced", "responseTimeoutSeconds": null}, {"name": "archon_coerced", "retryCount": -1.7}]'
call metadata_register_workflow_no_tasks POST /api/metadata/workflow \
  '{"name": "archon_no_tasks", "version": 1, "tasks": []}'

call metadata_register_workflow_overwrite POST '/api/metadata/workflow?overwrite=true' \
  "$(jq -c '.request.body | .description = "Overwritten"' "$OUT/metadata_register_workflow_simple.json")"
call metadata_get_workflow_overwritten GET '/api/metadata/workflow/archon_simple?version=1'
call metadata_get_workflow_version_not_found GET '/api/metadata/workflow/archon_simple?version=9'

bulk_task='{"name": "archon_task_c", "taskReferenceName": "task_c_ref", "type": "SIMPLE"}'
call metadata_update_workflows PUT /api/metadata/workflow \
  "[{\"name\": \"archon_bulk\", \"version\": 1, \"tasks\": [$bulk_task]},
    {\"name\": \"archon_bulk\", \"version\": 2, \"description\": \"v2\", \"tasks\": [$bulk_task]}]"
call metadata_get_workflow_bulk_latest GET /api/metadata/workflow/archon_bulk
# One invalid element fails the whole request: the valid one is not stored either.
call metadata_update_workflows_invalid PUT /api/metadata/workflow \
  "[{\"name\": \"archon_bulk_valid\", \"version\": 1, \"tasks\": [$bulk_task]},
    {\"name\": \"archon_bulk_invalid\", \"version\": 1, \"tasks\": []}]"
call metadata_get_workflow_bulk_rejected GET /api/metadata/workflow/archon_bulk_valid
call metadata_update_workflows_empty PUT /api/metadata/workflow '[]'

# --- workflow: start errors, inline definition, fetch options, terminate errors -------------

call workflow_start_not_found POST /api/workflow/archon_missing '{}'
call workflow_start_request_not_found POST /api/workflow '{"name": "archon_missing", "version": 3}'

inline_request() { # input n
  jq -nc --argjson n "$1" '{name: "archon_inline", correlationId: "archon-corr-3", input: {n: $n},
    workflowDef: {name: "archon_inline", version: 1, schemaVersion: 2, timeoutSeconds: 0,
      tasks: [{name: "archon_task_c", taskReferenceName: "task_c_ref", type: "SIMPLE",
               inputParameters: {n: "${workflow.input.n}"}}]}}'
}
call workflow_start_inline POST /api/workflow "$(inline_request 1)"
inline_id="$(body)"
call workflow_get_running_without_tasks GET "/api/workflow/$inline_id?includeTasks=false"
call workflow_get_status_default GET "/api/workflow/$inline_id/status"
call workflow_get_status_all GET "/api/workflow/$simple_id/status?includeOutput=true&includeVariables=true"
call workflow_get_status_not_found GET /api/workflow/00000000-0000-0000-0000-000000000000/status
call workflow_start_inline_second POST /api/workflow "$(inline_request 2)"

poll_until task_poll_inline_c archon_task_c
task_c="$(body | jq -r .taskId)"
call workflow_get_inline GET "/api/workflow/$inline_id"
# The other workflow's archon_task_c is the next task of the same type.
call task_update_v2_next POST /api/tasks/update-v2 \
  "$(task_result "$inline_id" "$task_c" COMPLETED '{"done": 1}')"
wait_status "$inline_id" COMPLETED
call workflow_terminate_completed DELETE "/api/workflow/$inline_id?reason=archon-contract-late"
call workflow_terminate_not_found DELETE /api/workflow/00000000-0000-0000-0000-000000000000

# --- task: empty batch, unknown task, validation --------------------------------------------

call task_batch_poll_empty GET "/api/tasks/poll/batch/archon_task_a?workerid=$WORKER&count=2&timeout=100"
call task_get_not_found GET /api/tasks/00000000-0000-0000-0000-000000000000
call task_update_not_found POST /api/tasks \
  "$(task_result "$inline_id" 00000000-0000-0000-0000-000000000000 COMPLETED '{}')"
call task_update_workflow_not_found POST /api/tasks \
  "$(task_result 00000000-0000-0000-0000-000000000000 00000000-0000-0000-0000-000000000000 COMPLETED '{}')"
call task_update_v2_not_found POST /api/tasks/update-v2 \
  "$(task_result "$inline_id" 00000000-0000-0000-0000-000000000000 COMPLETED '{}')"
call task_update_invalid POST /api/tasks \
  '{"workflowInstanceId": "00000000-0000-0000-0000-000000000000", "taskId": ""}'
call task_update_v2_invalid POST /api/tasks/update-v2 \
  '{"workflowInstanceId": "00000000-0000-0000-0000-000000000000", "taskId": ""}'

# --- routing: unknown path, Later paths shaped like MVP parameter paths, other methods, bad input

call route_not_found GET /api/archon/missing
call route_later_workflow_search GET /api/workflow/search
call route_later_workflow_running GET /api/workflow/running/archon_simple
call route_later_workflow_test POST /api/workflow/test '{}'
call route_later_metadata_names GET /api/metadata/workflow/names
call route_later_tasks_search GET /api/tasks/search
call route_method_patch_workflow PATCH /api/workflow '{}'
call route_method_put_task PUT /api/tasks/00000000-0000-0000-0000-000000000000 '{}'
call request_body_not_json POST /api/metadata/taskdefs 'not json'
call request_query_not_number GET "/api/tasks/poll/batch/archon_task_a?workerid=$WORKER&count=abc"
call request_query_not_boolean GET "/api/workflow/$inline_id?includeTasks=maybe"

# --- slice 5f (ADR 0023, decision 6): the answers the other slices wrote in their tests --------
# Errors first: none of them changes what the server holds.

# A missing or null body names the handler, one route each.
call metadata_register_taskdefs_missing_body POST /api/metadata/taskdefs ''
call metadata_update_taskdef_null_body PUT /api/metadata/taskdefs 'null'
call metadata_register_workflow_missing_body POST /api/metadata/workflow ''
call metadata_update_workflows_null_body PUT /api/metadata/workflow 'null'
call workflow_start_request_missing_body POST /api/workflow ''
call workflow_start_null_body POST /api/workflow/archon_simple 'null'
call task_update_missing_body POST /api/tasks ''
call task_update_v2_null_body POST /api/tasks/update-v2 'null'

# Validation prefixes and null elements of the metadata routes.
call metadata_register_workflow_no_name POST /api/metadata/workflow \
  '{"tasks": [{"name": "archon_task_a", "taskReferenceName": "task_a_ref", "type": "SIMPLE"}]}'
call metadata_register_workflow_overwrite_invalid POST '/api/metadata/workflow?overwrite=true' \
  '{"name": "archon_simple", "version": 1, "tasks": []}'
call metadata_update_taskdef_invalid PUT /api/metadata/taskdefs '{"name": ""}'
call metadata_update_workflows_null_element PUT /api/metadata/workflow '[null]'
call metadata_register_taskdefs_null_element POST /api/metadata/taskdefs '[null]'

# A value Jackson cannot convert (Archon writes its own message, ADR 0023 decision 4).
call metadata_register_taskdefs_wrong_type POST /api/metadata/taskdefs \
  '[{"name": "archon_task_x", "retryCount": "abc"}]'
call task_update_wrong_type POST /api/tasks \
  '{"workflowInstanceId": "00000000-0000-0000-0000-000000000000", "taskId": "x", "status": "BAD"}'
call workflow_start_request_wrong_type POST /api/workflow '{"name": "archon_simple", "priority": "abc"}'
call workflow_start_not_object POST /api/workflow/archon_simple '[]'

# Query values that do not convert.
call metadata_register_workflow_query_not_boolean POST '/api/metadata/workflow?overwrite=abc' \
  "$(jq -c .request.body "$OUT/metadata_register_workflow_simple.json")"
call metadata_get_workflow_query_not_number GET '/api/metadata/workflow/archon_simple?version=abc'
call workflow_start_query_not_number POST '/api/workflow/archon_simple?version=abc' '{}'
call workflow_get_status_query_not_boolean GET "/api/workflow/$simple_id/status?includeOutput=abc"

# Task routes.
call task_update_v2_invalid_both POST /api/tasks/update-v2 '{}'
call task_batch_poll_timeout_too_long GET "/api/tasks/poll/batch/archon_task_a?workerid=$WORKER&timeout=5001"
call task_batch_poll_count_zero GET "/api/tasks/poll/batch/archon_task_a?workerid=$WORKER&count=0"
call task_poll_domain_empty GET "/api/tasks/poll/archon_task_a?workerid=$WORKER&domain=archon_domain"

# Start errors.
call workflow_start_request_no_name POST /api/workflow '{}'
call workflow_start_request_priority_too_high POST /api/workflow '{"name": "archon_simple", "priority": 100}'
call workflow_start_request_invalid_definition POST /api/workflow \
  '{"name": "archon_inline", "workflowDef": {"name": "archon_inline", "tasks": [
     {"name": "archon_task_c", "type": "SIMPLE"}]}}'
call workflow_start_request_blank_name POST /api/workflow '{"name": " "}'
call workflow_start_request_null_input POST /api/workflow '{"name": "archon_simple", "input": null}'
call workflow_start_request_external_input POST /api/workflow \
  '{"name": "archon_simple", "externalInputPayloadStoragePath": "archon/input.json"}'
call workflow_start_priority_too_low POST '/api/workflow/archon_simple?priority=-1' '{}'
call workflow_start_version_not_found POST '/api/workflow/archon_simple?version=7' '{}'

# Status without a correlation ID, terminating a TERMINATED workflow.
call workflow_get_status_no_correlation GET "/api/workflow/$fork_id/status"
call workflow_terminate_terminated DELETE "/api/workflow/$term_id"

# Starts last: they leave tasks in the queues.
call workflow_start_request_defaults POST /api/workflow \
  '{"name": "archon_simple", "priority": null, "taskToDomain": null, "input": {"x": 5}}'
call workflow_get_request_defaults GET "/api/workflow/$(body)?includeTasks=false"
call workflow_start_request_inline_other_name POST /api/workflow \
  "$(jq -c '.name = "archon_missing"' <<<"$(inline_request 3)")"
call workflow_start_options POST '/api/workflow/archon_simple?version=1&correlationId=archon-corr-4&priority=5' \
  '{"x": 7}'
call workflow_get_options GET "/api/workflow/$(body)?includeTasks=false"

# --- Phase 6 (ADR 0025, decision 7): workflow operations ---------------------------------------
# Own task types and definitions: the starts above left archon_task_a and archon_task_c tasks in
# the queues. Each polled type has one task queued at a time; the other tasks are updated by the
# task ID a workflow GET answered. Errors that change nothing come first, then the flows.

# call_until NAME METHOD PATH JQ_FILTER [BODY]: repeats the request until the response body
# passes the filter (an asynchronous step happened), keeping the last answer as the fixture.
call_until() {
  local name="$1" method="$2" path="$3" filter="$4"
  shift 4
  for _ in $(seq 1 40); do
    call "$name" "$method" "$path" "$@"
    jq -e "$filter" >/dev/null 2>&1 <"$tmp/body" && return 0
    sleep 0.25
  done
  echo "$name: $filter did not hold" >&2
  exit 1
}

fixture_body() { jq -r .response.body "$OUT/$1.json"; }
task_id() { body | jq -r "[.tasks[] | select(.referenceTaskName == \"$1\")][${2:-0}].taskId"; }
child_id() { body | jq -r "[.tasks[] | select(.referenceTaskName == \"$1\")][${2:-0}].subWorkflowId"; }
missing=00000000-0000-0000-0000-000000000000

ops_task_def() { # name retryCount
  jq -nc --arg n "$1" --argjson r "$2" '{name: $n, retryCount: $r, retryLogic: "FIXED",
    retryDelaySeconds: 0, timeoutSeconds: 3600, responseTimeoutSeconds: 3600}'
}
call metadata_register_ops_taskdefs POST /api/metadata/taskdefs "$(jq -sc . <<<"
  $(ops_task_def archon_ops_a 0) $(ops_task_def archon_ops_b 0) $(ops_task_def archon_ops_c 0)
  $(ops_task_def archon_ops_cb 0) $(ops_task_def archon_ops_idle 0)
  $(ops_task_def archon_ops_sub 1) $(ops_task_def archon_ops_sub_once 0)")"

ops_def() { # version description
  jq -nc --argjson v "$1" --arg d "$2" '{name: "archon_ops", version: $v, schemaVersion: 2,
    description: $d, inputParameters: ["x"], timeoutPolicy: "ALERT_ONLY", timeoutSeconds: 0,
    tasks: [
      {name: "archon_ops_a", taskReferenceName: "ops_a_ref", type: "SIMPLE",
       inputParameters: {x: "${workflow.input.x}"}},
      {name: "archon_ops_b", taskReferenceName: "ops_b_ref", type: "SIMPLE"}]}'
}
simple_def() { # name ref taskType
  jq -nc --arg n "$1" --arg r "$2" --arg t "$3" '{name: $n, version: 1, schemaVersion: 2,
    timeoutPolicy: "ALERT_ONLY", timeoutSeconds: 0,
    tasks: [{name: $t, taskReferenceName: $r, type: "SIMPLE"}]}'
}
sub_def() { # name ref taskName child
  jq -nc --arg n "$1" --arg r "$2" --arg t "$3" --arg c "$4" '{name: $n, version: 1,
    schemaVersion: 2, timeoutPolicy: "ALERT_ONLY", timeoutSeconds: 0,
    tasks: [{name: $t, taskReferenceName: $r, type: "SUB_WORKFLOW",
             subWorkflowParam: {name: $c, version: 1}}]}'
}
waits_def() {
  jq -nc '{name: "archon_ops_waits", version: 1, schemaVersion: 2, timeoutPolicy: "ALERT_ONLY",
    timeoutSeconds: 0,
    tasks: ([range(1; 6) | {name: "archon_wait", taskReferenceName: "wait\(.)_ref", type: "WAIT"}]
            + [{name: "archon_ops_idle", taskReferenceName: "idle_ref", type: "SIMPLE"}])}'
}
call metadata_register_workflow_ops POST /api/metadata/workflow "$(ops_def 1 "Two SIMPLE tasks")"
call metadata_register_workflow_ops_v2 POST /api/metadata/workflow "$(ops_def 2 "Version 2")"
call metadata_register_workflow_ops_waits POST /api/metadata/workflow "$(waits_def)"
call metadata_register_workflow_ops_idle POST /api/metadata/workflow \
  "$(simple_def archon_ops_idle idle_ref archon_ops_idle)"
call metadata_register_workflow_ops_callback POST /api/metadata/workflow \
  "$(simple_def archon_ops_callback cb_ref archon_ops_cb)"
call metadata_register_workflow_ops_child POST /api/metadata/workflow \
  "$(simple_def archon_ops_child child_c_ref archon_ops_c)"
call metadata_register_workflow_ops_noop POST /api/metadata/workflow '{
  "name": "archon_ops_noop", "version": 1, "schemaVersion": 2, "timeoutPolicy": "ALERT_ONLY",
  "timeoutSeconds": 0,
  "tasks": [{"name": "route", "taskReferenceName": "noop_ref", "type": "SWITCH",
             "evaluatorType": "value-param", "expression": "route",
             "inputParameters": {"route": "${workflow.input.route}"},
             "decisionCases": {"x": [{"name": "archon_ops_idle", "taskReferenceName": "noop_idle_ref",
                                       "type": "SIMPLE"}]},
             "defaultCase": []}]
}'
call metadata_register_workflow_ops_loop POST /api/metadata/workflow '{
  "name": "archon_ops_loop", "version": 1, "schemaVersion": 2, "timeoutPolicy": "ALERT_ONLY",
  "timeoutSeconds": 0,
  "tasks": [{"name": "loop", "taskReferenceName": "loop_ref", "type": "DO_WHILE",
             "inputParameters": {"value": 2},
             "loopCondition": "if ($.loop_ref['"'"'iteration'"'"'] < $.value) { true; } else { false; }",
             "loopOver": [{"name": "archon_ops_b", "taskReferenceName": "loop_b_ref", "type": "SIMPLE"}]}]
}'
call metadata_register_workflow_ops_mid POST /api/metadata/workflow \
  "$(sub_def archon_ops_mid mid_sub_ref archon_ops_sub archon_ops_child)"
call metadata_register_workflow_ops_top POST /api/metadata/workflow \
  "$(sub_def archon_ops_top top_sub_ref archon_ops_sub_once archon_ops_mid)"
call metadata_register_workflow_ops_parent POST /api/metadata/workflow \
  "$(sub_def archon_ops_parent parent_sub_ref archon_ops_sub_once archon_ops_child)"
call metadata_register_workflow_ops_signal_parent POST /api/metadata/workflow \
  "$(sub_def archon_ops_signal_parent signal_sub_ref archon_ops_sub_once archon_ops_waits)"

# metadata: lists, validation, deleting what is not there.
call metadata_list_workflows GET /api/metadata/workflow
call metadata_list_workflows_classifier GET '/api/metadata/workflow?classifier=WORKFLOW'
call metadata_list_workflows_classifier_agent GET '/api/metadata/workflow?classifier=agent'
call metadata_workflow_names_and_versions GET /api/metadata/workflow/names-and-versions
call metadata_workflow_names GET /api/metadata/workflow/names
call metadata_workflow_latest_versions GET /api/metadata/workflow/latest-versions
call metadata_workflow_versions GET /api/metadata/workflow/archon_ops/versions
call metadata_workflow_versions_missing GET /api/metadata/workflow/archon_missing/versions
call metadata_validate_workflow POST /api/metadata/workflow/validate "$(ops_def 3 "Not stored")"
call metadata_validate_workflow_invalid POST /api/metadata/workflow/validate \
  '{"name": "archon_ops", "version": 1, "tasks": []}'
call metadata_get_workflow_not_validated GET '/api/metadata/workflow/archon_ops?version=3'
call metadata_delete_workflow_not_found DELETE /api/metadata/workflow/archon_missing/1
call metadata_delete_workflow_version_not_number DELETE /api/metadata/workflow/archon_ops/abc
call metadata_delete_taskdef_not_found DELETE /api/metadata/taskdefs/archon_missing

# Lifecycle errors: unknown, finished and running workflows (the MVP scenario's).
completed_id="$(fixture_body workflow_start_simple)"
running_id="$(fixture_body workflow_start_options)"
call workflow_pause_not_found PUT "/api/workflow/$missing/pause"
call workflow_resume_not_found PUT "/api/workflow/$missing/resume"
call workflow_retry_not_found POST "/api/workflow/$missing/retry"
call workflow_restart_not_found POST "/api/workflow/$missing/restart"
call workflow_rerun_not_found POST "/api/workflow/$missing/rerun" '{}'
call workflow_skiptask_not_found PUT "/api/workflow/$missing/skiptask/task_a_ref"
call workflow_resetcallbacks_not_found POST "/api/workflow/$missing/resetcallbacks"
call workflow_remove_not_found DELETE "/api/workflow/$missing/remove"
call workflow_terminate_remove_not_found DELETE "/api/workflow/$missing/terminate-remove"
call workflow_pause_completed PUT "/api/workflow/$completed_id/pause"
call workflow_resume_completed PUT "/api/workflow/$completed_id/resume"
call workflow_retry_completed POST "/api/workflow/$completed_id/retry"
call workflow_rerun_task_not_found POST "/api/workflow/$completed_id/rerun" \
  "{\"reRunFromTaskId\": \"$missing\"}"
call workflow_skiptask_completed PUT "/api/workflow/$completed_id/skiptask/task_b_ref"
call workflow_resetcallbacks_completed POST "/api/workflow/$completed_id/resetcallbacks"
call workflow_terminate_remove_completed DELETE "/api/workflow/$completed_id/terminate-remove"
call workflow_resume_running PUT "/api/workflow/$running_id/resume"
call workflow_retry_running POST "/api/workflow/$running_id/retry"
call workflow_restart_running POST "/api/workflow/$running_id/restart"
call workflow_rerun_running POST "/api/workflow/$running_id/rerun" '{}'
call workflow_skiptask_unknown_ref PUT "/api/workflow/$running_id/skiptask/archon_missing_ref"
call workflow_skiptask_existing_ref PUT "/api/workflow/$running_id/skiptask/task_a_ref"
call workflow_remove_running DELETE "/api/workflow/$running_id/remove"
call workflow_get_running_not_removed GET "/api/workflow/$running_id?includeTasks=false"

# Queries on the MVP scenario's workflows.
call workflow_tasks GET "/api/workflow/$completed_id/tasks"
call workflow_tasks_status GET "/api/workflow/$completed_id/tasks?status=COMPLETED"
call workflow_tasks_status_list GET "/api/workflow/$completed_id/tasks?status=scheduled,completed&status=FAILED"
call workflow_tasks_status_comma GET "/api/workflow/$completed_id/tasks?status=SCHEDULED,COMPLETED"
call workflow_tasks_status_none GET "/api/workflow/$completed_id/tasks?status=SCHEDULED"
call workflow_tasks_page GET "/api/workflow/$completed_id/tasks?start=1&count=1"
call workflow_tasks_count_negative GET "/api/workflow/$completed_id/tasks?count=-1"
call workflow_tasks_start_negative GET "/api/workflow/$completed_id/tasks?start=-1"
call workflow_tasks_start_past_end GET "/api/workflow/$completed_id/tasks?start=5&count=-1"
call workflow_tasks_not_found GET "/api/workflow/$missing/tasks"
call workflow_correlated GET /api/workflow/archon_simple/correlated/archon-corr-1
call workflow_correlated_closed GET '/api/workflow/archon_simple/correlated/archon-corr-1?includeClosed=true'
call workflow_correlated_closed_tasks GET \
  '/api/workflow/archon_simple/correlated/archon-corr-1?includeClosed=true&includeTasks=true'
call workflow_correlated_post POST /api/workflow/archon_simple/correlated \
  '["archon-corr-1", "archon-corr-4", "archon-missing"]'
call workflow_correlated_post_closed POST '/api/workflow/archon_simple/correlated?includeClosed=true' \
  '["archon-corr-1"]'
call workflow_correlated_post_empty POST /api/workflow/archon_simple/correlated '[]'
call workflow_running GET /api/workflow/running/archon_simple
call workflow_running_other_version GET '/api/workflow/running/archon_simple?version=2'
call workflow_running_time GET '/api/workflow/running/archon_simple?version=1&startTime=1&endTime=4102444800000'
call workflow_running_time_other_version GET \
  '/api/workflow/running/archon_simple?version=2&startTime=1&endTime=4102444800000'
call workflow_running_unknown GET /api/workflow/running/archon_missing

# Task updates by reference and signals that find no task.
call task_ref_update_workflow_not_found POST "/api/tasks/$missing/task_a_ref/COMPLETED" '{}'
call task_ref_update_sync_workflow_not_found POST "/api/tasks/$missing/task_a_ref/COMPLETED/sync" '{}'
call task_ref_update_no_task POST "/api/tasks/$completed_id/task_a_ref/COMPLETED" '{}'
call task_ref_update_sync_no_task POST "/api/tasks/$completed_id/task_a_ref/COMPLETED/sync" '{}'
call task_ref_update_status_invalid POST "/api/tasks/$completed_id/task_a_ref/BAD" '{}'
call task_signal_workflow_not_found POST "/api/tasks/$missing/COMPLETED/signal" '{}'
call task_signal_sync_workflow_not_found POST "/api/tasks/$missing/COMPLETED/signal/sync" '{}'
call task_signal_no_task POST "/api/tasks/$completed_id/COMPLETED/signal" '{}'
call task_signal_sync_no_task POST "/api/tasks/$completed_id/COMPLETED/signal/sync" '{}'

# Later and Unsupported routes shaped like the new parameter routes.
call route_unsupported_workflow_decide PUT "/api/workflow/decide/$missing"
call route_later_tasks_requeue POST /api/tasks/queue/requeue/archon_ops_idle ''
call route_later_workflow_bulk_search POST /api/workflow/bulk/search "[\"$missing\"]"
call route_later_task_log GET "/api/tasks/$missing/log"

# execute: the four return strategies on a WAIT, a finished workflow, a timeout, inline.
call workflow_execute_not_found POST /api/workflow/execute/archon_missing/1 '{}'
call workflow_execute POST '/api/workflow/execute/archon_ops_waits/1?requestId=archon-request-1' \
  '{"input": {"k": 1}, "correlationId": "archon-ops-execute"}'
execute_id="$(body | jq -r .workflowId)"
call workflow_execute_blocking_workflow POST \
  '/api/workflow/execute/archon_ops_waits/1?requestId=archon-request-2&returnStrategy=BLOCKING_WORKFLOW' '{}'
call workflow_execute_blocking_task POST \
  '/api/workflow/execute/archon_ops_waits/1?requestId=archon-request-3&returnStrategy=BLOCKING_TASK' '{}'
call workflow_execute_blocking_task_input POST \
  '/api/workflow/execute/archon_ops_waits/1?requestId=archon-request-4&returnStrategy=BLOCKING_TASK_INPUT' \
  '{"input": {"k": 4}}'
call workflow_execute_latest POST '/api/workflow/execute/archon_ops_noop/0?requestId=archon-request-5' '{}'
call workflow_execute_completed_blocking_task POST \
  '/api/workflow/execute/archon_ops_noop/1?requestId=archon-request-6&returnStrategy=BLOCKING_TASK' '{}'
call workflow_execute_wait_until_task POST \
  '/api/workflow/execute/archon_ops_noop/1?requestId=archon-request-7&returnStrategy=BLOCKING_TASK&waitUntilTaskRef=noop_ref' '{}'
call workflow_execute_timeout POST \
  '/api/workflow/execute/archon_ops_idle/1?requestId=archon-request-8&waitForSeconds=1' '{}'
call workflow_execute_timeout_blocking_task POST \
  '/api/workflow/execute/archon_ops_idle/1?requestId=archon-request-9&waitForSeconds=1&returnStrategy=BLOCKING_TASK' '{}'
call workflow_execute_inline POST '/api/workflow/execute/archon_ops_inline/1?requestId=archon-request-10' \
  '{"input": {"k": 10}, "workflowDef": {"name": "archon_ops_inline", "version": 1, "schemaVersion": 2,
     "tasks": [{"name": "archon_wait", "taskReferenceName": "inline_wait_ref", "type": "WAIT"}]}}'

# signal: four strategies down a chain of WAITs, a timeout, then no WAIT left to signal.
call workflow_start_signal POST /api/workflow/archon_ops_waits '{"k": 0}'
signal_id="$(body)"
call_until workflow_get_signal GET "/api/workflow/$signal_id" \
  '.tasks[0].status == "IN_PROGRESS"'
call task_signal_sync POST "/api/tasks/$signal_id/COMPLETED/signal/sync" '{"s": 1}'
call task_signal_sync_blocking_workflow POST \
  "/api/tasks/$signal_id/COMPLETED/signal/sync?returnStrategy=BLOCKING_WORKFLOW" '{"s": 2}'
call task_signal_sync_blocking_task POST \
  "/api/tasks/$signal_id/COMPLETED/signal/sync?returnStrategy=BLOCKING_TASK" '{"s": 3}'
call task_signal_sync_blocking_task_input POST \
  "/api/tasks/$signal_id/COMPLETED/signal/sync?returnStrategy=BLOCKING_TASK_INPUT" '{"s": 4}'
call task_signal_sync_timeout POST \
  "/api/tasks/$signal_id/COMPLETED/signal/sync?timeoutMillis=500" '{"s": 5}'
call task_signal_sync_no_wait POST \
  "/api/tasks/$signal_id/COMPLETED/signal/sync?returnStrategy=BLOCKING_TASK" '{"s": 6}'
call task_signal_no_wait POST "/api/tasks/$signal_id/COMPLETED/signal" '{"s": 7}'
call workflow_get_signal_no_wait GET "/api/workflow/$signal_id"
call task_signal POST "/api/tasks/$execute_id/COMPLETED/signal" '{"s": 8}'
call_until workflow_get_signaled GET "/api/workflow/$execute_id" \
  '.tasks[1].status == "IN_PROGRESS"'
# A WAIT in a child: the signal goes down the SUB_WORKFLOW.
call workflow_start_signal_parent POST /api/workflow/archon_ops_signal_parent '{}'
signal_parent_id="$(body)"
call_until workflow_get_signal_parent GET "/api/workflow/$signal_parent_id" \
  '.tasks[0].subWorkflowId != null'
signal_child_id="$(child_id signal_sub_ref)"
call_until workflow_get_signal_child GET "/api/workflow/$signal_child_id" \
  '.tasks[0].status == "IN_PROGRESS"'
call task_signal_sync_child POST \
  "/api/tasks/$signal_parent_id/COMPLETED/signal/sync?returnStrategy=BLOCKING_TASK" '{"s": 9}'

# Task updates by reference, a DO_WHILE iteration's reference.
call workflow_start_ref POST '/api/workflow/archon_ops?correlationId=archon-ops-ref' '{"x": 1}'
ref_id="$(body)"
call task_ref_update POST "/api/tasks/$ref_id/ops_a_ref/COMPLETED?workerid=archon-ref-worker" '{"y": 1}'
call_until workflow_get_ref_updated GET "/api/workflow/$ref_id" '(.tasks | length) == 2'
call task_ref_update_sync POST "/api/tasks/$ref_id/ops_b_ref/COMPLETED/sync" '{"z": 2}'
call task_ref_update_done POST "/api/tasks/$ref_id/ops_b_ref/COMPLETED" '{}'
call workflow_start_loop POST /api/workflow/archon_ops_loop '{}'
loop_id="$(body)"
call task_ref_update_loop POST "/api/tasks/$loop_id/loop_b_ref/COMPLETED" '{"i": 1}'
call_until workflow_get_loop_second GET "/api/workflow/$loop_id" '(.tasks | length) == 3'
call task_ref_update_loop_second POST "/api/tasks/$loop_id/loop_b_ref__2/COMPLETED" '{"i": 2}'
wait_status "$loop_id" COMPLETED
call workflow_get_loop_completed GET "/api/workflow/$loop_id"

# pause and resume, and the queries that see a PAUSED workflow.
call workflow_start_life POST '/api/workflow/archon_ops?version=1&correlationId=archon-ops-life' '{"x": 2}'
life_id="$(body)"
call workflow_start_life_v2 POST '/api/workflow/archon_ops?version=2&correlationId=archon-ops-life' '{"x": 2}'
call workflow_get_life_v2 GET "/api/workflow/$(body)"
call workflow_pause PUT "/api/workflow/$life_id/pause"
call workflow_get_paused GET "/api/workflow/$life_id"
call workflow_pause_paused PUT "/api/workflow/$life_id/pause"
call workflow_skiptask_paused PUT "/api/workflow/$life_id/skiptask/ops_b_ref"
call workflow_running_ops GET /api/workflow/running/archon_ops
call workflow_running_ops_time GET \
  '/api/workflow/running/archon_ops?version=2&startTime=1&endTime=4102444800000'
call workflow_correlated_paused GET /api/workflow/archon_ops/correlated/archon-ops-life
call workflow_correlated_paused_closed GET \
  '/api/workflow/archon_ops/correlated/archon-ops-life?includeClosed=true&includeTasks=true'
call workflow_resume PUT "/api/workflow/$life_id/resume"
call workflow_get_resumed GET "/api/workflow/$life_id"

# skiptask on a workflow with a correlation ID and a priority.
call workflow_start_skip POST '/api/workflow/archon_ops?correlationId=archon-ops-skip&priority=7' '{"x": 3}'
skip_id="$(body)"
call workflow_get_skip GET "/api/workflow/$skip_id"
skip_a="$(task_id ops_a_ref)"
call workflow_skiptask PUT "/api/workflow/$skip_id/skiptask/ops_b_ref" \
  '{"taskInput": {"ignored": true}, "taskOutput": {"ignored": true}}'
call workflow_get_skipped GET "/api/workflow/$skip_id"
call workflow_skiptask_again PUT "/api/workflow/$skip_id/skiptask/ops_b_ref"
call workflow_tasks_skipped GET "/api/workflow/$skip_id/tasks?status=SKIPPED"
call task_update_skip_a POST /api/tasks "$(task_result "$skip_id" "$skip_a" COMPLETED '{"y": 3}')"
wait_status "$skip_id" COMPLETED
call workflow_get_skip_completed GET "/api/workflow/$skip_id"

# resetcallbacks: a worker postpones its task for an hour.
call workflow_start_callback POST /api/workflow/archon_ops_callback '{}'
callback_id="$(body)"
poll_until task_poll_callback archon_ops_cb
call task_update_callback POST /api/tasks \
  "$(jq -nc --arg w "$callback_id" --arg t "$(body | jq -r .taskId)" --arg worker "$WORKER" \
     '{workflowInstanceId: $w, taskId: $t, status: "IN_PROGRESS", workerId: $worker,
       callbackAfterSeconds: 3600, outputData: {}}')"
call workflow_get_callback GET "/api/workflow/$callback_id"
call task_poll_callback_postponed GET "/api/tasks/poll/archon_ops_cb?workerid=$WORKER"
call workflow_resetcallbacks POST "/api/workflow/$callback_id/resetcallbacks"
call workflow_get_callback_reset GET "/api/workflow/$callback_id"
call task_poll_callback_reset GET "/api/tasks/poll/archon_ops_cb?workerid=$WORKER"

# retry and restart.
call workflow_start_retry POST /api/workflow/archon_ops '{"x": 4}'
retry_id="$(body)"
call workflow_get_retry GET "/api/workflow/$retry_id"
call task_update_retry_a POST /api/tasks \
  "$(task_result "$retry_id" "$(task_id ops_a_ref)" FAILED '{}')"
wait_status "$retry_id" FAILED
call workflow_get_retry_failed GET "/api/workflow/$retry_id"
call workflow_retry POST "/api/workflow/$retry_id/retry"
call workflow_get_retried GET "/api/workflow/$retry_id"
call workflow_start_restart POST /api/workflow/archon_ops '{"x": 5}'
restart_id="$(body)"
call workflow_terminate_restart DELETE "/api/workflow/$restart_id?reason=archon-restart"
call workflow_restart POST "/api/workflow/$restart_id/restart"
call workflow_get_restarted GET "/api/workflow/$restart_id"
call workflow_terminate_restarted DELETE "/api/workflow/$restart_id"
call workflow_restart_latest POST "/api/workflow/$restart_id/restart?useLatestDefinitions=true"
call workflow_get_restarted_latest GET "/api/workflow/$restart_id"

# rerun: from a task of the workflow, from the start, from its SUB_WORKFLOW, from a child's task.
call workflow_start_rerun POST '/api/workflow/archon_ops?correlationId=archon-ops-rerun' '{"x": 6}'
rerun_id="$(body)"
call workflow_get_rerun GET "/api/workflow/$rerun_id"
rerun_a="$(task_id ops_a_ref)"
call task_update_rerun_a POST /api/tasks "$(task_result "$rerun_id" "$rerun_a" COMPLETED '{"y": 6}')"
call_until workflow_get_rerun_b GET "/api/workflow/$rerun_id" '(.tasks | length) == 2'
call task_update_rerun_b POST /api/tasks \
  "$(task_result "$rerun_id" "$(task_id ops_b_ref)" COMPLETED '{"z": 6}')"
wait_status "$rerun_id" COMPLETED
call workflow_rerun_from_task POST "/api/workflow/$rerun_id/rerun" \
  "{\"reRunFromTaskId\": \"$rerun_a\", \"taskInput\": {\"x\": 60}}"
call workflow_get_rerun_from_task GET "/api/workflow/$rerun_id"
call workflow_terminate_rerun DELETE "/api/workflow/$rerun_id"
call workflow_rerun POST "/api/workflow/$rerun_id/rerun" \
  '{"workflowInput": {"x": 61}, "correlationId": "archon-ops-rerun-2"}'
call workflow_get_rerun_whole GET "/api/workflow/$rerun_id"

call workflow_start_parent POST /api/workflow/archon_ops_parent '{}'
parent_id="$(body)"
call_until workflow_get_parent GET "/api/workflow/$parent_id" '.tasks[0].subWorkflowId != null'
parent_sub="$(task_id parent_sub_ref)"
call_until workflow_get_parent_child GET "/api/workflow/$(child_id parent_sub_ref)" \
  '(.tasks | length) == 1'
call task_update_parent_child POST /api/tasks \
  "$(task_result "$(body | jq -r .workflowId)" "$(task_id child_c_ref)" FAILED '{}')"
wait_status "$parent_id" FAILED
call workflow_rerun_sub_workflow POST "/api/workflow/$parent_id/rerun" \
  "{\"reRunFromTaskId\": \"$parent_sub\", \"taskInput\": {\"ignored\": true}}"
# The rerun clears the task's child ID: the one that appears is the new child's.
call_until workflow_get_rerun_sub_workflow GET "/api/workflow/$parent_id" '.tasks[0].subWorkflowId != null'
call_until workflow_get_rerun_new_child GET "/api/workflow/$(child_id parent_sub_ref)" \
  '(.tasks | length) == 1'
call task_update_rerun_new_child POST /api/tasks \
  "$(task_result "$(body | jq -r .workflowId)" "$(task_id child_c_ref)" FAILED '{}')"
wait_status "$parent_id" FAILED
call workflow_rerun_child_task POST "/api/workflow/$parent_id/rerun" \
  "{\"reRunFromTaskId\": \"$(fixture_body workflow_get_rerun_new_child | jq -r '.tasks[0].taskId')\",
    \"taskInput\": {\"c\": 1}, \"workflowInput\": {\"p\": 1}}"
call workflow_get_rerun_child_parent GET "/api/workflow/$parent_id"
call workflow_get_rerun_child GET "/api/workflow/$(child_id parent_sub_ref)"

# A task in the first child of a retried SUB_WORKFLOW, two levels down (top, mid, child).
call workflow_start_top POST /api/workflow/archon_ops_top '{}'
top_id="$(body)"
call_until workflow_get_top GET "/api/workflow/$top_id" '.tasks[0].subWorkflowId != null'
mid_id="$(child_id top_sub_ref)"
call_until workflow_get_mid GET "/api/workflow/$mid_id" '.tasks[0].subWorkflowId != null'
child1_id="$(child_id mid_sub_ref)"
call_until workflow_get_child_first GET "/api/workflow/$child1_id" '(.tasks | length) == 1'
child1_task="$(task_id child_c_ref)"
call task_update_child_first POST /api/tasks "$(task_result "$child1_id" "$child1_task" FAILED '{}')"
call_until workflow_get_mid_retried GET "/api/workflow/$mid_id" \
  '(.tasks | length) == 2 and .tasks[1].subWorkflowId != null'
child2_id="$(child_id mid_sub_ref 1)"
call_until workflow_get_child_second GET "/api/workflow/$child2_id" '(.tasks | length) == 1'
call task_update_child_second POST /api/tasks \
  "$(task_result "$child2_id" "$(task_id child_c_ref)" FAILED '{}')"
wait_status "$top_id" FAILED
call workflow_get_mid_failed GET "/api/workflow/$mid_id"
call workflow_get_top_failed GET "/api/workflow/$top_id"
call workflow_rerun_retried_child POST "/api/workflow/$top_id/rerun" \
  "{\"reRunFromTaskId\": \"$child1_task\", \"workflowInput\": {\"t\": 1}}"
# Upstream's answer: the mid workflow decides again, finds its second attempt FAILED with no
# retry left and fails, terminating the first child; the top workflow stays RUNNING.
call workflow_get_rerun_top GET "/api/workflow/$top_id"
call_until workflow_get_rerun_mid GET "/api/workflow/$mid_id" '.status == "FAILED"'
call_until workflow_get_rerun_child_first GET "/api/workflow/$child1_id" '.status == "TERMINATED"'

# remove and terminate-remove.
call workflow_start_remove POST /api/workflow/archon_ops '{"x": 7}'
remove_id="$(body)"
call workflow_get_remove GET "/api/workflow/$remove_id"
call task_update_remove_a POST /api/tasks \
  "$(task_result "$remove_id" "$(task_id ops_a_ref)" FAILED '{}')"
wait_status "$remove_id" FAILED
call workflow_remove DELETE "/api/workflow/$remove_id/remove"
call workflow_get_removed GET "/api/workflow/$remove_id"
call workflow_remove_removed DELETE "/api/workflow/$remove_id/remove"
call workflow_start_remove_running POST /api/workflow/archon_ops '{"x": 8}'
call workflow_remove_no_archive DELETE "/api/workflow/$(body)/remove?archiveWorkflow=false"
call workflow_get_removed_running GET "/api/workflow/$(fixture_body workflow_start_remove_running)"
call workflow_start_terminate_remove POST /api/workflow/archon_ops '{"x": 9}'
call workflow_terminate_remove DELETE "/api/workflow/$(body)/terminate-remove?reason=archon-terminate-remove"
call workflow_get_terminate_removed GET "/api/workflow/$(fixture_body workflow_start_terminate_remove)"

# bulk: limits, mixed results, terminate-remove of a COMPLETED workflow.
call workflow_bulk_pause_empty PUT /api/workflow/bulk/pause '[]'
call workflow_bulk_pause_too_many PUT /api/workflow/bulk/pause \
  "$(jq -nc '[range(1001) | "archon-bulk-\(.)"]')"
call workflow_bulk_pause_null_body PUT /api/workflow/bulk/pause ''
call workflow_start_bulk_1 POST /api/workflow/archon_ops '{"x": 10}'
bulk_1="$(body)"
call workflow_start_bulk_2 POST /api/workflow/archon_ops '{"x": 11}'
bulk_2="$(body)"
call workflow_bulk_pause PUT /api/workflow/bulk/pause "[\"$bulk_1\", \"$bulk_2\", \"$missing\"]"
call workflow_bulk_pause_single PUT /api/workflow/bulk/pause "\"$bulk_1\""
call workflow_bulk_resume PUT /api/workflow/bulk/resume "[\"$bulk_1\", \"$completed_id\"]"
call workflow_bulk_terminate POST '/api/workflow/bulk/terminate?reason=archon-bulk' \
  "[\"$bulk_1\", \"$completed_id\", \"$missing\"]"
call workflow_bulk_retry POST /api/workflow/bulk/retry "[\"$bulk_1\", \"$bulk_2\"]"
call workflow_bulk_restart POST '/api/workflow/bulk/restart?useLatestDefinitions=true' \
  "[\"$completed_id\", \"$bulk_2\", \"$missing\"]"
call workflow_get_bulk_restarted GET "/api/workflow/$completed_id?includeTasks=false"
call workflow_bulk_remove DELETE '/api/workflow/bulk/remove?archiveWorkflow=false' \
  "[\"$bulk_1\", \"$missing\"]"
call workflow_get_bulk_removed GET "/api/workflow/$bulk_1"
call workflow_get_bulk_terminate_remove GET "/api/workflow/$(fixture_body workflow_start_ref)?includeTasks=false"
call workflow_bulk_terminate_remove DELETE '/api/workflow/bulk/terminate-remove?reason=archon-bulk' \
  "[\"$bulk_2\", \"$(fixture_body workflow_start_ref)\", \"$missing\"]"
call workflow_get_bulk_terminate_removed GET "/api/workflow/$(fixture_body workflow_start_ref)"

# Deleting definitions last.
call metadata_delete_workflow DELETE /api/metadata/workflow/archon_ops/2
call metadata_get_workflow_deleted GET '/api/metadata/workflow/archon_ops?version=2'
call metadata_get_workflow_after_delete GET /api/metadata/workflow/archon_ops
call metadata_delete_taskdef DELETE /api/metadata/taskdefs/archon_ops_idle
call metadata_get_taskdef_deleted GET /api/metadata/taskdefs/archon_ops_idle
