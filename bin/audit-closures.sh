#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

VERSION="2026.05.24-a4"
ENV_FILE="${PAPERCLIP_AUDIT_ENV:-/etc/paperclip-substrate/audit.env}"
DEFAULT_PAPERCLIP_API_URL="http://100.89.115.103:3210"
DEFAULT_PAPERCLIP_COMPANY_ID="e26a9f74-9e85-43a1-af55-c4db68bd40eb"
TERMINAL_CLOSE_STATUS="cancelled"
ISSUE_LIMIT="${AUDIT_ISSUE_LIMIT:-500}"
TMP_FILES=()

dry_run_arg=0
dry_run=0
since_iso=""
until_iso=""
issue_id=""
agents_file=""
scanned_count=0
flagged_count=0
reopened_count=0

# Deployment notes:
# - This Paperclip box uses "cancelled" + cancelledAt as the close state; it does
#   not use "done". Extend TERMINAL_CLOSE_STATUS if upstream adds other terminal
#   close states.
# - Closing actor identity is not present on the issue. It comes from the latest
#   issue.updated activity where details.status == "cancelled".
# - Agent closes with runId=null have no heartbeat transcript and are therefore
#   evidence-less by definition.
# - The CEO dedupe carve-out is narrowed here to explicit duplicate text. The
#   canonical "cancelled instead of done" leg would exempt every CEO close on
#   this deployment because all closes use "cancelled".

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat <<'USAGE'
usage: audit-closures.sh [--dry-run] [--since ISO] [--until ISO] [--issue ISSUE_ID]

Audits Paperclip agent closures for tool-output evidence. By default it scans
agent-closed issues in the last AUDIT_WINDOW_HOURS hours and re-opens closures
that lack evidence. Use --dry-run to report without mutating Paperclip state.

Options:
  --dry-run          Print "would re-open" reports; do not PATCH issues.
  --since ISO        Inclusive lower bound, e.g. 2026-05-22T00:00:00Z.
  --until ISO        Exclusive upper bound, e.g. 2026-05-23T00:00:00Z.
  --issue ISSUE_ID   Audit one issue id instead of listing company issues.
  --help             Show this help.

Environment:
  PAPERCLIP_AUDIT_ENV       Env file path; default /etc/paperclip-substrate/audit.env.
  PAPERCLIP_API_URL         Default http://100.89.115.103:3210.
  PAPERCLIP_AUDIT_API_KEY   Dedicated Auditor agent bearer token.
  PAPERCLIP_COMPANY_ID      Default e26a9f74-9e85-43a1-af55-c4db68bd40eb.
  AUDIT_DRY_RUN_DEFAULT     true/false; default false.
  AUDIT_WINDOW_HOURS        Default 24.
  AUDIT_STATE_DIR           Default /var/lib/paperclip-audit.

Exit codes:
  0  Scan completed and no re-opens were needed.
  1  At least one issue was re-opened or would be re-opened.
  2  Script or API error.
USAGE
}

cleanup() {
  local file

  for file in "${TMP_FILES[@]}"; do
    rm -f -- "$file"
  done
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

tmp_file() {
  local file

  file="$(mktemp "${TMPDIR:-/tmp}/paperclip-audit.XXXXXX")"
  TMP_FILES+=("$file")
  printf '%s\n' "$file"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run_arg=1
        shift
        ;;
      --since)
        [[ $# -ge 2 ]] || die "--since requires an ISO timestamp"
        since_iso="$2"
        shift 2
        ;;
      --until)
        [[ $# -ge 2 ]] || die "--until requires an ISO timestamp"
        until_iso="$2"
        shift 2
        ;;
      --issue)
        [[ $# -ge 2 ]] || die "--issue requires an issue id"
        issue_id="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

truthy() {
  case "$(lower "$1")" in
    1|true|yes|y|on)
      return 0
      ;;
    0|false|no|n|off|'')
      return 1
      ;;
    *)
      die "invalid boolean value: $1"
      ;;
  esac
}

load_env() {
  if [[ -r "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
  elif [[ -z "${PAPERCLIP_AUDIT_API_KEY:-}" ]]; then
    die "missing readable env file: ${ENV_FILE}; create it from etc/audit.env.example or set PAPERCLIP_AUDIT_API_KEY"
  fi

  PAPERCLIP_API_URL="${PAPERCLIP_API_URL:-$DEFAULT_PAPERCLIP_API_URL}"
  PAPERCLIP_API_URL="${PAPERCLIP_API_URL%/}"
  PAPERCLIP_COMPANY_ID="${PAPERCLIP_COMPANY_ID:-$DEFAULT_PAPERCLIP_COMPANY_ID}"
  AUDIT_DRY_RUN_DEFAULT="${AUDIT_DRY_RUN_DEFAULT:-false}"
  AUDIT_WINDOW_HOURS="${AUDIT_WINDOW_HOURS:-24}"
  AUDIT_STATE_DIR="${AUDIT_STATE_DIR:-/var/lib/paperclip-audit}"

  [[ -n "${PAPERCLIP_API_URL:-}" ]] || die "PAPERCLIP_API_URL is required"
  [[ -n "${PAPERCLIP_COMPANY_ID:-}" ]] || die "PAPERCLIP_COMPANY_ID is required"
  [[ "$PAPERCLIP_COMPANY_ID" =~ ^[A-Za-z0-9-]+$ ]] || die "PAPERCLIP_COMPANY_ID must be an id, not a path"
  [[ "$AUDIT_WINDOW_HOURS" =~ ^[0-9]+$ ]] || die "AUDIT_WINDOW_HOURS must be numeric"

  if [[ -z "${PAPERCLIP_AUDIT_API_KEY:-}" || "${PAPERCLIP_AUDIT_API_KEY:-}" == "<paste here>" ]]; then
    die "PAPERCLIP_AUDIT_API_KEY is missing in ${ENV_FILE}; provision the dedicated Auditor agent key first"
  fi

  if [[ "$dry_run_arg" -eq 1 ]] || truthy "$AUDIT_DRY_RUN_DEFAULT"; then
    dry_run=1
  else
    dry_run=0
  fi
}

default_since() {
  if date -u -d "${AUDIT_WINDOW_HOURS} hours ago" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -d "${AUDIT_WINDOW_HOURS} hours ago" '+%Y-%m-%dT%H:%M:%SZ'
    return
  fi

  if date -u -v-"${AUDIT_WINDOW_HOURS}"H '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -v-"${AUDIT_WINDOW_HOURS}"H '+%Y-%m-%dT%H:%M:%SZ'
    return
  fi

  die "date does not support GNU -d or BSD -v hour arithmetic"
}

normalize_iso_epoch() {
  local value="$1"

  jq -nr --arg ts "$value" '
    def epoch:
      sub("\\.[0-9]+Z$"; "Z")
      | fromdateiso8601;
    $ts | epoch
  ' 2>/dev/null || die "invalid ISO timestamp: $value"
}

configure_window() {
  local since_epoch
  local until_epoch

  if [[ -z "$until_iso" ]]; then
    until_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi

  if [[ -z "$since_iso" ]]; then
    since_iso="$(default_since)"
  fi

  since_epoch="$(normalize_iso_epoch "$since_iso")"
  until_epoch="$(normalize_iso_epoch "$until_iso")"

  [[ "$since_epoch" -lt "$until_epoch" ]] || die "--since must be earlier than --until"
}

timestamp_in_window() {
  local timestamp="$1"
  local result

  result="$(jq -nr \
    --arg ts "$timestamp" \
    --arg since "$since_iso" \
    --arg until "$until_iso" '
      def epoch:
        sub("\\.[0-9]+Z$"; "Z")
        | fromdateiso8601;
      ($ts | epoch) as $t
      | ($since | epoch) as $s
      | ($until | epoch) as $u
      | ($t >= $s and $t < $u)
    ' 2>/dev/null)" || die "invalid activity timestamp: $timestamp"

  [[ "$result" == "true" ]]
}

api_get() {
  local path="$1"
  local out_file="$2"
  local http_status

  http_status="$(curl -sS \
    -o "$out_file" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${PAPERCLIP_AUDIT_API_KEY}" \
    -H "Accept: application/json" \
    "${PAPERCLIP_API_URL}${path}")" \
    || die "Paperclip GET failed: $path"

  case "$http_status" in
    2*)
      ;;
    401|403)
      die "Paperclip GET ${path} returned HTTP ${http_status}; check PAPERCLIP_AUDIT_API_KEY"
      ;;
    *)
      die "Paperclip GET ${path} returned HTTP ${http_status}"
      ;;
  esac

  jq -e . "$out_file" >/dev/null || die "Paperclip GET ${path} returned unparseable JSON"
}

api_patch_json() {
  local path="$1"
  local body_file="$2"
  local out_file="$3"
  local http_status

  http_status="$(curl -sS \
    -o "$out_file" \
    -w '%{http_code}' \
    -X PATCH \
    -H "Authorization: Bearer ${PAPERCLIP_AUDIT_API_KEY}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data-binary "@${body_file}" \
    "${PAPERCLIP_API_URL}${path}")" \
    || die "Paperclip PATCH failed: $path"

  case "$http_status" in
    2*)
      ;;
    401|403)
      die "Paperclip PATCH ${path} returned HTTP ${http_status}; check PAPERCLIP_AUDIT_API_KEY permissions"
      ;;
    *)
      die "Paperclip PATCH ${path} returned HTTP ${http_status}"
      ;;
  esac

  if [[ -s "$out_file" ]]; then
    jq -e . "$out_file" >/dev/null || die "Paperclip PATCH ${path} returned unparseable JSON"
  fi
}

normalize_issue() {
  local in_file="$1"
  local out_file="$2"

  jq 'if type == "object" and has("issue") then .issue else . end' "$in_file" > "$out_file"
}

issue_array_filter() {
  jq -r '
    def items:
      if type == "array" then .
      elif type == "object" and (.issues | type) == "array" then .issues
      elif type == "object" and (.data | type) == "array" then .data
      else []
      end;
    items[] | .id // empty
  '
}

activity_close_filter() {
  jq -c --arg status "$TERMINAL_CLOSE_STATUS" '
    def events:
      if type == "array" then .
      elif type == "object" and (.activity | type) == "array" then .activity
      elif type == "object" and (.events | type) == "array" then .events
      elif type == "object" and (.data | type) == "array" then .data
      else []
      end;
    [
      events[]
      | select(.action == "issue.updated")
      | select((.details.status // .details.newStatus // .details.toStatus // "") == $status)
    ]
    | sort_by(.createdAt // "")
    | last // empty
  '
}

agent_role() {
  local agent_id="$1"

  jq -r --arg id "$agent_id" '
    def agents:
      if type == "array" then .
      elif type == "object" and (.agents | type) == "array" then .agents
      elif type == "object" and (.data | type) == "array" then .data
      else []
      end;
    [
      agents[]
      | select((.id // .agentId // "") == $id)
      | (.role // .agentRole // "")
    ][0] // ""
  ' "$agents_file"
}

comments_latest_text() {
  local comments_file="$1"

  jq -r '
    def comments:
      if type == "array" then .
      elif type == "object" and (.comments | type) == "array" then .comments
      elif type == "object" and (.data | type) == "array" then .data
      else []
      end;
    [comments[] | (.body // .text // .comment // "")] | last // ""
  ' "$comments_file"
}

comments_all_text() {
  local comments_file="$1"

  jq -r '
    def comments:
      if type == "array" then .
      elif type == "object" and (.comments | type) == "array" then .comments
      elif type == "object" and (.data | type) == "array" then .data
      else []
      end;
    [comments[] | (.body // .text // .comment // "")] | join("\n")
  ' "$comments_file"
}

issue_reference_text() {
  local issue_file="$1"

  jq -r '
    [
      .identifier // "",
      .title // "",
      .description // "",
      .body // "",
      .content // ""
    ] | join("\n")
  ' "$issue_file"
}

is_ceo_duplicate_exempt() {
  local role="$1"
  local issue_file="$2"
  local comments_file="$3"
  local closing_json="$4"
  local latest_comment
  local issue_text

  [[ "$(lower "$role")" == "ceo" ]] || return 1

  latest_comment="$(comments_latest_text "$comments_file")"
  issue_text="$(issue_reference_text "$issue_file")"

  jq -en \
    --arg text "${latest_comment}"$'\n'"${issue_text}"$'\n'"${closing_json}" '
      $text | test("duplicate of #?\\d+"; "i")
    ' >/dev/null
}

existing_audit_comment() {
  local comments_file="$1"
  local run_display="$2"
  local closed_at="$3"
  local comments_text

  comments_text="$(comments_all_text "$comments_file")"
  jq -en --arg text "$comments_text" --arg run "$run_display" --arg closedAt "$closed_at" '
    ($text | contains("Auto-reopened by audit-closures"))
    and ($text | contains("run " + $run))
    and (if $run == "null" then ($text | contains($closedAt)) else true end)
  ' >/dev/null
}

detect_evidence() {
  local issue_file="$1"
  local events_file="$2"
  local close_text="$3"

  jq -n \
    --slurpfile issue "$issue_file" \
    --slurpfile events "$events_file" \
    --arg close_text "$close_text" '
      def strings_join: [.. | strings] | join("\n");
      def norm_events:
        $events[0]
        | if type == "array" then .
          elif type == "object" and (.events | type) == "array" then .events
          elif type == "object" and (.data | type) == "array" then .data
          else []
          end;
      def issue_text: ($issue[0] | strings_join);
      def common_words: [
        "agent", "blocked", "cancelled", "closed", "doing", "duplicate",
        "error", "issue", "paperclip", "status", "todo", "triage"
      ];
      def strong_refs:
        [
          issue_text | scan("[A-Za-z0-9._/-]+\\.[A-Za-z0-9][A-Za-z0-9._/-]*"),
          issue_text | scan("CVE-[0-9]{4}-[0-9]{4,}"),
          issue_text | scan("[A-Fa-f0-9]{7,40}"),
          issue_text | scan("[A-Za-z0-9][A-Za-z0-9._-]{5,}")
        ]
        | flatten
        | map(select(length >= 4))
        | map(select((ascii_downcase as $word | common_words | index($word) | not)))
        | unique;
      def mentions_ref($text):
        (strong_refs | length == 0)
        or any(strong_refs[]; ($text | ascii_downcase | contains(. | ascii_downcase)));
      def has_output_key($event):
        any($event | .. | objects | keys_unsorted[]?;
          ascii_downcase | test("^(output|stdout|stderr|result|results|exitcode|exit_code|logs?)$"));
      def event_text($event): ($event | strings_join);
      def search_cmd($text):
        $text | test("(^|[^A-Za-z0-9_-])(rg|grep|git[[:space:]]+grep|ripgrep|ag)([^A-Za-z0-9_-]|$)"; "i");
      def read_cmd($text):
        $text | test("(^|[^A-Za-z0-9_-])(cat|sed|awk|head|tail|less|read_file|open_file|view)([^A-Za-z0-9_-]|$)"; "i");
      def git_cmd($text):
        $text | test("git[[:space:]]+(show|log|blame|diff)([[:space:]]|$)"; "i");
      {
        refs: strong_refs,
        output_keys_present: any(norm_events[]; has_output_key(.)),
        grep_calls: ([norm_events[] | event_text(.) as $text | select(search_cmd($text) and mentions_ref($text))] | length),
        file_read_calls: ([norm_events[] | event_text(.) as $text | select(read_cmd($text) and mentions_ref($text))] | length),
        git_evidence_calls: ([norm_events[] | event_text(.) as $text | select(git_cmd($text) and mentions_ref($text))] | length),
        verified_no_change_tag: ($close_text | test("\\[VERIFIED-NO-CHANGE\\]"; "i"))
      } as $result
      | $result
      | .tool_evidence = (.output_keys_present and ((.grep_calls + .file_read_calls + .git_evidence_calls) > 0))
      | .has_evidence = .tool_evidence
      | .reason = (
          if .has_evidence then
            "tool evidence present: grep=\(.grep_calls), file_read=\(.file_read_calls), git=\(.git_evidence_calls)"
          elif .verified_no_change_tag then
            "[VERIFIED-NO-CHANGE] tag present but no paired grep/cat/read/git evidence"
          else
            "0 grep/cat/read/git evidence calls in the run transcript"
          end
        )
    '
}

state_file_for() {
  local issue="$1"
  local run="$2"
  local closed_at="$3"
  local key
  local hash_output
  local hash

  key="${issue}|${run}|${closed_at}"
  hash_output="$(printf '%s' "$key" | openssl dgst -sha256 -r)"
  hash="${hash_output%% *}"

  printf '%s/%s.json\n' "$AUDIT_STATE_DIR" "$hash"
}

ensure_state_dir() {
  if [[ ! -d "$AUDIT_STATE_DIR" ]]; then
    mkdir -p "$AUDIT_STATE_DIR"
  fi

  [[ -w "$AUDIT_STATE_DIR" ]] || die "AUDIT_STATE_DIR is not writable: $AUDIT_STATE_DIR"
}

write_state() {
  local state_file="$1"
  local issue="$2"
  local run="$3"
  local closed_at="$4"
  local reason="$5"
  local tmp

  ensure_state_dir
  tmp="$(mktemp "${AUDIT_STATE_DIR}/audit-state.XXXXXX")"
  TMP_FILES+=("$tmp")

  jq -n \
    --arg issueId "$issue" \
    --arg runId "$run" \
    --arg closedAt "$closed_at" \
    --arg reason "$reason" \
    --arg auditedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{
      issueId: $issueId,
      runId: $runId,
      closedAt: $closedAt,
      reason: $reason,
      auditedAt: $auditedAt
    }' > "$tmp"

  mv -f -- "$tmp" "$state_file"
}

build_reopen_comment() {
  local run_display="$1"
  local reason="$2"

  cat <<EOF
🚨 Auto-reopened by audit-closures (run ${run_display}, audit-script v${VERSION}).

This closure lacked tool-output evidence supporting the verdict. Per the anti-fabrication contract in the CTO/engineer prompts, codebase claims must be backed by tool output in the same run that produced the close.

Audit found: ${reason}

For humans to review: was this a legitimate verified-no-change close, or a fabrication? If legit, post a comment with the verifying tool output and re-close. If fabrication, the agent's instructions need review.
EOF
}

reopen_issue() {
  local issue="$1"
  local run_display="$2"
  local reason="$3"
  local body_file
  local response_file
  local comment

  body_file="$(tmp_file)"
  response_file="$(tmp_file)"
  comment="$(build_reopen_comment "$run_display" "$reason")"

  jq -n --arg comment "$comment" '{restore: true, comment: $comment}' > "$body_file"
  api_patch_json "/api/issues/${issue}" "$body_file" "$response_file"
}

issue_label() {
  local issue_file="$1"

  jq -r '.identifier // .number // .id // "unknown"' "$issue_file"
}

flag_issue() {
  local issue="$1"
  local label="$2"
  local run_display="$3"
  local closed_at="$4"
  local reason="$5"
  local state_file="$6"

  ((flagged_count += 1))

  if [[ "$dry_run" -eq 1 ]]; then
    printf 'would re-open %s (%s): %s\n' "$label" "$issue" "$reason"
    return
  fi

  reopen_issue "$issue" "$run_display" "$reason"
  write_state "$state_file" "$issue" "$run_display" "$closed_at" "$reason"
  ((reopened_count += 1))
  printf 're-opened %s (%s): %s\n' "$label" "$issue" "$reason"
}

audit_issue() {
  local id="$1"
  local issue_raw
  local issue_file
  local activity_file
  local comments_file
  local closing_json
  local current_status
  local closed_at
  local actor_type
  local actor_agent_id
  local role
  local run_id
  local run_display
  local label
  local state_file
  local latest_comment
  local issue_text
  local close_text
  local events_file
  local evidence_json
  local has_evidence
  local reason

  [[ "$id" =~ ^[A-Za-z0-9-]+$ ]] || die "invalid issue id: $id"

  issue_raw="$(tmp_file)"
  issue_file="$(tmp_file)"
  activity_file="$(tmp_file)"
  comments_file="$(tmp_file)"

  api_get "/api/issues/${id}" "$issue_raw"
  normalize_issue "$issue_raw" "$issue_file"

  current_status="$(jq -r '.status // ""' "$issue_file")"
  [[ "$current_status" == "$TERMINAL_CLOSE_STATUS" ]] || return 0

  api_get "/api/issues/${id}/activity" "$activity_file"
  closing_json="$(activity_close_filter < "$activity_file")"
  [[ -n "$closing_json" ]] || return 0

  closed_at="$(printf '%s' "$closing_json" | jq -r '.createdAt // ""')"
  [[ -n "$closed_at" ]] || die "closing activity for issue ${id} has no createdAt"
  timestamp_in_window "$closed_at" || return 0

  ((scanned_count += 1))

  actor_type="$(printf '%s' "$closing_json" | jq -r '.actorType // ""')"
  [[ "$actor_type" == "user" ]] && return 0

  actor_agent_id="$(printf '%s' "$closing_json" | jq -r '.agentId // (if .actorType == "agent" then .actorId else empty end) // ""')"
  [[ -n "$actor_agent_id" ]] || die "closing activity for issue ${id} lacks agent identity"

  role="$(agent_role "$actor_agent_id")"

  api_get "/api/issues/${id}/comments?order=asc&limit=100" "$comments_file"

  if is_ceo_duplicate_exempt "$role" "$issue_file" "$comments_file" "$closing_json"; then
    return 0
  fi

  run_id="$(printf '%s' "$closing_json" | jq -r '.runId // ""')"
  if [[ -n "$run_id" ]]; then
    run_display="$run_id"
  else
    run_display="null"
  fi

  state_file="$(state_file_for "$id" "$run_display" "$closed_at")"
  if [[ "$dry_run" -eq 0 && -f "$state_file" ]]; then
    return 0
  fi

  if existing_audit_comment "$comments_file" "$run_display" "$closed_at"; then
    if [[ "$dry_run" -eq 0 ]]; then
      write_state "$state_file" "$id" "$run_display" "$closed_at" "audit comment already present"
    fi
    return 0
  fi

  label="$(issue_label "$issue_file")"

  if [[ -z "$run_id" ]]; then
    reason="closing activity at ${closed_at} had runId=null; no heartbeat transcript exists"
    flag_issue "$id" "$label" "$run_display" "$closed_at" "$reason" "$state_file"
    return
  fi

  events_file="$(tmp_file)"
  api_get "/api/heartbeat-runs/${run_id}/events" "$events_file"

  latest_comment="$(comments_latest_text "$comments_file")"
  issue_text="$(issue_reference_text "$issue_file")"
  close_text="${latest_comment}"$'\n'"${issue_text}"$'\n'"${closing_json}"
  evidence_json="$(detect_evidence "$issue_file" "$events_file" "$close_text")"
  has_evidence="$(printf '%s' "$evidence_json" | jq -r '.has_evidence')"

  if [[ "$has_evidence" == "true" ]]; then
    return 0
  fi

  reason="$(printf '%s' "$evidence_json" | jq -r '.reason')"
  flag_issue "$id" "$label" "$run_display" "$closed_at" "$reason" "$state_file"
}

list_issue_ids() {
  local list_file

  list_file="$(tmp_file)"
  api_get "/api/companies/${PAPERCLIP_COMPANY_ID}/issues?status=${TERMINAL_CLOSE_STATUS}&limit=${ISSUE_LIMIT}" "$list_file"
  issue_array_filter < "$list_file"
}

load_agents() {
  agents_file="$(tmp_file)"
  api_get "/api/companies/${PAPERCLIP_COMPANY_ID}/agents" "$agents_file"
}

main() {
  local id

  parse_args "$@"

  require_cmd curl
  require_cmd jq
  require_cmd openssl
  require_cmd date
  require_cmd mktemp

  load_env
  configure_window
  load_agents

  if [[ "$dry_run" -eq 0 ]]; then
    ensure_state_dir
  fi

  if [[ -n "$issue_id" ]]; then
    audit_issue "$issue_id"
  else
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      audit_issue "$id"
    done < <(list_issue_ids)
  fi

  printf 'audit complete: scanned=%d flagged=%d reopened=%d dry_run=%s window=[%s,%s)\n' \
    "$scanned_count" "$flagged_count" "$reopened_count" "$dry_run" "$since_iso" "$until_iso"

  if [[ "$flagged_count" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
