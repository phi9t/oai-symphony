---
tracker:
  kind: orgmode
  file: "/mnt/data_infra/workspace/symphony/.symphony/revision-plan.org"
  root_id: "f9275d23-68c0-4ce4-bdf9-2169f65b28da"
  emacsclient_command: "emacsclient -s symphony"
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
  kind: local
workspace:
  root: "/mnt/data_infra/workspace/symphony/.symphony/workspaces"
hooks:
  after_create: |
    rsync -a --delete \
      --exclude '.symphony/workspaces/' \
      /mnt/data_infra/workspace/symphony/ ./
  before_remove: |
    cd elixir && /home/phi9t/.local/bin/mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: "codex app-server"
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

Current Org workpad:
{% if workpad %}
{{ workpad }}
{% else %}
No workpad exists yet.
{% endif %}

## Operating rules

1. Act autonomously. Do not ask a human to perform follow-up work.
2. Use the `org_task` tool to read and replace the workpad as you progress.
3. Keep the workpad current with these sections:
   - `Environment`
   - `Plan`
   - `Acceptance Criteria`
   - `Validation`
   - `Notes`
4. Reproduce or inspect the current failure before editing code.
5. Run concrete validation before ending the turn.
6. Only set the task to `Human Review` when the task is actually ready for review.
7. If blocked or only partially complete, leave the task in an active state or move it to `Rework` with a precise blocker.

## Expected workflow

1. Call `org_task` with `get_task` or `get_workpad`.
2. Update the workpad with a real plan and validation checklist.
3. Inspect the repo, implement needed changes, and keep the workpad synced.
4. Validate the result.
5. Set the final state with `org_task.set_state`.

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
```
