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
3. Use `org_task.deep_dive` when you need to capture a structural analysis, failure investigation, or architecture review in the task itself.
4. Use `org_task.deep_revision` when your work reveals follow-on tasks. Use `mode: "create"` only when the new work is clear and actionable; use `mode: "draft"` when uncertainty is still high and the proposal should be discussed first. Every proposed task must include title, description, acceptance criteria, priority, and validation, and created tasks should start with an empty `Codex Workpad`.
5. For major architecture, runtime, or process proposals, create or update an RFC in `docs/rfcs/` before spawning implementation tasks. Only convert accepted RFCs into Org tasks.
6. Keep the workpad current with these sections:
   - `Environment`
   - `Plan`
   - `Acceptance Criteria`
   - `Validation`
   - `Notes`
7. Reproduce or inspect the current failure before editing code.
8. Run concrete validation before ending the turn.
9. Only set the task to `Human Review` when the task is actually ready for review.
10. If blocked or only partially complete, leave the task in an active state or move it to `Rework` with a precise blocker.

## Expected workflow

1. Call `org_task` with `get_task` or `get_workpad`.
2. Update the workpad with a real plan and validation checklist.
3. Inspect the repo, implement needed changes, and keep the workpad synced.
4. If the work uncovers architecture findings, capture them with `org_task.deep_dive`.
5. If the work becomes a major proposal rather than a direct fix, write an RFC in `docs/rfcs/` and keep task creation behind RFC review.
6. If the work reveals new actionable issues, call `org_task.deep_revision` with a detailed task list that includes description, acceptance criteria, priority, and validation for each task.
7. Validate the result.
8. Set the final state with `org_task.set_state`.

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
