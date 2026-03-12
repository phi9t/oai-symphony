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
  kind: local
workspace:
  root: "/mnt/data_infra/workspace/symphony/.symphony/workspaces"
hooks:
  after_create: |
    rsync -a --delete \
      --exclude '.symphony/workspaces/' \
      /mnt/data_infra/workspace/symphony/ ./
    git remote set-url origin git@github.com:phi9t/oai-symphony.git
    if git remote get-url upstream >/dev/null 2>&1; then
      git remote set-url upstream https://github.com/openai/symphony.git
    else
      git remote add upstream https://github.com/openai/symphony.git
    fi
    git fetch origin main
    git checkout -B "symphony/$(basename "$PWD")" origin/main
  before_remove: |
    cd elixir && /home/phi9t/.local/bin/mise exec -- mix workspace.before_remove --repo phi9t/oai-symphony
agent:
  max_concurrent_agents: 1
  max_turns: 30
server:
  port: 4041
codex:
  command: "codex app-server"
  approval_policy: "never"
  thread_sandbox: "workspace-write"
  turn_sandbox_policy:
    type: "workspaceWrite"
    writableRoots:
      - "/mnt/data_infra/workspace/symphony/.symphony/workspaces"
    readOnlyAccess:
      type: "fullAccess"
    networkAccess: true
    excludeTmpdirEnvVar: false
    excludeSlashTmp: false
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
2. Use the `org_task` tool to read the task, keep the workpad current, and set the final state.
3. Use `org_task.deep_dive` to record structural analysis or failure investigation that should stay with the task.
4. Use `org_task.deep_revision` when the implementation exposes follow-on work. Use `mode: "create"` only when the new tasks are clearly actionable; otherwise use `mode: "draft"` so the proposal can be reviewed later. Every proposed task must include title, description, acceptance criteria, priority, and validation, and created tasks should start with an empty `Codex Workpad`.
5. For major architecture, runtime, or process proposals, write an RFC under `docs/rfcs/` and collect review votes before converting it into implementation tasks.
6. Use the repo-local `commit`, `push`, and `land` skills before ending a successful task.
7. The workspace `origin` remote already points to `git@github.com:phi9t/oai-symphony.git`; open pull requests against that fork's `main` branch.
8. Keep the workpad current with these sections:
   - `Environment`
   - `Plan`
   - `Acceptance Criteria`
   - `Validation`
   - `Notes`
9. Reproduce or inspect the current failure before editing code.
10. Run concrete validation before ending the turn.
11. Do not end a successful implementation in `Human Review`. Successful tasks must be committed, pushed, landed, and then moved to `Done`.
12. If code is finished but the PR is still open or checks are pending, move the task to `Merging` and continue driving it to merge.
13. If blocked or only partially complete, leave the task active or move it to `Rework` with a precise blocker.
14. Use [`docs/operations/validation-triage.md`](docs/operations/validation-triage.md) for command lookup, evidence locations, and retry-vs-repair guidance, and use [`docs/operations/phase-1-remote-validation-matrix.md`](docs/operations/phase-1-remote-validation-matrix.md) for validation gate classes and pass evidence.

## Expected workflow

1. Call `org_task` with `get_task` or `get_workpad`.
2. Update the workpad with a real plan and validation checklist.
3. Inspect the repo, implement the task, and keep the workpad synced.
4. If the work uncovers reusable analysis, capture it with `org_task.deep_dive`.
5. If the work becomes a broad proposal rather than a direct implementation, write an RFC in `docs/rfcs/` and keep new task creation behind RFC review.
6. If the work reveals new actionable issues, call `org_task.deep_revision` with detailed tasks that include description, acceptance criteria, priority, and validation for each task.
7. Validate the result.
8. Use the `commit` skill to create a focused commit.
9. Use the `push` skill to publish the branch and open or update the PR.
10. Use the `land` skill to wait for checks and squash-merge the PR.
11. Once the merge is complete, record the PR URL and merge commit in the workpad and set the task state to `Done`.

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
