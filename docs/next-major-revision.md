# Next Major Revision Plan

## Objective

The next major revision should make Symphony bootstrapable, self-hosting, and operationally credible on a fresh machine. The first milestone is not new product surface area; it is proving that Symphony can plan, launch, monitor, and repair its own work through the orchestrator with minimal manual intervention.

## Why This Revision

The current repo has the core pieces for Org tracking, local execution, and a Temporal/K3s path, but the operator story is still weak:

- there is no turnkey bootstrap for an Org-backed first run
- the remote backend depends on external Temporal and Kubernetes infrastructure that is not repo-managed
- local and remote execution follow different completion contracts
- the repo lacks an end-to-end self-hosting smoke path that catches orchestration regressions early

## Revision Tracks

### 1. Self-Hosting Bootstrap

Ship a repo-owned workflow, tracker seed, and smoke command that let Symphony claim an Org task and complete a supervised first run locally.

### 2. Remote Backend Bring-Up

Turn the Temporal/K3s path into a deployable developer workflow with repeatable startup, health checks, and cleanup. The target is a documented `dev up` path, not an operator guessing which services must already exist.

### 3. Durable Control Plane Semantics

Align local and remote execution around one task lifecycle, one workpad model, and explicit continuation rules. Remove avoidable branching between `org_task` and artifact-driven flows where possible.

### 4. Reliability and Recovery

Add end-to-end tests for restarts, cancellations, stuck runs, and malformed agent outputs. A restart should preserve enough state to reconcile safely instead of forcing manual cleanup.

### 5. Operator Visibility

Expand the dashboard and logs so an engineer can answer four questions quickly: what is running, why it is blocked, what it changed, and what should happen next.

## Execution Order

1. `REV-1`: Bootstrap a repeatable self-hosted local run.
2. `REV-2`: Make Temporal/K3s bring-up reproducible.
3. `REV-3`: Unify lifecycle and tracker semantics.
4. `REV-4`: Add failure-injection and end-to-end coverage.
5. `REV-5`: Improve dashboard and operator controls.

The Org tracker in `.symphony/revision-plan.org` is the execution source of truth for this revision.
