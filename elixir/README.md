# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work
2. Renders a repo-owned prompt plus the current Org workpad snapshot
3. Starts or resumes a Temporal workflow for the task
4. Runs Codex inside a K3s job backed by a stable per-task project workspace
5. Syncs `.symphony/workpad.md` and `.symphony/run-result.json` back into Org

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Choose an Org file and subtree to act as the tracker, then set `SYMPHONY_ORG_FILE` and
   `SYMPHONY_ORG_ROOT_ID`.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, and `land` skills to your repo.
5. Customize the copied `WORKFLOW.md` file for your project.
   - The default workflow expects Org TODO keywords that map to `Backlog`, `Todo`, `In Progress`,
     `Human Review`, `Merging`, `Rework`, and `Done`.
   - Set `tracker.file`, `tracker.root_id`, and `tracker.state_map` to match your Org layout.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage the Elixir/Erlang/Go toolchain.
Install Docker separately; the remote backend dev stack uses Docker to start both Temporal and a
single-node K3s control plane.

```bash
mise install
mise exec -- elixir --version
mise exec -- go version
docker --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony
mise trust
mise install
cd elixir
mise exec -- mix setup
mise exec -- mix build
cd ..
./dev/temporal-k3s up
./dev/temporal-k3s smoke
eval "$(./dev/temporal-k3s env)"
mise exec -- ./elixir/bin/symphony ./elixir/WORKFLOW.md
```

When you are done with the remote backend, tear it down with:

```bash
./dev/temporal-k3s down
```

## Repo-local Org workflows

This repository also keeps two local Org workflows under `./.symphony/`:

- `local-bootstrap-workflow.md` runs the local backend against the repo's Org queue and is intended
  for supervised bootstrap tasks that stop in `Human Review`.
- `fork-self-land-workflow.md` runs the local backend against the same Org queue, rewrites each
  workspace so `origin` points at `git@github.com:phi9t/oai-symphony.git`, and requires the
  repo-local `commit`, `push`, and `land` skills before the task can move to `Done`.
- The fork workflow also overrides the default Codex runtime settings so agent turns stay
  workspace-scoped while still allowing networked GitHub operations needed for `push` and `land`.

Start either workflow from the repository root:

```bash
mise exec -- ./elixir/bin/symphony ./.symphony/local-bootstrap-workflow.md
mise exec -- ./elixir/bin/symphony ./.symphony/fork-self-land-workflow.md
```

## Remote Backend Dev Stack

The repository now ships `./dev/temporal-k3s`, which provides a repeatable local bring-up path for
the Temporal/K3s backend:

```bash
./dev/temporal-k3s up
./dev/temporal-k3s status
./dev/temporal-k3s smoke
./dev/temporal-k3s down
```

What each command does:

- `up` starts a local Temporal dev server, starts a single-node K3s server in Docker, imports the
  repo-owned smoke image, and launches the Temporal worker with the right K3s control-plane wiring.
- `status` acts as the health check: it verifies Temporal, K3s, the worker, and the Symphony
  namespace are all ready.
- `smoke` runs an end-to-end Temporal workflow that fans out into a K3s job, clones the repo in the
  remote workspace, and writes the required `.symphony/workpad.md` plus `.symphony/run-result.json`
  artifacts.
- `down` stops the worker and removes the local Temporal plus K3s containers.

Before starting Symphony itself, export the workflow-facing environment that matches the dev stack:

```bash
eval "$(./dev/temporal-k3s env)"
```

This exports `TEMPORAL_ADDRESS`, `TEMPORAL_NAMESPACE`, `TEMPORAL_TASK_QUEUE`,
`SYMPHONY_K3S_PROJECT_ROOT`, and `SYMPHONY_K3S_SHARED_CACHE_ROOT`.

Notes:

- The smoke workflow uses the repo-owned `symphony/smoke-agent:dev` image built by
  `./dev/temporal-k3s up`.
- Real agent runs still need `k3s.image` to point at an image that contains `bash`, `git`, and a
  working implementation of your configured `codex.command`.
- The default Temporal helper command is now `./temporal/bin/symphony`, which works correctly from
  the repository root.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: orgmode
  file: "$SYMPHONY_ORG_FILE"
  root_id: "$SYMPHONY_ORG_ROOT_ID"
execution:
  kind: temporal_k3s
temporal:
  helper_command: "./temporal/bin/symphony"
repository:
  origin_url: "https://github.com/your-org/your-repo.git"
codex:
  command: codex exec --full-auto --json
---

You are working on an Org task `{{ issue.identifier }}`.
Keep progress in ./.symphony/workpad.md and emit ./.symphony/run-result.json before exit.
```

Notes:

- If a value is missing, defaults are used.
- `execution.kind: temporal_k3s` enables the new remote backend; `local` keeps the original host-local runner.
- The remote backend requires a Temporal helper command plus `repository.origin_url`.
- The shipped remote workflow does not rely on `org_task`; Org updates are applied by Symphony after the job completes.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- `tracker.file` resolves `$VAR` before path handling, so env-backed file paths are supported.
- `tracker.root_id` is the Org `ID` of the parent heading that contains Symphony-managed tasks.
- `tracker.state_map` maps Org TODO keywords such as `IN_PROGRESS` to display states such as
  `In Progress`.
- `tracker.api_key` still reads from `LINEAR_API_KEY` when `tracker.kind: linear` is used.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `k3s.project_root`, `k3s.shared_cache_root`, and `workspace.root`
  resolve `$VAR` before path handling, while `codex.command` stays a shell command string.

```yaml
tracker:
  file: $SYMPHONY_ORG_FILE
  root_id: $SYMPHONY_ORG_ROOT_ID
execution:
  kind: temporal_k3s
repository:
  origin_url: $SOURCE_REPO_URL
k3s:
  project_root: $SYMPHONY_K3S_PROJECT_ROOT
  shared_cache_root: $SYMPHONY_K3S_SHARED_CACHE_ROOT
codex:
  command: "$CODEX_BIN exec --full-auto --json"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local and remote runs
- `../temporal/`: Go Temporal helper and worker used by the remote backend
- `../k3s/`: K3s templates and launch scripts for remote agent jobs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
