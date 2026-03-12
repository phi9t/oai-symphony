# Phase-1 Remote Validation Matrix

This document is the repo-owned source of truth for the phase-1 remote golden path defined by [`docs/rfcs/RFC-0001-validation-verification-hardening.md`](../rfcs/RFC-0001-validation-verification-hardening.md).

Use [`validation-triage.md`](validation-triage.md) for the operator command lookup, identifier correlation flow, evidence locations, retention defaults, and retry-vs-repair guidance that sit on top of this matrix.

Authoritative system under test:

`Org task -> Elixir orchestrator -> Temporal helper -> Temporal worker -> K3s job -> artifact bundle -> Elixir finalization -> Org task`

Use this matrix to answer four questions without reopening scope in later tasks:

- Which subsystem or boundary is changing?
- Which gate classes are required before the change can land?
- Which workstream owns the pass condition?
- Which evidence proves the change passed?

## Phase-1 Defaults

- `Local` means fast, targeted checks used while iterating on one subsystem or boundary.
- `Pre-merge` means a required gate before landing. As of March 12, 2026, only `make -C elixir all` is wired in GitHub Actions; the Go and shell gates below are still repo-owned required checks that run locally or on self-hosted infrastructure until dedicated CI lanes exist.
- `Scheduled` means a repeated self-hosted or operator-run cadence that keeps the remote path honest without blocking every PR.
- `Manual` means operator smoke or review proof for cutover, incident triage, or validating a newly-expanded surface.
- Phase 1 does not treat self-landing workflow smoke as part of the remote golden path. That remains a later-phase gate once the remote runtime itself is stable.

## Contract Authority

| Contract area | Authority | Canonical surfaces | Phase-1 rule |
| --- | --- | --- | --- |
| Operator-facing status and triage payloads | Presenter and observability API payloads | `elixir/lib/symphony_elixir_web/presenter.ex`, `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`, `/api/v1/state`, `/api/v1/refresh`, `/api/v1/:issue_identifier` | `REV-5` may extend operator projections and controls, but it does not get to redefine phase-1 payload ownership or required evidence without an RFC follow-up. |
| Runtime handoff between Elixir and Temporal | Temporal helper request and response payloads | `elixir/lib/symphony_elixir/execution/temporal_k3s.ex`, `elixir/lib/symphony_elixir/temporal_cli.ex`, `temporal/cmd/symphony/main.go` | `REV-14` owns versioning later, but phase 1 already fixes these payloads as the authoritative Elixir <-> Temporal contract. |
| Runtime handoff between worker and job runtime | Worker activity input and K3s launcher payloads | `temporal/internal/activities/issue_job.go`, `k3s/bin/sjob`, `k3s/bin/run-agent-job` | The worker may add fields later, but the existing workflow, run, project, workspace, artifact, and job identifiers remain mandatory phase-1 evidence keys. |
| Artifact handoff back to the control plane | `./.symphony/workpad.md` and `./.symphony/run-result.json` | `elixir/lib/symphony_elixir/execution/temporal_k3s.ex`, `k3s/bin/run-agent-job`, `dev/temporal-k3s`, `elixir/WORKFLOW.md` | `workpad.md` must preserve the required sections; `run-result.json` remains the authoritative target-state handoff for remote runs. |

## Gate Catalog

### Local

| ID | Check |
| --- | --- |
| `L1` | `cd elixir && /home/phi9t/.local/bin/mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs` |
| `L2` | `cd elixir && /home/phi9t/.local/bin/mise exec -- mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs` |
| `L3` | `cd elixir && /home/phi9t/.local/bin/mise exec -- mix test test/symphony_elixir/temporal_cli_test.exs test/symphony_elixir/temporal_k3s_test.exs test/symphony_elixir/orchestrator_status_test.exs` |
| `L4` | `cd elixir && /home/phi9t/.local/bin/mise exec -- mix test test/symphony_elixir/k3s_launcher_test.exs` |
| `L5` | `cd temporal && GOCACHE=/tmp/symphony-go-build go test ./...` |
| `L6` | `shellcheck dev/temporal-k3s k3s/bin/* k3s/lib/*.sh temporal/bin/*` |
| `L7` | `bash -n dev/temporal-k3s k3s/bin/* k3s/lib/*.sh temporal/bin/*` |

### Pre-merge

| ID | Check |
| --- | --- |
| `P1` | `make -C elixir all` |
| `P2` | `L3` whenever the remote backend, presenter payloads, final sync, or retry metadata change. |
| `P3` | `L5` whenever `temporal/` changes. |
| `P4` | `L6` and `L7` whenever `dev/temporal-k3s`, `k3s/`, or `temporal/bin/` changes. |

### Scheduled

| ID | Check |
| --- | --- |
| `S1` | Self-hosted or operator cadence: `./dev/temporal-k3s up`, `./dev/temporal-k3s status`, `./dev/temporal-k3s smoke`, `./dev/temporal-k3s down`. |
| `S2` | Self-hosted Org-backed golden path: export `./dev/temporal-k3s env`, run Symphony with `execution.kind: temporal_k3s` against an Org fixture or repo task, and capture the synced Org workpad/state plus `/api/v1/state`, `/api/v1/refresh`, and `/api/v1/:issue_identifier`. |

### Manual

| ID | Check |
| --- | --- |
| `M1` | Operator stack smoke: run the `dev/temporal-k3s` bring-up path and inspect the printed artifact directory for `workpad.md` and `run-result.json`. |
| `M2` | Operator golden-path round trip: move an Org task to `Todo`, run Symphony on the remote backend, and verify the final Org state plus synced workpad. |
| `M3` | Operator contract proof: capture `/api/v1/state`, `/api/v1/refresh`, and `/api/v1/:issue_identifier` during a remote run and confirm workflow, run, job, workspace, and artifact metadata are present when applicable. |

## Subsystem Matrix

| Phase-1 subsystem | Local | Pre-merge | Scheduled | Manual | Owning workstream | Required evidence for pass |
| --- | --- | --- | --- | --- | --- | --- |
| Workflow config, schema parsing, and remote workflow prompt contract | `L1` | `P1` | `S2` | `M2` | Elixir control plane | Green config/workflow tests plus one remote run using the intended workflow file and env wiring. |
| Org tracker intake plus final state/workpad sync | `L1`, `L3` | `P1`, `P2` | `S2` | `M2` | Elixir control plane | The issue is claimed from Org, the workpad is read before dispatch, and the final state plus workpad write back to Org without manual repair. |
| Orchestrator state transitions, retry behavior, and stall handling | `L3` | `P1`, `P2` | `S2` | `M2` | Elixir control plane | Test output proves bounded status polling, fresh retry identifiers, and terminal-state reconciliation. |
| Presenter, dashboard, and observability API payloads | `L2`, `L3` | `P1`, `P2` | `S2` | `M3` | Operator contract | `state`, `issue`, and `refresh` payloads preserve remote metadata needed to identify backend, workflow, run, job, workspace, and artifact directory. |
| Temporal helper CLI request and response payloads | `L3`, `L5` | `P2`, `P3` | `S1`, `S2` | `M3` | Temporal runtime | Green helper tests plus a smoke or golden-path capture that shows the same Temporal address, namespace, workflow ID, and run ID through `run`, `status`, `cancel`, and `describe`. |
| Temporal workflow, activity, and worker lifecycle | `L5` | `P3` | `S1`, `S2` | `M1`, `M2` | Temporal runtime | `go test` stays green and repeated smoke proves the worker can launch, observe, and complete a K3s job with stable IDs. |
| K3s launcher shell scripts and manifest rendering | `L4`, `L6`, `L7` | `P4` | `S1` | `M1` | K3s runtime | Manifest tests plus clean shell analysis and a smoke run that shows the job starts with the expected namespace, resources, and TTL. |
| Remote agent launcher and Codex command handoff | `L5`, `L6`, `L7` | `P3`, `P4` | `S1`, `S2` | `M1`, `M2` | K3s runtime | The remote workspace is created from the configured repo, the prompt/workpad/result paths are populated, and the command exits with a valid result artifact. |
| Artifact contract handling for `./.symphony/workpad.md` and `./.symphony/run-result.json` | `L3` | `P2` | `S1`, `S2` | `M1`, `M2` | Runtime contract | `workpad.md` keeps the required sections, `run-result.json` carries a valid target-state handoff, and Elixir rejects missing or malformed final sync data. |
| Repo-managed Temporal/K3s stack smoke harness | `L5`, `L6`, `L7` | `P3`, `P4` when those paths change | `S1` | `M1` | Validation operations | The stack brings itself up, reports ready, produces the expected artifacts, and tears itself down cleanly. |

## Boundary Matrix

| Phase-1 boundary | Local | Pre-merge | Scheduled | Manual | Owning workstream | Required evidence for pass |
| --- | --- | --- | --- | --- | --- | --- |
| Org task -> Elixir orchestrator intake | `L1`, `L3` | `P1`, `P2` | `S2` | `M2` | Elixir control plane | The claimed issue, initial workpad, and prompt inputs match Org data and survive retry/continuation. |
| Elixir -> Temporal helper request and response handoff | `L3` | `P2` | `S1`, `S2` | `M3` | Temporal runtime | Helper payloads preserve `workflowId`, `runId`, `projectId`, connection settings, and remote workspace paths. |
| Temporal helper -> worker execution handoff | `L5` | `P3` | `S1`, `S2` | `M1`, `M2` | Temporal runtime | The worker accepts the helper payload unchanged enough to launch the correct workflow and attempt. |
| Worker -> K3s launcher handoff | `L4`, `L5`, `L6`, `L7` | `P3`, `P4` | `S1` | `M1` | K3s runtime | The rendered job name, resource settings, runtime class, and mounted paths match the worker payload. |
| K3s job -> artifact directory handoff | `L3`, `L5` | `P2`, `P3` | `S1`, `S2` | `M1`, `M2` | Runtime contract | The job writes readable `workpad.md` and `run-result.json` files under the expected artifact/workspace path. |
| Artifact directory -> Elixir finalization handoff | `L3` | `P2` | `S2` | `M2` | Elixir control plane | Elixir reads the artifact bundle, derives the target state, and fails loudly if the data is missing or malformed. |
| Elixir finalization -> Org state/workpad handoff | `L3` | `P2` | `S2` | `M2` | Elixir control plane | The final Org state and workpad reflect the remote attempt without a second manual sync step. |
| Orchestrator snapshot -> presenter/API operator handoff | `L2`, `L3` | `P1`, `P2` | `S2` | `M3` | Operator contract | Operator surfaces expose enough metadata to diagnose which plane failed without log archaeology. |

## Backlog Boundary Resolution

`REV-17` fixes the phase-1 scope. The following tasks inherit this document instead of creating their own competing plan:

| Task | Resolution |
| --- | --- |
| `REV-5` | Owns operator projection and control evolution on top of the operator-facing authority defined here. It may add fields or controls, but it must not redefine presenter/API payload ownership, gate classes, or pass evidence for the remote golden path. |
| `REV-12` | Owns module decomposition only. It must preserve the subsystem and boundary responsibilities in this matrix and keep the same validation obligations even if code moves between modules. |
| `REV-13` | Owns harness structure, fixture reuse, and scenario builders. It may reorganize the tests behind `L1`-`L7` and `P1`-`P4`, but it does not choose a different subsystem list or lower the evidence bar. |
| `REV-14` | Owns schema/versioning follow-through for the helper and artifact contracts already named here. It version-controls the authorities; it does not reopen which payloads are authoritative in phase 1. |

Any later task that needs to add a new subsystem, boundary, or gate class to the remote golden path should update RFC-0001 first or land an explicit follow-up RFC before changing this matrix.
