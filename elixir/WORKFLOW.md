---
# Repo-local Symphony workflows for this repository live under `../.symphony/`.
# `local-bootstrap-workflow.md` is the supervised local path.
# `fork-self-land-workflow.md` rewrites workspace remotes to
# `git@github.com:phi9t/oai-symphony.git`, enables networked Codex turns
# for GitHub operations, and requires `commit`, `push`, and `land`
# before a task can move to `Done`.
# In a self-landing setup, only emit `targetState: "Done"` after the PR has
# actually merged. Once the tracker reflects that terminal state, Symphony
# removes the matching workspace; if `hooks.before_remove` is configured, it
# runs first so stale PRs can be closed before deletion.
tracker:
  kind: orgmode
  file: "$SYMPHONY_ORG_FILE"
  root_id: "$SYMPHONY_ORG_ROOT_ID"
  emacsclient_command: "emacsclient -a emacs"
  state_map:
    BACKLOG: Backlog
    TODO: Todo
    IN_PROGRESS: In Progress
    HUMAN_REVIEW: Human Review
    MERGING: Merging
    REWORK: Rework
    DONE: Done
    CANCELLED: Cancelled
    DUPLICATE: Duplicate
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Cancelled
    - Closed
    - Done
    - Duplicate
polling:
  interval_ms: 5000
execution:
  kind: temporal_k3s
temporal:
  helper_command: "./temporal/bin/symphony"
  address: "$TEMPORAL_ADDRESS"
  namespace: "$TEMPORAL_NAMESPACE"
  task_queue: "symphony"
  status_poll_ms: 5000
k3s:
  namespace: "symphony"
  image: "symphony/agent:latest"
  project_root: "$SYMPHONY_K3S_PROJECT_ROOT"
  shared_cache_root: "$SYMPHONY_K3S_SHARED_CACHE_ROOT"
  ttl_seconds_after_finished: 86400
  default_cpu: "2"
  default_memory: "8Gi"
  default_gpu_count: 0
  runtime_class: null
repository:
  origin_url: "https://github.com/openai/symphony.git"
  default_branch: "main"
workspace:
  root: ~/code/symphony-workspaces
hooks:
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex exec --full-auto --json
---

The configured `temporal.address` and `temporal.namespace` apply to helper `run`, `status`,
`cancel`, and `describe` requests.

You are working on an Org task `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the task is still in an active state.
- Each retry starts in a fresh remote workflow/job attempt.
- Rebuild context from the synced workpad and repository state instead of assuming the prior remote workspace still exists.
- Do not repeat already-completed investigation or validation unless the repo state changed.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Current workpad snapshot:
{% if workpad %}
{{ workpad }}
{% else %}
No workpad was synced from Org.
{% endif %}

## Operating model

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. The control plane owns Org updates. You must not expect an `org_task` tool.
3. Keep all progress in local artifacts under `./.symphony/`.
4. The control plane will sync `./.symphony/workpad.md` back to the Org `Codex Workpad` heading after the run.
5. The control plane will read `./.symphony/run-result.json` to decide the target Org state.
6. If remote status checks exceed `codex.stall_timeout_ms` or the final Org sync fails, the control
   plane will fail the run instead of silently retrying forever or dropping the error.

## Required local artifacts

- `./.symphony/workpad.md`
  - This is the live execution checklist and must be updated as work progresses.
- `./.symphony/run-result.json`
  - This file must exist before the run ends.
  - Required keys: `status`, `targetState`, `summary`, `validation`, `blockedReason`, `needsContinuation`.

## Default posture

- Start by reconciling `./.symphony/workpad.md` with the repo state.
- Reproduce first before changing code.
- Treat any task-authored `Validation`, `Test Plan`, or `Testing` sections as mandatory acceptance input.
- Keep the workpad current whenever the plan, findings, or validation state changes.
- Operate autonomously end-to-end unless blocked by missing permissions or secrets.

## State rules

- `Backlog` -> do not change code or artifacts.
- `Todo` -> the control plane will move the task to `In Progress` before your run starts.
- `In Progress` -> execute the plan and keep the local workpad current.
- `Human Review` -> only target this state when validation is complete and the branch/PR is ready.
- `Rework` -> rebuild the plan around the new feedback, not as a minimal patch.
- `Done` -> terminal; do nothing.

## Execution requirements

1. Reconcile `./.symphony/workpad.md` before new edits.
2. Ensure the workpad keeps these sections:
   - `Environment`
   - `Plan`
   - `Acceptance Criteria`
   - `Validation`
   - `Notes`
3. Capture a concrete reproduction signal before implementing.
4. Run the required validation before concluding the run.
5. If blocked, record the blocker in both the workpad and `run-result.json`.

## `run-result.json` contract

- Successful ready-for-review run:
  - `targetState`: `Human Review`
  - `needsContinuation`: `false`
- Blocked or failed-but-actionable run:
  - `targetState`: `Rework`
  - `blockedReason`: short explanation
- More work required in another run:
  - `targetState`: `In Progress`
  - `needsContinuation`: `true`

## Workpad template

```md
### Environment
`<host>:<abs-workdir>@<short-sha>`

### Plan
- [ ] Item

### Acceptance Criteria
- [ ] Criterion

### Validation
- [ ] Command or manual proof

### Notes
- Findings, reproduction signals, and review outcomes
```

## Result template

```json
{
  "status": "succeeded",
  "targetState": "Human Review",
  "summary": "Short run summary.",
  "validation": ["mix test"],
  "blockedReason": null,
  "needsContinuation": false
}
```
