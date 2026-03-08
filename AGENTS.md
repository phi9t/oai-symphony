# Repository Guidelines

## Project Structure & Module Organization

This repository has two layers:

- Root files define the project contract and shared docs: `README.md`, `SPEC.md`, and `.github/`.
- `elixir/` contains the active reference implementation. Core runtime code lives in `elixir/lib/symphony_elixir/`, web and dashboard code in `elixir/lib/symphony_elixir_web/`, config in `elixir/config/`, static assets in `elixir/priv/static/`, and tests in `elixir/test/`.

Keep implementation changes aligned with [`SPEC.md`](/mnt/data_infra/workspace/symphony/SPEC.md). If behavior or configuration changes, update the matching docs in `README.md`, `elixir/README.md`, and `elixir/WORKFLOW.md` in the same PR.

## Build, Test, and Development Commands

Run commands from the repository root unless noted otherwise:

- `mise install` then `cd elixir && mise exec -- mix setup`: install Elixir/Erlang and fetch deps.
- `make -C elixir build`: build the `bin/symphony` escript.
- `make -C elixir test`: run ExUnit tests.
- `make -C elixir coverage`: run tests with coverage enforcement.
- `make -C elixir lint`: run `mix specs.check` and strict Credo.
- `make -C elixir all`: full local gate; use this before opening a PR.

## Coding Style & Naming Conventions

Use standard Elixir style: 2-space indentation, snake_case filenames, and PascalCase module names such as `SymphonyElixir.Orchestrator`. Format with `mix format`; the repo formatter uses `elixir/.formatter.exs` with a 200-character line limit.

Public functions in `elixir/lib/` must have adjacent `@spec` declarations unless they are `@impl` callbacks. Route configuration reads through `SymphonyElixir.Config`; do not add ad hoc environment lookups.

## Testing Guidelines

Tests use ExUnit and live under `elixir/test/` with filenames ending in `_test.exs`. Snapshot fixtures for dashboard output live in `elixir/test/fixtures/status_dashboard_snapshots/`.

The project sets a 100% coverage summary threshold in `elixir/mix.exs`, so add or update tests with every behavioral change. Prefer targeted runs while iterating, then finish with `make -C elixir all`.

## Commit & Pull Request Guidelines

Recent commits use short, imperative subjects, sometimes with a PR reference, for example `Move Elixir observability dashboard to Phoenix (#29)`. Keep commits narrowly scoped and avoid unrelated refactors.

PRs must follow `.github/pull_request_template.md` exactly: fill in `Context`, `TL;DR`, `Summary`, `Alternatives`, and `Test Plan`. Include targeted validation steps, and attach screenshots when changing the Phoenix dashboard or other user-visible output.
