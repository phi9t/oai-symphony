# Validation Triage Runbook

Use this document for command lookup, identifier correlation, evidence collection, and retry-vs-repair decisions. Use the companion [phase-1 remote validation matrix](phase-1-remote-validation-matrix.md) for gate classes, owners, and required pass evidence.

All commands assume the repository root unless noted otherwise.

## Default Posture

- As of March 12, 2026, GitHub Actions only runs `.github/workflows/make-all.yml`, which executes `make -C elixir all` on pull requests and pushes to `main`.
- The repo-managed Temporal/K3s stack is not yet a required GitHub-hosted lane. Repeated smoke stays self-hosted or operator-run:

  ```bash
  ./dev/temporal-k3s up
  ./dev/temporal-k3s status
  ./dev/temporal-k3s smoke
  ./dev/temporal-k3s smoke --workflow-mode vanilla
  ./dev/temporal-k3s down
  ```

- The heavier Org-backed golden path is also operator-run or self-hosted:

  ```bash
  eval "$(./dev/temporal-k3s env)"
  mise exec -- ./elixir/bin/symphony ./.symphony/temporal-self-land-workflow.md
  ```

- Failure injection is later-phase work. Treat it as scheduled or manual validation, not as a merge-blocking PR requirement.

## Triage Sequence

1. Start at the observability API:

   ```bash
   curl -s http://127.0.0.1:4041/api/v1/state | jq
   curl -s http://127.0.0.1:4041/api/v1/<issue_identifier> | jq
   curl -s -X POST http://127.0.0.1:4041/api/v1/refresh | jq
   ```

2. Copy the identifiers from `.running` or `.retry`: `workflow_id`, `workflow_run_id`, `project_id`, `workspace_path`, `artifact_dir`, `job_name`, `failure_code`, and `last_known_org_sync_result`.
3. Use the subsystem command map below to prove which plane failed before retrying.
4. Capture evidence before cleanup or repair changes remove it.

## Identifier Lookup Flow

1. Start with the Org task identifier such as `REV-22`.
2. Query `http://127.0.0.1:4041/api/v1/<issue_identifier>`.
3. If the issue is still active, read `.running.*`. If it is backing off, read `.retry.*`.
4. Use `workflow_id` and `workflow_run_id` with the Temporal helper:

   ```bash
   cat > /tmp/temporal-status.json <<'EOF'
   {
     "workflowId": "<workflow_id>",
     "runId": "<workflow_run_id>",
     "workflowMode": "phased",
     "temporal": {
       "address": "${TEMPORAL_ADDRESS}",
       "namespace": "${TEMPORAL_NAMESPACE}",
       "taskQueue": "${TEMPORAL_TASK_QUEUE}"
     }
   }
   EOF

   ./temporal/bin/symphony status --input /tmp/temporal-status.json --output json | jq
   ./temporal/bin/symphony describe --input /tmp/temporal-status.json --output json | jq
   ```

5. Use `job_name` and `project_id` with the K3s tooling:

   ```bash
   ./k3s/bin/sjob status --project-id <project_id> --job <job_name> --namespace symphony --output json | jq
   ./k3s/bin/docker-kubectl logs -n symphony job/<job_name> --all-containers=true
   ```

6. If the API is unavailable, fall back to local evidence:

   ```bash
   tail -n 200 log/symphony.log
   tail -n 200 .symphony/dev/temporal-k3s/logs/worker.log
   find "${SYMPHONY_K3S_PROJECT_ROOT:-$PWD/.symphony/dev/projects}" -maxdepth 3 -type f \( -name metadata.json -o -name run-result.json \) | sort
   ```

## Evidence Locations

- Symphony control-plane logs: `log/symphony.log` unless `--logs-root` changed it.
- Repo-managed worker logs: `.symphony/dev/temporal-k3s/logs/worker.log`.
- Repo-managed smoke evidence: `.symphony/dev/projects/smoke-*/evidence/`.
- Smoke summaries: `summary.txt`, plus `blocker-plane.txt` and `blocker.txt` on failures. These are
  the fastest way to identify the failing plane before reading raw logs.
- Live remote workspaces: `${SYMPHONY_K3S_PROJECT_ROOT:-$PWD/.symphony/dev/projects}/<project_id>/workspace/`.
- Copied artifact bundles: `${SYMPHONY_K3S_PROJECT_ROOT:-$PWD/.symphony/dev/projects}/<project_id>/outputs/<run_id>/`.
- Artifact metadata: `metadata.json` in the copied artifact bundle. It records `workflowId`, `runId`, `projectId`, `jobName`, `status`, `collectedArtifacts`, and any `cleanupError`.
- Retried remote attempts keep sibling project roots with `-attempt-<n>-<hint>` suffixes. Preserve the failed attempt directory until triage is complete.

## Evidence Retention Defaults

- Successful remote attempts keep their artifact bundle only until final Org reconciliation and normal workspace cleanup complete. After cleanup, the remaining durable proof should be the recorded identifiers, state, and outcome metadata in Org plus the observability surfaces.
- Failed remote attempts keep their evidence by default until the issue leaves active triage or an operator explicitly cleans it up.
- `./dev/temporal-k3s smoke` always preserves a dedicated evidence directory and prints its path. Keep that directory until the failing plane is understood.
- The default smoke lane is `workflow_mode=phased`. Capture one `./dev/temporal-k3s smoke` result
  and one `./dev/temporal-k3s smoke --workflow-mode vanilla` result when validating the fallback
  contract or triaging a phased-only regression.

## Subsystem Command Map

### Org Intake And Final Sync

- Remote triage:

  ```bash
  curl -s http://127.0.0.1:4041/api/v1/<issue_identifier> | jq '{status, failure_code: (.retry.failure_code // .running.failure_code), org_sync: (.retry.last_known_org_sync_result // .running.last_known_org_sync_result), workspace, retry, running}'
  ```

- Local regression:

  ```bash
  cd elixir && /home/phi9t/.local/bin/mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs
  ```

- Primary evidence: `log/symphony.log`, copied `.symphony/workpad.md`, copied `.symphony/run-result.json`.
- Key remote lifecycle log events in `log/symphony.log`: `event=issue_dispatch`,
  `event=remote_workflow_submission_*`, `event=remote_phase_*`, `event=remote_status_poll_*`,
  `event=remote_artifact_sync_*`, and `event=remote_org_finalization_*`.
- Repair before retry when the failure is `org_workpad_sync_failed`, `org_state_sync_failed`, or the issue cannot be read back from Org.

### Elixir Control Plane And Observability API

- Remote triage:

  ```bash
  tail -n 200 log/symphony.log
  curl -s http://127.0.0.1:4041/api/v1/state | jq '.runtime, .running, .retrying'
  curl -s -X POST http://127.0.0.1:4041/api/v1/refresh | jq
  ```

- Local regression:

  ```bash
  make -C elixir all
  cd elixir && /home/phi9t/.local/bin/mise exec -- mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs
  ```

- Primary evidence: `log/symphony.log`, `/api/v1/state`, `/api/v1/<issue_identifier>`, `/api/v1/refresh`.
- Repair before retry when the issue never appears in the API, refresh fails, or the control plane cannot read the current runtime state.

### Temporal Reachability And Workflow State

- Runtime readiness:

  ```bash
  ./dev/temporal-k3s status

  cat > /tmp/temporal-readiness.json <<'EOF'
  {
    "temporal": {
      "address": "${TEMPORAL_ADDRESS}",
      "namespace": "${TEMPORAL_NAMESPACE}",
      "taskQueue": "${TEMPORAL_TASK_QUEUE}"
    },
    "k3s": {
      "namespace": "symphony"
    }
  }
  EOF

  ./temporal/bin/symphony readiness --input /tmp/temporal-readiness.json --output json | jq
  ```

- Workflow detail:

  ```bash
  ./temporal/bin/symphony status --input /tmp/temporal-status.json --output json | jq
  ./temporal/bin/symphony describe --input /tmp/temporal-status.json --output json | jq
  ```

- Local regression:

  ```bash
  cd elixir && /home/phi9t/.local/bin/mise exec -- mix test test/symphony_elixir/temporal_cli_test.exs test/symphony_elixir/temporal_k3s_test.exs test/symphony_elixir/orchestrator_status_test.exs
  cd temporal && GOCACHE=/tmp/symphony-go-build go test ./...
  ```

- Primary evidence: `/api/v1/state` runtime blockers, helper `status` and `describe` output, `log/symphony.log`.
- Repair before retry for `temporal_unreachable`, `temporal_namespace_missing`, `temporal_namespace_unavailable`, `temporal_worker_missing`, or `temporal_worker_probe_failed`.

### Temporal Worker

- Remote triage:

  ```bash
  tail -n 200 .symphony/dev/temporal-k3s/logs/worker.log
  ps -fp "$(cat .symphony/dev/temporal-k3s/worker.pid)"
  ./dev/temporal-k3s status
  ```

- Local regression:

  ```bash
  cd temporal && GOCACHE=/tmp/symphony-go-build go test ./...
  ```

- Primary evidence: `.symphony/dev/temporal-k3s/logs/worker.log`, helper readiness blockers, workflow `describe` output.
- Repair before retry when the worker is absent, using stale Temporal settings, or failing to poll the configured task queue.

### K3s Launcher And Job Runtime

- Remote triage:

  ```bash
  ./k3s/bin/docker-kubectl get jobs,pods -n symphony
  ./k3s/bin/sjob status --project-id <project_id> --job <job_name> --namespace symphony --output json | jq
  ./k3s/bin/docker-kubectl logs -n symphony job/<job_name> --all-containers=true
  ```

- Local regression:

  ```bash
  cd elixir && /home/phi9t/.local/bin/mise exec -- mix test test/symphony_elixir/k3s_launcher_test.exs
  shellcheck dev/temporal-k3s k3s/bin/* k3s/lib/*.sh temporal/bin/*
  bash -n dev/temporal-k3s k3s/bin/* k3s/lib/*.sh temporal/bin/*
  ```

- Primary evidence: K3s job/pod status, K3s logs, copied artifact bundle, repo-managed smoke evidence.
- Repair before retry for `k3s_launcher_missing`, `k3s_namespace_missing`, `k3s_prerequisites_broken`, image-pull failures, permissions errors, or OOM-killed jobs.

### Cleanup And Workspace Removal

- Remote triage:

  ```bash
  find "${SYMPHONY_K3S_PROJECT_ROOT:-$PWD/.symphony/dev/projects}" -maxdepth 2 -type f -name metadata.json | sort
  jq . "${SYMPHONY_K3S_PROJECT_ROOT:-$PWD/.symphony/dev/projects}/<project_id>/outputs/<run_id>/metadata.json"
  find "${SYMPHONY_K3S_PROJECT_ROOT:-$PWD/.symphony/dev/projects}" -maxdepth 1 -type d -name '<project_id>*'
  ```

- Local regression or repair:

  ```bash
  cd elixir && /home/phi9t/.local/bin/mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs
  cd elixir && /home/phi9t/.local/bin/mise exec -- mix workspace.before_remove --repo phi9t/oai-symphony --branch <branch>
  ```

- Primary evidence: `metadata.json` `cleanupError`, `log/symphony.log`, lingering project roots or local workspaces.
- Repair before retry when cleanup hooks, GitHub auth, or filesystem permissions prevent workspace removal.

## Retry Versus Repair

- Retry only after the failing plane is named and evidence is captured. A blind retry that destroys the only artifact bundle is a triage failure.
- Repair first for readiness blockers and contract errors: `temporal_unreachable`, `temporal_namespace_missing`, `temporal_namespace_unavailable`, `temporal_worker_missing`, `temporal_worker_probe_failed`, `k3s_launcher_missing`, `k3s_namespace_missing`, `k3s_prerequisites_broken`, `org_workpad_sync_failed`, `org_state_sync_failed`, `invalid_run_result_target_state`, `missing_run_result`, and `malformed_run_result`.
- Retry after repair or after proving a transient cause for `temporal_status_timeout`, `temporal_workflow_failed`, `temporal_run_failed`, `temporal_workflow_cancelled`, or a worker stall. Use helper `describe`, worker logs, job logs, and the artifact bundle to decide whether the failure was infrastructure-only or a real implementation bug.
- Cleanup failures are not a reason to delete evidence. Capture `metadata.json`, preserve the project root, repair the hook or permission problem, and only then rerun cleanup.
