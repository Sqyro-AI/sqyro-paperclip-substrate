# Paperclip Closure Audit API Reference

This document records the Paperclip API contract used by `bin/audit-closures.sh`.
It is based on live probing of the Sqyro Paperclip box at `100.89.115.103:3210`
on 2026-05-24. No mutating probe was performed; the only write shape verified was
a validation failure for an invalid re-open payload.

## Connection

Default base URL:

```text
http://100.89.115.103:3210
```

Authentication:

```http
Authorization: Bearer pcp_<redacted>
Accept: application/json
```

The substrate reads these values from `/etc/paperclip-substrate/audit.env`:

```sh
PAPERCLIP_API_URL=http://100.89.115.103:3210
PAPERCLIP_AUDIT_API_KEY="<paste here>"
PAPERCLIP_COMPANY_ID=e26a9f74-9e85-43a1-af55-c4db68bd40eb
AUDIT_DRY_RUN_DEFAULT=false
AUDIT_WINDOW_HOURS=24
AUDIT_STATE_DIR=/var/lib/paperclip-audit
```

## Routes

### List Issues

```http
GET /api/companies/{companyId}/issues?status=cancelled&limit=500
```

Example response shape:

```json
[
  {
    "id": "f308ee59-dec2-4c7a-b591-a19693e7f41a",
    "identifier": "SQY-8",
    "status": "cancelled",
    "title": "Investigate dependency exposure",
    "cancelledAt": "2026-05-22T19:05:41.134Z",
    "completedAt": null
  }
]
```

Notes:

- `limit` works; the deployment returned all 190 current issues with a high limit.
- There is no surfaced date filter. The audit script filters close timestamps
  locally after fetching issue activity.
- `status=cancelled` is the terminal close filter for this deployment.

### Get Issue

```http
GET /api/issues/{issueId}
```

Example response shape:

```json
{
  "id": "f308ee59-dec2-4c7a-b591-a19693e7f41a",
  "identifier": "SQY-8",
  "status": "cancelled",
  "title": "Investigate dependency exposure",
  "description": "Check whether libxmljs2 is present.",
  "cancelledAt": "2026-05-22T19:05:41.134Z"
}
```

The issue record does not include `closedBy`, `lastTransitionActor`, or equivalent
actor fields. Use issue activity to identify the closer.

### Get Issue Activity

```http
GET /api/issues/{issueId}/activity
```

Example response shape:

```json
[
  {
    "actorType": "agent",
    "actorId": "adfb98e4-redacted",
    "agentId": "adfb98e4-redacted",
    "action": "issue.updated",
    "runId": null,
    "details": {
      "status": "cancelled"
    },
    "createdAt": "2026-05-22T19:05:41.134Z"
  }
]
```

The audit script uses this predicate to find the closing transition:

```jq
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
  | select((.details.status // .details.newStatus // .details.toStatus // "") == "cancelled")
]
| sort_by(.createdAt // "")
| last // empty
```

Actor extraction:

```jq
.agentId // (if .actorType == "agent" then .actorId else empty end) // ""
```

Human closures are skipped:

```jq
.actorType == "user"
```

### Get Issue Runs

```http
GET /api/issues/{issueId}/runs
```

Example response shape:

```json
[]
```

For the May 22 false-closure sample, this endpoint returned no runs because the
close activity had `runId: null`. The audit script relies on the activity `runId`
instead of this list.

### Get Issue Comments

```http
GET /api/issues/{issueId}/comments?order=asc&limit=100
```

Example response shape:

```json
[
  {
    "id": "comment-redacted",
    "body": "Duplicate of #123.",
    "createdAt": "2026-05-22T18:59:00.000Z",
    "actorType": "agent"
  }
]
```

The latest comment and issue text are used for the CEO duplicate carve-out. Existing
audit comments are also checked as a second idempotency guard.

### Company Activity

```http
GET /api/companies/{companyId}/activity?agentId={agentId}&entityType=issue&entityId={issueId}&limit=500
```

Example response shape:

```json
[
  {
    "entityType": "issue",
    "entityId": "f308ee59-dec2-4c7a-b591-a19693e7f41a",
    "action": "issue.updated",
    "agentId": "adfb98e4-redacted",
    "createdAt": "2026-05-22T19:05:41.134Z"
  }
]
```

This is useful for manual investigations. The v1 audit script does not need it
because per-issue activity has the close actor and `runId`.

### List Heartbeat Runs

```http
GET /api/companies/{companyId}/heartbeat-runs?limit=500
```

Example response shape:

```json
[
  {
    "id": "run-redacted",
    "agentId": "agent-redacted",
    "createdAt": "2026-05-22T18:30:00.000Z",
    "status": "completed"
  }
]
```

This route exists for run browsing. The audit follows the exact `runId` from the
close activity when one exists.

### Get Heartbeat Run

```http
GET /api/heartbeat-runs/{runId}
```

Example response shape:

```json
{
  "id": "run-redacted",
  "agentId": "agent-redacted",
  "status": "completed",
  "createdAt": "2026-05-22T18:30:00.000Z"
}
```

### Get Heartbeat Run Events

```http
GET /api/heartbeat-runs/{runId}/events
```

Example response shape:

```json
[
  {
    "type": "tool_call",
    "name": "shell",
    "input": {
      "cmd": "rg libxmljs2 package.json"
    }
  },
  {
    "type": "tool_result",
    "stdout": "",
    "stderr": "",
    "exitCode": 1
  }
]
```

This is the evidence source when close activity has a non-null `runId`.

### List Agents

```http
GET /api/companies/{companyId}/agents
```

Example response shape:

```json
[
  {
    "id": "adfb98e4-redacted",
    "role": "cto",
    "name": "CTO"
  },
  {
    "id": "ceo-redacted",
    "role": "ceo",
    "name": "CEO"
  }
]
```

The audit maps the closing `agentId` to `role` for the CEO duplicate carve-out.

### Re-open Issue

```http
PATCH /api/issues/{issueId}
Content-Type: application/json

{
  "reopen": true,
  "comment": "Auto-reopened by audit-closures ..."
}
```

Validation enforces a non-empty `comment`. The audit uses this single PATCH for
both the re-open and the audit comment.

### Post Comment Alternative

```http
POST /api/issues/{issueId}/comments
Content-Type: application/json

{
  "body": "Auto-reopened by audit-closures ...",
  "reopen": true
}
```

This route goes through the same agent issue mutation middleware. It is documented
as a fallback shape, but the v1 script uses `PATCH /api/issues/{issueId}`.

## Deployment Surprises

### 1. Terminal Status Is `cancelled`

The canonical brief expected `done`, but this deployment has no `done` issues.
Observed status distribution across 190 issues:

```text
blocked: 37
cancelled: 104
in_progress: 12
todo: 37
```

`completedAt` was empty for all issues sampled; `cancelledAt` is the close timestamp.
The script therefore treats this as the terminal close state:

```sh
TERMINAL_CLOSE_STATUS="cancelled"
```

If upstream Paperclip later adds `done` or another close state, extend this constant
and revisit the CEO carve-out.

### 2. No `closedBy` Field

The issue resource does not expose who closed it. The close actor must be derived
from activity:

```jq
[
  events[]
  | select(.action == "issue.updated")
  | select((.details.status // .details.newStatus // .details.toStatus // "") == "cancelled")
]
| sort_by(.createdAt // "")
| last
```

If this activity record ever disappears or lacks agent identity, the audit cannot
function safely and should stop rather than infer.

### 3. May 22 Closures Have `runId: null`

Sampled May 22 false closures had close activity like:

```json
{
  "actorType": "agent",
  "agentId": "adfb98e4-redacted",
  "action": "issue.updated",
  "runId": null,
  "details": { "status": "cancelled" }
}
```

There is no heartbeat transcript for these closes. The audit rule is:

```text
actor is an agent AND closing activity runId is null => evidence-less
```

That branch is stronger than a weak transcript match because no transcript exists
and no tool-output evidence can be attached to the close run.

### 4. CEO Dedupe Carve-out Is Narrowed

The canonical carve-out was:

```text
closing agent role == CEO
AND (comment matches /duplicate of #?\d+/ OR status was cancelled instead of done)
```

On this deployment every close uses `cancelled`, so the second leg would exempt all
CEO closes. The script preserves intent by applying only the duplicate-text leg:

```jq
$text | test("duplicate of #?\\d+"; "i")
```

`$text` is the latest issue comment, issue title/description/body/content, and the
closing activity JSON.

## Evidence Detection

The audit is intentionally conservative. False positives are tolerable because a
human can re-close with evidence; false negatives defeat the audit.

For close activity with `runId: null`:

```text
evidence = false
reason = "closing activity at <createdAt> had runId=null; no heartbeat transcript exists"
```

For close activity with a non-null `runId`, the script fetches
`/api/heartbeat-runs/{runId}/events` and applies these jq predicates.

Normalize event arrays:

```jq
def norm_events:
  $events[0]
  | if type == "array" then .
    elif type == "object" and (.events | type) == "array" then .events
    elif type == "object" and (.data | type) == "array" then .data
    else []
    end;
```

Extract strong issue references:

```jq
def strings_join: [.. | strings] | join("\n");
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
```

Require a command to mention one of those references when any are extractable:

```jq
def mentions_ref($text):
  (strong_refs | length == 0)
  or any(strong_refs[]; ($text | ascii_downcase | contains(. | ascii_downcase)));
```

Detect attached tool output. An empty `stdout` still counts as attached output for
negative search results:

```jq
def has_output_key($event):
  any($event | .. | objects | keys_unsorted[]?;
    ascii_downcase | test("^(output|stdout|stderr|result|results|exitcode|exit_code|logs?)$"));
```

Detect evidence-producing commands:

```jq
def event_text($event): ($event | strings_join);

def search_cmd($text):
  $text | test("(^|[^A-Za-z0-9_-])(rg|grep|git[[:space:]]+grep|ripgrep|ag)([^A-Za-z0-9_-]|$)"; "i");

def read_cmd($text):
  $text | test("(^|[^A-Za-z0-9_-])(cat|sed|awk|head|tail|less|read_file|open_file|view)([^A-Za-z0-9_-]|$)"; "i");

def git_cmd($text):
  $text | test("git[[:space:]]+(show|log|blame|diff)([[:space:]]|$)"; "i");
```

Final decision:

```jq
{
  output_keys_present: any(norm_events[]; has_output_key(.)),
  grep_calls: ([norm_events[] | event_text(.) as $text | select(search_cmd($text) and mentions_ref($text))] | length),
  file_read_calls: ([norm_events[] | event_text(.) as $text | select(read_cmd($text) and mentions_ref($text))] | length),
  git_evidence_calls: ([norm_events[] | event_text(.) as $text | select(git_cmd($text) and mentions_ref($text))] | length),
  verified_no_change_tag: ($close_text | test("\\[VERIFIED-NO-CHANGE\\]"; "i"))
}
| .tool_evidence = (.output_keys_present and ((.grep_calls + .file_read_calls + .git_evidence_calls) > 0))
| .has_evidence = .tool_evidence
```

`[VERIFIED-NO-CHANGE]` alone is not evidence. It is accepted only when paired with
the grep/read/git tool evidence above.

## Auditor Agent Provisioning

Leif provisions the dedicated Auditor agent before enabling the timer:

1. Open Paperclip web UI at `http://100.89.115.103:3210`.
2. Navigate to Agents -> Create Agent.
3. Role: `auditor`, if selectable.
4. If `auditor` is not selectable, stop and ask Leif whether `engineer` is the
   correct fallback. Do not guess role taxonomy.
5. Mint an API key with read+write access on issues.
6. Paste it into `/etc/paperclip-substrate/audit.env` as `PAPERCLIP_AUDIT_API_KEY`.
7. Lock the file down:

```sh
chown root:paperclip-engineer /etc/paperclip-substrate/audit.env
chmod 0640 /etc/paperclip-substrate/audit.env
```

The script uses whatever bearer key is provided. Comment identity is determined
by Paperclip from that key, not by any local setting.

## State and Idempotency

Real mode writes one JSON state file under `AUDIT_STATE_DIR` after a successful
re-open. The state key is derived from:

```text
issue_id | run_id_or_null | closing_activity_createdAt
```

Including `createdAt` keeps repeated direct agent closes with `runId: null` auditable
while still preventing double-posts for the same close activity. Dry-run mode does
not write state. The audit-comment idempotency fallback also requires the matching
`createdAt` when `runId` is null, so a later direct close of the same issue is not
silently skipped.
