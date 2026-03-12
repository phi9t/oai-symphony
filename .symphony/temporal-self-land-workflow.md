---
tracker:
  kind: orgmode
  file: "/mnt/data_infra/workspace/symphony/.symphony/revision-plan.org"
  root_id: "f9275d23-68c0-4ce4-bdf9-2169f65b28da"
  emacsclient_command: "emacs --quick --batch"
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
  task_queue: "$TEMPORAL_TASK_QUEUE"
  status_poll_ms: 5000
k3s:
  namespace: "symphony"
  image: "$SYMPHONY_K3S_IMAGE"
  project_root: "$SYMPHONY_K3S_PROJECT_ROOT"
  shared_cache_root: "$SYMPHONY_K3S_SHARED_CACHE_ROOT"
  ttl_seconds_after_finished: 86400
  default_cpu: "2"
  default_memory: "8Gi"
  default_gpu_count: 0
  runtime_class: null
repository:
  origin_url: "https://github.com/phi9t/oai-symphony.git"
  default_branch: "main"
workspace:
  root: "/mnt/data_infra/workspace/symphony/.symphony/workspaces"
hooks:
  before_remove: |
    cd elixir && /home/phi9t/.local/bin/mise exec -- mix workspace.before_remove --repo phi9t/oai-symphony
agent:
  max_concurrent_agents: 1
  max_turns: 30
server:
  port: 4041
codex:
  command: "codex exec --json -a never -s workspace-write"
---

You are working on Org task `{{ issue.identifier }}` for the Symphony repository.

Issue context:
- Identifier: `{{ issue.identifier }}`
- Title: `{{ issue.title }}`
- Current state: `{{ issue.state }}`
- Labels: `{{ issue.labels }}`

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Current synced workpad snapshot:
{% if workpad %}
{{ workpad }}
{% else %}
No workpad exists yet.
{% endif %}

## Operating model

1. This is an unattended Temporal/K3s execution. Never ask a human to perform follow-up work.
2. The control plane owns Org updates. Do not expect an `org_task` tool in this remote run.
3. Keep progress in local artifacts under `./.symphony/`.
4. The control plane will sync `./.symphony/workpad.md` back into the Org `Codex Workpad` after the run.
5. The control plane will read `./.symphony/run-result.json` to decide the target Org state.
6. Use the repo-local `commit`, `push`, and `land` skills before setting `targetState: "Done"`.
7. The workspace `origin` remote points at `https://github.com/phi9t/oai-symphony.git`. Add `upstream` as `https://github.com/openai/symphony.git` if a workflow step or skill expects it.
8. Runtime readiness is checked before claim. If Temporal, the worker, or K3s are unavailable, the control plane will block dispatch and surface the blocker separately.
9. Use [`docs/operations/validation-triage.md`](docs/operations/validation-triage.md) for operator triage commands, evidence locations, and retry-vs-repair guidance, and use [`docs/operations/phase-1-remote-validation-matrix.md`](docs/operations/phase-1-remote-validation-matrix.md) for required gate classes and pass evidence.

## Required local artifacts

- `./.symphony/workpad.md`
  - This is the live execution checklist and must be updated as work progresses.
- `./.symphony/run-result.json`
  - This file must exist before the run ends.
  - Required keys: `status`, `targetState`, `summary`, `validation`, `blockedReason`, `needsContinuation`.

## Execution requirements

1. Reconcile `./.symphony/workpad.md` with the repo state before new edits.
2. Keep the workpad current with these sections:
   - `Environment`
   - `Plan`
   - `Acceptance Criteria`
   - `Validation`
   - `Notes`
3. Reproduce first before changing code.
4. Run the task's required validation before concluding.
5. Only set `targetState: "Done"` after the PR is merged and the workpad records both the PR URL and merge commit.
6. If blocked, record the blocker in both the workpad and `run-result.json`.

## Result contract

- Successful landed run:
  - `targetState`: `Done`
  - `needsContinuation`: `false`
- Successful but not yet merged:
  - `targetState`: `Human Review`
  - `needsContinuation`: `false`
- Blocked or failed-but-actionable:
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
- [ ] Command or proof

### Notes
- Findings and decisions
- PR: <url>
- Merge commit: <sha>
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
