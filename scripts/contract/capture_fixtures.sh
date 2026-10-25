#!/usr/bin/env bash
# Captures golden request/response fixtures from a running upstream Conductor OSS server.
#
# Usage: BASE_URL=http://localhost:8080 scripts/contract/capture_fixtures.sh [out_dir]
#
# The server must start empty (fresh SQLite file). Each exchange is written as one JSON file:
#   {"request": {"method", "path", "body"}, "response": {"status", "content_type", "body"}}
# JSON response bodies are stored parsed, text/plain bodies as strings, empty bodies as null.
# Fixtures are written verbatim except that the server hostname in error bodies is redacted;
# volatile fields are documented in test/fixtures/contract/README.md.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
OUT="${1:-test/fixtures/contract}"
WORKER="archon-contract"
mkdir -p "$OUT"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# call NAME METHOD PATH [BODY_JSON]
# Writes $OUT/NAME.json and leaves the response body in $tmp/body, status in $tmp/status.
call() {
  local name="$1" method="$2" path="$3" body="${4:-}"
  local args=(-sS -X "$method" -o "$tmp/body" -D "$tmp/headers" -w '%{http_code}')
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  curl "${args[@]}" "$BASE_URL$path" >"$tmp/status"

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
    --argjson req_body "${body:-null}" \
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
