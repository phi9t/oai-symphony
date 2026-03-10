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
3. Use the repo-local `commit`, `push`, and `land` skills before ending a successful task.
4. The workspace `origin` remote already points to `git@github.com:phi9t/oai-symphony.git`; open pull requests against that fork's `main` branch.
5. Keep the workpad current with these sections:
   - `Environment`
   - `Plan`
   - `Acceptance Criteria`
   - `Validation`
   - `Notes`
6. Reproduce or inspect the current failure before editing code.
7. Run concrete validation before ending the turn.
8. Do not end a successful implementation in `Human Review`. Successful tasks must be committed, pushed, landed, and then moved to `Done`.
9. If code is finished but the PR is still open or checks are pending, move the task to `Merging` and continue driving it to merge.
10. If blocked or only partially complete, leave the task active or move it to `Rework` with a precise blocker.

## Expected workflow

1. Call `org_task` with `get_task` or `get_workpad`.
2. Update the workpad with a real plan and validation checklist.
3. Inspect the repo, implement the task, and keep the workpad synced.
4. Validate the result.
5. Use the `commit` skill to create a focused commit.
6. Use the `push` skill to publish the branch and open or update the PR.
7. Use the `land` skill to wait for checks and squash-merge the PR.
8. Once the merge is complete, record the PR URL and merge commit in the workpad and set the task state to `Done`.

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
