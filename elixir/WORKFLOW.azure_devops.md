---
tracker:
  kind: azure_devops
  endpoint: https://dev.azure.com/your-org
  project: Symphony
  api_key: $AZURE_DEVOPS_TOKEN
  assignee: $AZURE_DEVOPS_ASSIGNEE
  active_states:
    - Todo
    - In Progress
    - Human Review
    - Merging
    - Rework
  terminal_states:
    - Done
    - Closed
    - Removed
  work_item_types:
    - User Story
    - Bug
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://dev.azure.com/your-org/your-project/_git/your-repo .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove --provider azure_devops --repo your-repo
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on an Azure Boards work item `{{ issue.identifier }}`.

Azure context:

- Work item id: `{{ issue.id }}`
- Work item identifier: `{{ issue.identifier }}`
- Title: `{{ issue.title }}`
- Current state: `{{ issue.state }}`
- URL: `{{ issue.url }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the work item is still in an active state.
- Resume from the current workspace and existing workpad instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless the new attempt changes the plan.
{% endif %}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Do not ask a human to perform follow-up actions unless a required permission or secret is truly missing.
2. Keep all work inside the provided repository copy.
3. Use Azure Boards comments and Azure Repos PR state as the source of truth for progress and handoff.

## Required Azure tools and skills

- The app-server session must expose `azure_devops_request`.
- Provider-aware repo skills should exist locally: `commit`, `pull`, `push`, `land`, and `azure_devops`.
- If `azure_devops_request` or the required Azure auth is missing, stop, record the blocker in the workpad, and move the work item to the workflow's blocked/handoff state.

## Required Azure operator inputs before PR mutations

Before creating or updating an Azure Repos PR, make sure the workflow or repo-local docs already define:

- the Azure DevOps project;
- the repository id or name;
- the PR target branch;
- the real work item id used for `AB#<id>` linkage;
- any mandatory reviewers or branch-policy constraints.

If any of those are missing, stop and record a concrete blocker instead of guessing.

## Workpad policy

- Keep exactly one live `## Codex Workpad` comment on the active Azure Boards work item.
- Reuse the existing workpad comment if one already exists.
- Update that comment in place throughout planning, implementation, validation, push, review, land, and cleanup.
- Do not create duplicate summary comments if the workpad already exists.
- Only reset the workpad intentionally during `Rework`.

## PR linkage policy

When a branch is published, preserve linkage in this priority order:

1. direct Azure work-item link to the PR via the PR `artifactId`;
2. `AB#{{ issue.id }}` in the PR title or body as a safety net;
3. PR URL recorded in the workpad if direct linking is blocked.

Keep the `AB#...` safety net even when the direct link succeeds.

## Status map

- `Backlog` -> out of scope for this workflow.
- `Todo` -> immediately move to `In Progress`, then reconcile the workpad and start execution.
- `In Progress` -> active implementation.
- `Human Review` -> PR is attached and validated; wait for human decision.
- `Merging` -> run the `land` skill using the Azure Repos flow until the PR is completed or an explicit blocker remains.
- `Rework` -> reset the plan, keep one active workpad, and reopen the execution flow.
- `Done` -> terminal state; do nothing.

## Execution flow

1. Read the current work item state and route using the status map above.
2. Find or create the `## Codex Workpad` comment on the work item.
3. Reconcile the workpad before new edits:
   - refresh the plan;
   - refresh acceptance criteria and validation items;
   - note the current environment stamp as `<host>:<abs-workdir>@<short-sha>`.
4. Reproduce the issue or capture the current baseline signal before implementing.
5. Run the `pull` skill before code edits and record the result in the workpad.
6. Implement only the current work item scope and keep the workpad current after each meaningful milestone.
7. Run validation that directly proves the changed behavior.
8. Use the `push` skill for branch publication and Azure PR create/update flow.
9. Use the `land` skill only when the work item reaches `Merging`.

## Azure Repos expectations for `push`

- Use `azure_devops_request` for Azure Repos and Azure Boards mutations.
- Search for PRs on the current source branch before creating a new one.
- If the branch only has completed or abandoned PRs, create a fresh branch and PR instead of reusing the closed one.
- Keep the workpad updated with PR URL, status, blockers, and validation summary.
- If the repo supports PR labels, preserve Symphony metadata there. If not, keep the equivalent metadata in the PR title/body and workpad.

## Azure Repos expectations for `land`

- Treat unresolved threads, negative reviewer votes, and failing required policies as blockers.
- Do not enable auto-complete if that would bypass waiting for reviewers or policies.
- Complete the PR with squash semantics when the Azure checks are clear.
- After the PR lands, update the existing workpad comment with the landed state.

## Cleanup expectation

- When the tracked work item reaches a terminal state without merge, the `before_remove` hook should abandon open Azure PRs for the current branch and add a closing thread that explains why cleanup closed the PR.

## Definition of done for this workflow

Before moving a work item to `Human Review`, make sure:

- the workpad is fully reconciled and current;
- the latest validation is recorded in the workpad;
- the branch is pushed;
- the PR exists;
- direct work-item linkage is present or the fallback (`AB#...` + PR URL in workpad) is documented.
