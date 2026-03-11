# Azure DevOps Wrap Plan

## Current Execution Status

Real status in the current local worktree on `devops-wrapper` as of `2026-03-11`:

- `US-01`: implemented locally, not committed, no PR, not merged
- `US-02`: implemented locally, not committed, no PR, not merged
- `US-03`: implemented locally, not committed, no PR, not merged
- `US-04`: implemented locally, not committed, no PR, not merged
- `US-05`: pending
- `US-06`: pending
- `US-07`: pending
- `US-08`: pending
- `US-09`: pending

This status reflects the current checkout only. It does not imply branch handoff, PR creation, or
merge completion for any story.

Operator-approved baseline exception as of `2026-03-11`:

- `US-01` is integrated in `Danigm-dev/symphony:devops-wrapper` at
  `f38b29a3f2c0625f7641a63da0209b1704403c69`.
- `US-02` through `US-05` are accepted as a grouped local baseline at commit `158998b`
  (`Stack local Azure base through US-05`) for the limited purpose of starting `US-06` and later
  stories on top of that baseline.
- This exception does not retroactively mean `US-02` through `US-05` satisfy the normal operational
  closure contract of branch + commit + PR + merge per story.

## Goal

Extend Symphony so it supports a second full provider path, Azure Boards + Azure Repos, without removing or weakening the existing Linear + GitHub path.

This is not a tracker-only change. The current implementation couples:

- issue polling and reconciliation to Linear
- dynamic agent tooling to `linear_graphql`
- workpad/comment workflow to Linear
- PR creation, review sweep, merge, and cleanup to GitHub CLI and GitHub-specific skills

The Azure DevOps path must be additive. Existing Linear + GitHub behavior should stay behaviorally identical.

Authentication for Azure DevOps v1 should use a PAT from environment variables.

## Current Repo Context

Key integration points in the current codebase:

- Tracker abstraction exists but only routes `linear | memory`: `elixir/lib/symphony_elixir/tracker.ex`
- Config validation only supports `linear | memory` and requires Linear-specific token/project fields: `elixir/lib/symphony_elixir/config.ex`
- Core runtime is typed around `SymphonyElixir.Linear.Issue`:
  - `elixir/lib/symphony_elixir/orchestrator.ex`
  - `elixir/lib/symphony_elixir/agent_runner.ex`
  - `elixir/lib/symphony_elixir/prompt_builder.ex`
  - `elixir/lib/symphony_elixir/tracker/memory.ex`
- Linear implementation:
  - `elixir/lib/symphony_elixir/linear/client.ex`
  - `elixir/lib/symphony_elixir/linear/adapter.ex`
  - `elixir/lib/symphony_elixir/linear/issue.ex`
- Dynamic tooling is Linear-only via `linear_graphql`: `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- Dashboard/status surface contains Linear-specific project link rendering: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Workflow and skills assume Linear + GitHub:
  - `elixir/WORKFLOW.md`
  - `.codex/skills/linear/SKILL.md`
  - `.codex/skills/push/SKILL.md`
  - `.codex/skills/land/SKILL.md`
  - `elixir/lib/mix/tasks/workspace.before_remove.ex`

## Design Goals

- Keep the existing Linear + GitHub path behaviorally identical.
- Add Azure DevOps in a provider-aware way rather than forking the runtime.
- Preserve the Symphony operating model:
  - active-state polling
  - isolated workspaces
  - retry/reconcile logic
  - one persistent workpad comment
  - PR feedback sweep before handoff
  - explicit merge/land stage
- Avoid inventing Azure-specific workflow semantics when the existing Symphony semantics can be preserved through mapping and config.

## Implementation Plan

### 1. Generalize the normalized issue model

Introduce a provider-neutral issue type, for example `SymphonyElixir.Issue`, containing the fields the runtime already depends on:

- `id`
- `identifier`
- `title`
- `description`
- `priority`
- `state`
- `branch_name`
- `url`
- `assignee_id`
- `blocked_by`
- `labels`
- `assigned_to_worker`
- `created_at`
- `updated_at`

Refactor the runtime to use this neutral type in:

- `orchestrator`
- `agent_runner`
- `prompt_builder`
- `tracker/memory`

Keep `SymphonyElixir.Linear.Issue` as a compatibility layer or thin wrapper so current tests and code can migrate incrementally without changing behavior.

### 2. Extend config to support Azure DevOps

Preserve the existing tracker keys for Linear.

Add support for `tracker.kind: azure_devops` with PAT-based auth and Azure-specific routing fields. Reuse generic keys where possible.

Required or primary fields for Azure:

- `tracker.kind: azure_devops`
- `tracker.endpoint`
  - Recommended shape: `https://dev.azure.com/<organization>`
- `tracker.project`
- `tracker.api_key`
  - Default env fallback: `AZURE_DEVOPS_TOKEN`

Optional Azure fields:

- `tracker.assignee`
  - Default env fallback: `AZURE_DEVOPS_ASSIGNEE`
- `tracker.active_states`
- `tracker.terminal_states`
- `tracker.wiql`
- `tracker.work_item_types`
- `tracker.area_paths`
- `tracker.iteration_path`
- `tracker.api_version`
  - Default: `7.1`

Behavior:

- If `tracker.wiql` is present for Azure, it becomes the candidate-selection source of truth.
- Otherwise, build a WIQL query from project + active states + optional assignee/type/area/iteration filters.
- Keep the current single-project-per-workflow scope because that matches the current Linear implementation scope.

### 3. Add Azure Boards provider

Create Azure provider modules analogous to the Linear ones:

- `SymphonyElixir.AzureDevOps.Client`
- `SymphonyElixir.AzureDevOps.Adapter`

Supported tracker operations should match the current adapter boundary:

- `fetch_candidate_issues/0`
- `fetch_issues_by_states/1`
- `fetch_issue_states_by_ids/1`
- `create_comment/2`
- `update_issue_state/2`

Azure Boards implementation requirements:

- Use WIQL to obtain candidate work item ids.
- Use batch work item fetches to hydrate normalized issue payloads.
- Use JSON Patch updates for state changes.
- Use Azure work item comments APIs to create and edit the persistent workpad comment.
- Resolve `tracker.assignee: me` against the authenticated Azure identity.
- Map Azure relations and dependencies into `blocked_by` so the current dispatch eligibility logic is preserved.
- Preserve issue URL rendering with Azure DevOps work item URLs.

Do not degrade the current reconciliation logic:

- running issue refresh must still stop, retry, or release based on active vs terminal state
- blocker changes must still affect dispatch eligibility

### 4. Make core runtime provider-aware but not provider-specific

Refactor existing Linear-specific naming and messages in the runtime where needed:

- orchestrator log and error text
- continuation guidance text
- prompt builder module docs
- any active-state checks that currently call `Config.linear_active_states()` directly

Introduce generic config accessors for:

- tracker endpoint
- tracker token
- tracker assignee
- tracker active states
- tracker terminal states
- optional tracker project reference

Keep Linear-specific accessors as compatibility wrappers during migration if that reduces risk.

### 5. Add Azure dynamic tooling for the agent

Do not remove `linear_graphql`.

Add a second dynamic tool for Azure, for example `azure_devops_request`.

Input contract:

- `method`
- `path`
- `query` optional object
- `body` optional JSON object, array, or string

Behavior:

- Only call the configured Azure DevOps endpoint.
- Reuse Symphony's configured Azure PAT.
- Return JSON payloads as tool text, in the same style as `linear_graphql`.
- Fail cleanly for missing auth, invalid method/path/body, or HTTP error status.

Purpose:

- give repo skills and workflow prompts a raw Azure DevOps escape hatch similar to what `linear_graphql` does for Linear
- allow workpad edits, PR linking, reviewer/thread handling, and other ad hoc provider interactions without hardcoding every mutation into the runtime

### 6. Add Azure-specific repo skills while preserving existing names where needed

Keep existing `linear`, `push`, and `land` flows working for GitHub.

Add:

- `.codex/skills/azure_devops/SKILL.md`

Update provider-sensitive skills so they can branch by detected provider:

- `push`
- `land`

Target behavior for Azure Repos path in `push`:

- run validation locally
- push branch to `origin`
- locate existing PR by source branch
- create PR if missing
- update title and body if existing
- if branch is tied to a closed or completed PR, create a new branch + PR
- apply Symphony label or tag if supported in the Azure setup; otherwise record equivalent metadata in the PR title, body, or work item link policy
- ensure the work item is linked to the PR

Target behavior for Azure Repos path in `land`:

- inspect PR status, mergeability, reviewers, comment threads, and policy/build status
- treat actionable unresolved review feedback as blocking
- wait for required policies/build validations to pass
- complete the PR with squash
- preserve the current "keep looping until landed unless blocked" posture

Target behavior for cleanup:

- replace `workspace.before_remove` with provider-aware logic
- GitHub path stays unchanged
- Azure path abandons or closes open PRs for the branch and posts an equivalent closing rationale tied to terminal tracker state

### 7. Define Azure parity for workpad and PR linkage

Preserve the existing Symphony workflow semantics:

- one persistent `## Codex Workpad`
- workpad updated in place
- PR linked to the ticket before human handoff
- review sweep completed before `Human Review`

Azure workpad policy:

- use Azure Boards comments on the work item
- locate the existing workpad by marker header
- update that same comment in place when possible
- only create a new workpad when none exists or when the workflow intentionally resets it during `Rework`

Azure PR linkage policy:

- primary: link the work item to the PR using Azure Repos work-item linking
- secondary safety net: include `AB#<work_item_id>` in title or body so linkage survives client differences
- fallback evidence: if direct link mutation is unavailable, post the PR URL in the workpad and mark the link as blocked-but-recorded

### 8. Add Azure workflow example without changing the Linear one

Keep `elixir/WORKFLOW.md` as the Linear example.

Add a second example workflow:

- `elixir/WORKFLOW.azure_devops.md`

The Azure workflow should preserve the same Symphony stages and instructions:

- `Todo`
- `In Progress`
- `Rework`
- `Human Review`
- `Merging`
- terminal states

Do not force a different Azure-only workflow model in the runtime. If Azure Boards in a target org cannot support those names directly, the copied workflow can map to local state names through config and prompt conventions.

The prompt text should be rewritten for Azure terminology only where needed:

- "work item" instead of "Linear ticket"
- Azure Boards comments instead of Linear comments
- Azure Repos PR threads, reviewers, and policies instead of GitHub review APIs

### 9. Update docs and spec carefully

Update docs so the repo clearly supports both provider paths:

- root contributor docs if needed
- `elixir/README.md`
- provider setup docs for Azure PAT
- workflow examples

Update `SPEC.md` in an additive way:

- stop saying only Linear is supported
- define the generic tracker contract as the real invariant
- keep Linear requirements as one provider-specific section
- add Azure DevOps provider-specific section
- keep the normalized issue contract unchanged

## Public Interfaces and Config Additions

New or changed external interfaces:

### Workflow config

Azure additions:

- `tracker.kind: azure_devops`
- `tracker.endpoint`
- `tracker.project`
- `tracker.api_key`
- `tracker.assignee`
- `tracker.wiql`
- `tracker.work_item_types`
- `tracker.area_paths`
- `tracker.iteration_path`
- `tracker.api_version`

### Environment variables

Azure v1:

- `AZURE_DEVOPS_TOKEN`
- `AZURE_DEVOPS_ASSIGNEE`

### Dynamic tools

Keep:

- `linear_graphql`

Add:

- `azure_devops_request`

### Skills

Keep existing:

- `linear`
- `push`
- `land`

Add:

- `azure_devops`

## Test Plan

### Regression coverage for existing provider

- All current Linear tests must stay green without semantic changes.
- Existing GitHub-oriented flows must continue to work unchanged.

### New config and provider tests

- config accepts `tracker.kind: azure_devops`
- PAT resolves from `AZURE_DEVOPS_TOKEN`
- assignee resolves from `AZURE_DEVOPS_ASSIGNEE`
- Azure required fields validate correctly
- `tracker.wiql` precedence works as intended

### Azure client normalization tests

- WIQL candidate fetch returns normalized issues
- batch hydration produces the neutral issue type correctly
- labels, priority, assignee, timestamps, URL, branch name, blockers map correctly
- missing optional fields do not break polling
- `assignee: me` resolution works
- state patch and comment create or update succeed

### Runtime behavior tests

- dispatch honors Azure active states
- terminal cleanup honors Azure terminal states
- reconciliation stops or retries workers correctly for Azure issues
- blocker changes affect eligibility the same way they do today
- continuation turns still behave identically regardless of provider

### Dynamic tool tests

- `azure_devops_request` validates inputs
- missing PAT returns a structured failure
- non-2xx responses return structured failures
- base URL escaping or cross-host requests are rejected

### Azure Repos workflow tests

- create PR when missing
- update PR when open
- recover when branch is tied to completed or abandoned PR
- review or comment sweep detects blocking feedback
- policy or build gating blocks merge until green
- squash completion succeeds
- terminal cleanup abandons open PRs for the issue branch

## Official Azure API Surface to Use

Use official Azure DevOps REST APIs as primary sources:

- Work Item Query Language (WIQL)
- Work Items batch/get/update
- work item comments
- pull requests create/get/list/update
- PR reviewers
- PR threads/comments
- labels/tags if available in the target repo policy
- policy evaluations / build status endpoints

## Assumptions and Defaults

- Azure integration target is Azure DevOps Services cloud, not on-prem Azure DevOps Server.
- Authentication for v1 is PAT-only.
- Scope matches the current Linear implementation scope: one project per workflow file.
- The existing Symphony flow is the invariant; Azure support should wrap or adapt to it rather than redefine it.
- "Do not lose functionality" means:
  - no feature regression for Linear/GitHub
  - Azure path must support the same operational lifecycle, not necessarily the exact same API shapes
- If a feature exists only because of GitHub- or Linear-specific APIs, keep it on that provider and provide the closest Azure equivalent without removing the original feature.

## Recommended Implementation Order

1. Introduce the neutral issue model and generic config accessors.
2. Add the Azure tracker adapter and client with tests.
3. Refactor the runtime to provider-neutral state access.
4. Add `azure_devops_request`.
5. Add the Azure Boards skill.
6. Make `push`, `land`, and cleanup provider-aware for Azure Repos.
7. Add the Azure workflow example and docs.
8. Expand integration and regression coverage and rerun the full gate.

## Multi-CLI Delivery Rules

Use the plan below as the execution backlog. The goal is to let different CLIs take one story at a
time without stepping on the same files or silently depending on half-finished work.

### Branch strategy

- Integration branch for this effort: `devops-wrapper`
- Every story branch must be created from the latest `devops-wrapper`, not from `main`.
- Every story PR/merge target must be `devops-wrapper`.
- If `openai/symphony` is not writable from the current environment or does not yet have
  `devops-wrapper`, bootstrap and use a writable fork while keeping the same branch strategy.
- Current writable integration repo for this execution chain:
  - `Danigm-dev/symphony`
  - Integration branch: `devops-wrapper`
  - `US-01` merged there at `f38b29a3f2c0625f7641a63da0209b1704403c69`
- Until `openai/symphony:devops-wrapper` exists and is writable, every later story must branch from
  the latest `Danigm-dev/symphony:devops-wrapper` and merge back into that same branch.
- Recommended story branch naming:
  - `dw-us-01-neutral-issue-contract`
  - `dw-us-02-config-routing`
  - `dw-us-03-provider-aware-runtime`
  - `dw-us-04-azure-read-adapter`
  - `dw-us-05-azure-write-path`
  - `dw-us-06-azure-dynamic-tool`
  - `dw-us-07-azure-skills-cleanup`
  - `dw-us-08-azure-docs-spec`
  - `dw-us-09-azure-hardening`
- Do not use branch names like `devops-wrapper/us-01-...` because Git ref naming will collide with
  the integration branch `devops-wrapper`.

- One story per branch/CLI.
- Each CLI branch must start from the latest `devops-wrapper` that already contains all listed
  dependencies.
- If the previous story handoff records a fork fallback, the next CLI must continue from that same
  fork and must not silently jump back to `origin/main` or an outdated upstream checkout.
- Do not start a story until every dependency listed for that story is merged.
- If a story needs files owned by a later story, stop and split a follow-up instead of widening the
  scope.
- Every story must leave the Linear + GitHub path green before handoff.
- When a story mentions skill files outside this repo tree, treat those files as part of the same
  change set but keep ownership exclusive to that story.

### CLI execution contract

Every CLI working a story must follow these rules:

- Change only the files listed in `Owns files`, plus directly related tests for those files.
- Do not refactor shared infrastructure "while here" unless that refactor is explicitly inside the
  story scope.
- Do not pull work from a later story just because the current story makes it tempting.
- If a missing capability is discovered outside the story scope, stop at the boundary, document the
  blocker, and leave it for the owning story.
- Do not edit docs/spec files owned by a later story except for minimal notes required to keep the
  current story accurate.
- Handoff for each story must include: changed files, tests run, acceptance criteria status, and
  any newly discovered follow-up items.
- A story is not done until its acceptance criteria are satisfied without weakening existing Linear
  or GitHub behavior.

## User Story Backlog

### US-01: Introduce a provider-neutral issue contract

**User story**
As a Symphony maintainer, I want the runtime to depend on a neutral issue struct so Azure can be
added without forking the orchestration flow.

**Depends on**
- None

**Owns files**
- `elixir/lib/symphony_elixir/issue.ex` (new)
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/prompt_builder.ex`
- `elixir/lib/symphony_elixir/tracker/memory.ex`
- `elixir/lib/symphony_elixir/linear/issue.ex`
- runtime tests that currently assume `SymphonyElixir.Linear.Issue`

**Scope**
- Add `SymphonyElixir.Issue` with the normalized fields required by the runtime.
- Refactor runtime modules to accept the neutral issue type.
- Keep `SymphonyElixir.Linear.Issue` as a compatibility layer or conversion wrapper.

**Acceptance criteria**
- The runtime compiles and runs against `SymphonyElixir.Issue`.
- Existing Linear behavior stays unchanged.
- Existing memory tracker behavior stays unchanged.
- Current tests for the Linear path remain green after the refactor.

**Do not include**
- Azure-specific config
- Azure HTTP client work
- dynamic tool changes

### US-02: Extend config and tracker routing for provider awareness

**User story**
As a Symphony operator, I want `WORKFLOW.md` to describe either Linear or Azure DevOps so the
runtime can validate the right config without guessing.

**Depends on**
- US-01

**Owns files**
- `elixir/lib/symphony_elixir/config.ex`
- `elixir/lib/symphony_elixir/tracker.ex`
- config and workflow validation tests

**Scope**
- Add `tracker.kind: azure_devops`.
- Add Azure config fields and env fallbacks.
- Introduce generic tracker accessors alongside Linear compatibility wrappers.
- Route `Tracker.adapter/0` by provider kind.

**Acceptance criteria**
- Linear config remains valid and behaviorally identical.
- Azure config validates required fields and env fallbacks correctly.
- Generic accessors exist for endpoint, token, assignee, active states, terminal states, and
  project reference.
- Unsupported tracker kinds still fail with explicit errors.

**Do not include**
- Runtime copy or log wording changes
- Azure adapter implementation

### US-03: Make the runtime provider-aware without changing behavior

**User story**
As a Symphony maintainer, I want runtime logic to read provider-neutral config and messages so a
second provider can plug in without special-case branching through the core loop.

**Depends on**
- US-01
- US-02

**Owns files**
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/prompt_builder.ex`
- `elixir/lib/symphony_elixir/status_dashboard.ex`
- runtime behavior and dashboard tests

**Scope**
- Replace Linear-specific config reads with generic tracker accessors.
- Generalize log, error, and continuation text where needed.
- Remove Linear-only assumptions from dashboard link rendering and docs strings.

**Acceptance criteria**
- Active and terminal state checks use generic config accessors.
- Runtime log and error text no longer claim every provider is Linear.
- Dashboard still renders correctly for the existing Linear path.
- No behavior regression in reconciliation, retry, or continuation logic.

**Do not include**
- Azure API calls
- skill updates

### US-04: Add the Azure Boards read adapter

**User story**
As a Symphony operator, I want Azure Boards work items normalized into Symphony issues so polling,
dispatch, and blocker gating can work against Azure.

**Depends on**
- US-01
- US-02

**Owns files**
- `elixir/lib/symphony_elixir/azure_devops/client.ex` (new)
- `elixir/lib/symphony_elixir/azure_devops/adapter.ex` (new)
- Azure adapter read-path tests

**Scope**
- Implement WIQL candidate discovery.
- Implement batch work item hydration into `SymphonyElixir.Issue`.
- Implement `fetch_candidate_issues/0`, `fetch_issues_by_states/1`, and
  `fetch_issue_states_by_ids/1`.
- Resolve `tracker.assignee: me`.
- Map Azure dependency relations into `blocked_by`.

**Acceptance criteria**
- Candidate polling returns normalized issues from Azure.
- State refresh works for running issue reconciliation.
- URLs, timestamps, labels, priority, branch name, and blockers are mapped consistently.
- Missing optional Azure fields do not break polling.

**Do not include**
- state mutation
- comment mutation
- dynamic tool work

### US-05: Add the Azure Boards write path

**User story**
As a Symphony operator, I want Azure write primitives for state transitions and comments so the
workflow can move work items and maintain tracker-side execution state.

**Depends on**
- US-04

**Owns files**
- `elixir/lib/symphony_elixir/azure_devops/client.ex`
- `elixir/lib/symphony_elixir/azure_devops/adapter.ex`
- Azure adapter write-path tests

**Scope**
- Implement work item state updates via JSON Patch.
- Implement comment create/list/update helpers in the Azure client.
- Wire `update_issue_state/2` through the Azure adapter.
- Keep the public tracker boundary stable unless a separate follow-up is explicitly required.

**Acceptance criteria**
- Azure state transitions succeed through the tracker adapter.
- Azure comment primitives exist for later workpad reuse/update flows.
- Error handling mirrors current Symphony behavior: structured failures, no silent no-ops.
- Linear adapter behavior remains unchanged.

**Do not include**
- provider-aware repo skills
- workflow docs

### US-06: Add the Azure dynamic tool

**User story**
As a Codex agent, I want a raw Azure DevOps request tool so skill flows can perform Azure Boards
and Azure Repos operations that are not worth hardcoding into the runtime.

**Depends on**
- US-02
- US-05

**Owns files**
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- dynamic tool tests
- shared Azure HTTP helper code if needed by the tool

**Scope**
- Add `azure_devops_request`.
- Validate `method`, `path`, optional `query`, and optional `body`.
- Enforce same-host requests against the configured Azure endpoint.
- Reuse Symphony-configured Azure auth.

**Acceptance criteria**
- Tool specs advertise both provider-appropriate tools.
- Missing auth, invalid input, non-2xx responses, and cross-host paths fail cleanly.
- JSON responses are returned in the same style as `linear_graphql`.
- Existing `linear_graphql` behavior is unchanged.

**Do not include**
- push/land policy logic
- cleanup task refactor

### US-07: Add Azure Repos operational skills and cleanup

**User story**
As a Symphony operator, I want `push`, `land`, and cleanup flows to work with Azure Repos so the
Azure path can complete the same operational lifecycle as the GitHub path.

**Depends on**
- US-03
- US-06

**Owns files**
- `.codex/skills/azure_devops/SKILL.md` (or the equivalent skills repo path)
- `.codex/skills/push/SKILL.md` (or the equivalent skills repo path)
- `.codex/skills/land/SKILL.md` (or the equivalent skills repo path)
- `elixir/lib/mix/tasks/workspace.before_remove.ex`
- cleanup and workflow task tests

**Scope**
- Add an Azure-specific skill entry point.
- Make `push` provider-aware for Azure PR create/update/recreate flows.
- Make `land` provider-aware for reviewer, thread, policy, and squash-complete flows.
- Make workspace cleanup provider-aware so Azure PRs are abandoned or closed with rationale.
- Implement Azure workpad find/create/reuse/update flow using Azure Boards comments.
- Implement PR linkage behavior with this order: direct work-item link, `AB#<id>` safety net, and
  workpad evidence fallback when direct linking is unavailable.
- Apply Symphony label/tag metadata when supported, or record the equivalent metadata in the PR
  title/body or link policy path.

**Acceptance criteria**
- GitHub flows still work unchanged.
- Azure push flow can create, update, or recreate PRs as needed.
- Azure push flow records the expected Symphony metadata and links the work item to the PR before
  human handoff.
- Azure land flow blocks on unresolved review feedback and pending policies.
- Azure land preserves the current "keep looping until landed unless blocked" posture.
- Cleanup handles Azure PR shutdown without changing GitHub semantics.
- Exactly one persistent `## Codex Workpad` comment is reused for an active Azure work item unless
  the workflow intentionally resets it during `Rework`.
- If direct PR linking is unavailable, the PR URL is still recorded in the workpad as
  blocked-but-recorded evidence.

**Do not include**
- new tracker polling behavior
- unrelated runtime refactors

### US-08: Document the Azure workflow and operator contract

**User story**
As a Symphony operator, I want Azure-specific workflow documentation so I can configure and run the
new provider path without modifying the existing Linear example.

**Depends on**
- US-02
- US-07

**Owns files**
- `elixir/WORKFLOW.azure_devops.md` (new)
- `elixir/README.md`
- `SPEC.md`
- any Azure-specific docs cross-links needed from existing docs

**Scope**
- Add a complete Azure workflow example.
- Document Azure env vars, config keys, and provider-specific skill expectations.
- Document workpad and PR-linkage policy for Azure.
- Update `SPEC.md` additively so the generic tracker contract becomes the invariant and Linear/Azure
  are provider-specific sections.
- Rewrite Azure-facing workflow wording only where terminology must differ from Linear/GitHub.

**Acceptance criteria**
- Linear workflow docs stay intact.
- Azure example is sufficient to bootstrap a real workflow file.
- Docs explain the fallback/linkage rules when direct PR linking is unavailable.
- `SPEC.md` no longer implies Linear is the only supported provider.

**Do not include**
- new feature code beyond documentation-only nits

### US-09: Close the parity gap with integration and regression coverage

**User story**
As a maintainer, I want explicit parity coverage for the Azure path so we can merge the provider
additively without regressing Linear + GitHub.

**Depends on**
- US-03
- US-05
- US-06
- US-07
- US-08

**Owns files**
- cross-cutting tests only
- validation notes or release checklist docs if needed

**Scope**
- Add missing regression coverage across config, runtime reconciliation, dynamic tooling, Azure
  adapter behavior, and cleanup flow.
- Run the full quality gate after targeted test gaps are closed.

**Acceptance criteria**
- Linear regression suite remains green.
- Azure-specific tests cover candidate polling, state refresh, state mutation, tool validation, and
  cleanup semantics.
- Full gate passes before merge.

**Do not include**
- new production feature scope

## Coverage Audit Against the Original Plan

This backlog covers every implementation section in the original plan:

- Plan item 1, neutral issue model: US-01
- Plan item 2, Azure config support: US-02
- Plan item 3, Azure Boards provider: US-04 and US-05
- Plan item 4, provider-aware runtime: US-03
- Plan item 5, Azure dynamic tool: US-06
- Plan item 6, Azure-specific repo skills and cleanup: US-07
- Plan item 7, workpad and PR-linkage parity: US-05, US-06, US-07, and US-08
- Plan item 8, Azure workflow example: US-08
- Plan item 9, docs and spec updates: US-08

Nothing from the plan should be implemented outside these story owners. If a change does not fit one
of the mappings above, it should become a new story instead of leaking into an existing one.

## Safe Execution Order

If you are running one CLI at a time, use this exact order:

1. US-01
2. US-02
3. US-03
4. US-04
5. US-05
6. US-06
7. US-07
8. US-08
9. US-09

Optional parallel window only if you later want it:

- US-03 and US-04 can run in parallel after US-02 is merged.

## File Collision Notes

These are the main places where parallel work will cause churn:

- US-01 and US-03 both touch `orchestrator.ex`, `agent_runner.ex`, and `prompt_builder.ex`; do not
  run them concurrently.
- US-04 and US-05 both own `elixir/lib/symphony_elixir/azure_devops/*`; keep them sequential.
- US-05 and US-06 may both want shared Azure HTTP helpers; finish US-05 first.
- US-07 is the only story that should touch `workspace.before_remove.ex` and provider-sensitive
  skill files.
- US-09 should not introduce feature work; if a missing behavior is discovered, open US-10-style
  follow-up work instead of expanding the hardening pass.
