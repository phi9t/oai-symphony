# RFC Process

Use RFCs for major architecture, runtime, workflow, process, or product-surface changes that are too broad for a normal issue description. Each proposal lives in its own file under `docs/rfcs/` using `RFC-####-short-slug.md`.

## Lifecycle

1. Draft
   Create a new RFC from [`0000-template.md`](/mnt/data_infra/workspace/symphony/docs/rfcs/0000-template.md). The author may be an agent or a human. Fill in the problem, proposal, risks, rollout, and validation sections before asking for review.
2. Review
   Ask at least two other agents to review the RFC. Reviews are appended to the same file under `## Reviews`, one subsection per reviewer. Each reviewer records:
   - `Vote`: `+1` approve, `0` neutral/defer, `-1` block
   - `Summary`
   - `Concerns`
   - `Required changes` or `nits`
3. Vote and decision
   Move the RFC to `Accepted` when it has at least two `+1` votes and no unresolved `-1`. Keep it `Under Review` if blockers remain. Use `Deferred`, `Rejected`, or `Superseded` when the proposal should not move forward.
4. Task extraction
   Once accepted, a planning agent converts the RFC into Org work using `org_task.deep_revision`.
   - Use `mode: "create"` when the follow-on tasks are clear and implementation-ready.
   - Use `mode: "draft"` when the RFC is accepted but task boundaries are still uncertain.
5. Closure
   Link created tasks back into the RFC under `## Derived Tasks`. When the implementation lands, update the RFC status to `Implemented`.

## Agent Roles

- Author agent: drafts the RFC and updates it as feedback arrives.
- Reviewer agents: challenge assumptions, propose alternatives, and vote.
- Planning agent: turns accepted RFCs into actionable Org tasks with title, description, acceptance criteria, priority, and validation steps.

## Required Content

Every RFC must include:

- a concise problem statement
- the proposed change and non-goals
- alternatives considered
- operational and testing impact
- rollout and rollback notes
- explicit validation steps

## Conventions

- Keep one proposal per RFC file.
- Prefer additive review notes over rewriting another reviewer’s section.
- If an RFC materially changes after review, increment the `Revision` field and ask reviewers to refresh their votes.
- If the proposal is very uncertain, stop at the RFC and do not create Org tasks yet.
