# Next Major Revision Plan

## Objective

The next major revision should turn the current bootstrap into a maintainable control plane. The repository can now self-host and run through Org-backed workflows, but the next phase needs cleaner module boundaries, better test leverage, a firmer cross-language contract, and a planning lane that can expand the queue safely.

## Why This Revision

The main structural pressure points are now visible in the codebase:

- several Elixir modules are too large and mix unrelated concerns
- the test suite is concentrated in a few giant files that are hard to extend safely
- Elixir, Go, shell, and agent artifacts still share implicit JSON contracts
- the `temporal_k3s` backend exists, but the repo still relies on the local runner for actual unattended task execution
- operator-facing dashboard logic is tightly coupled to orchestrator state shaping
- planning is possible through Org, but not yet operationalized as a first-class workflow

## Revision Tracks

### 1. Reliability and Recovery

Build reusable cross-backend recovery coverage for restart, cancellation, malformed output, stuck turns, and workspace cleanup.

### 2. Temporal/K3s Runtime Adoption

Make `temporal_k3s` the preferred runtime for real task execution on supported hosts, with clear readiness checks, worker/runtime observability, and at least one end-to-end smoke or self-landing path.

### 3. Operator Projections and Controls

Split dashboard projection and operator controls away from raw orchestrator state so the Phoenix surface can evolve cleanly.

### 4. Elixir Control-Plane Boundaries

Decompose `Config`, `Orchestrator`, `StatusDashboard`, `Codex.AppServer`, and `Codex.DynamicTool` into bounded collaborators with stable public facades.

### 5. Test Harness Structure

Replace giant test files with reusable scenario builders and fixtures that match the new module boundaries.

### 6. Cross-Language Contracts

Version the execution contract between Elixir, Go, K3s launchers, and `.symphony` artifacts so compatibility is explicit and testable.

### 7. Planning Workflow

Operationalize deep-dive and deep-revision runs so Symphony can grow the Org queue itself when the next work is clear.

## Execution Order

1. `REV-4`: Add cross-backend recovery and failure-injection coverage.
2. `REV-16`: Make Temporal/K3s the preferred task execution runtime.
3. `REV-5`: Separate operator projections and control points.
4. `REV-12`: Split oversized Elixir control-plane modules.
5. `REV-13`: Reorganize the test harness around reusable scenarios.
6. `REV-14`: Version the cross-language execution contract.
7. `REV-15`: Operationalize deep-dive and deep-revision planning runs.

The Org tracker in `.symphony/revision-plan.org` is the execution source of truth for this revision.
