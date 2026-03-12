# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors tracked work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

For this repository itself, the repo-local Org workflows live under [`.symphony/`](.symphony):
`temporal-self-land-workflow.md` is the preferred unattended path on hosts where the Temporal/K3s
runtime is available, `fork-self-land-workflow.md` remains the local fallback and requires
`commit`, `push`, and `land` before `Done`, and `local-bootstrap-workflow.md` keeps supervised
local runs in `Human Review`.

Those Org workflows also define a planning lane: use `org_task.deep_dive` to keep structural
analysis or failure investigation on the current task, and use `org_task.deep_revision` in
`draft` mode for uncertain proposals or `create` mode only for clear top-level tasks with
description, acceptance criteria, priority, validation steps, and a blank `Codex Workpad`.

On supported hosts, start the queue with `./.symphony/temporal-self-land-workflow.md` after
bringing up the stack and exporting its environment:

```bash
./dev/temporal-k3s up
eval "$(./dev/temporal-k3s env)"
mise exec -- ./elixir/bin/symphony ./.symphony/temporal-self-land-workflow.md
```

The remote self-landing path claims normal Org tasks, runs them through Temporal workflows and K3s
jobs, syncs `.symphony/workpad.md` plus `.symphony/run-result.json` back into Org, and only marks
tasks `Done` after the PR URL and merge commit are recorded in the workpad. Before each claim,
Symphony now probes Temporal reachability, namespace availability, active worker pollers, and the
target K3s namespace so blocked runtimes surface immediately instead of hanging after dispatch.
Remote runs also bound repeated Temporal status-check failures by `codex.stall_timeout_ms`, fail
the attempt if the final Org sync cannot be written back, start each retry in a fresh
Temporal/K3s attempt, and run the configured `before_remove` cleanup hook before deleting remote
project workspaces.

To smoke the self-landing queue in this repository without the remote stack, start Symphony with
`./.symphony/fork-self-land-workflow.md`, move an Org task to `Todo`, and let the queue drive the
task through implementation, fork PR creation, merge, and `Done`. After the merge is recorded in
the Org workpad, Symphony removes the matching workspace on the next terminal cleanup pass; if a
task reaches a terminal state without merge, the `before_remove` hook closes any leftover fork PRs
before deleting the workspace. The observability API/dashboard also exposes the active remote
workflow/run/job identifiers, artifact directory, last successful status poll, last Org sync
result, and stable failure code when those fields are available.

The repository now also ships a repo-owned Temporal/K3s developer stack for the remote backend:

```bash
./dev/temporal-k3s up
./dev/temporal-k3s status
./dev/temporal-k3s smoke
./dev/temporal-k3s down
```

The remote K3s workflow also supports optional `k3s.default_gpu_count` and `k3s.runtime_class`
settings for GPU-backed jobs without changing CPU-only manifests.

When the remote backend is configured with a non-default Temporal `address` or `namespace`, the
helper now reuses that connection for workflow `run`, `status`, `cancel`, and `describe`
operations.

The repo-owned source of truth for the phase-1 remote golden path now lives in
[`docs/operations/phase-1-remote-validation-matrix.md`](docs/operations/phase-1-remote-validation-matrix.md).
Use that matrix for required gate classes, contract authority, owners, and pass evidence across
the `Org -> Elixir -> Temporal -> K3s -> Org` path.

See [elixir/README.md](elixir/README.md) for the detailed bring-up, health-check, and teardown
workflow.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
