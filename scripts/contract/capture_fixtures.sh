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
