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
2. Creates an isolated workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony can also serve a provider-specific client-side tool:

- `linear_graphql` when `tracker.kind: linear`
- `azure_devops_request` when `tracker.kind: azure_devops`

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Choose the tracker example that matches your deployment:
   - Linear: start from [`WORKFLOW.md`](./WORKFLOW.md).
   - Azure DevOps: start from [`WORKFLOW.azure_devops.md`](./WORKFLOW.azure_devops.md).
3. Export the tracker credential for your provider:
   - Linear: `LINEAR_API_KEY`
   - Azure DevOps: `AZURE_DEVOPS_TOKEN`
4. Optionally copy the repo skills your workflow expects.
   - Linear workflows typically use `commit`, `push`, `pull`, `land`, and `linear`.
   - Azure workflows typically use `commit`, `push`, `pull`, `land`, and `azure_devops`.
5. Customize the copied workflow file for your project.
   - Linear uses `tracker.project_slug`.
   - Azure DevOps uses `tracker.project` and usually also documents the Azure repo id/name and target branch in the workflow body or repo docs.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

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
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
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
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from the provider fallback env var when unset or when value is `$...`.
  - Linear fallback: `LINEAR_API_KEY`
  - Azure DevOps fallback: `AZURE_DEVOPS_TOKEN`
- `tracker.assignee` also supports `$...` indirection.
  - Linear fallback: `LINEAR_ASSIGNEE`
  - Azure DevOps fallback: `AZURE_DEVOPS_ASSIGNEE`
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Azure DevOps workflow

The Linear example above remains the default example. For Azure Boards + Azure Repos, use
[`WORKFLOW.azure_devops.md`](./WORKFLOW.azure_devops.md).

Symphony runtime keys consumed by the current Azure adapter:

- `tracker.kind: azure_devops`
- `tracker.endpoint`: required Azure organization URL such as `https://dev.azure.com/your-org`
- `tracker.api_key`: PAT literal or `$AZURE_DEVOPS_TOKEN`
- `tracker.project`: required Azure project name
- `tracker.assignee`: optional display name, email, or `me`; also supports `$AZURE_DEVOPS_ASSIGNEE`
- `tracker.active_states`
- `tracker.terminal_states`
- `tracker.wiql`: optional override for candidate polling only
- `tracker.work_item_types`
- `tracker.area_paths`
- `tracker.iteration_path`
- `tracker.api_version`: optional; defaults to `7.1`

Provider-specific operator expectations for the Azure path:

- `azure_devops_request` is the raw REST tool exposed to the app-server session.
- The provider-aware `push` and `land` skills expect the Azure project, repository id or name,
  target branch, and real work item id to be known before they mutate Azure Repos.
- The Azure path keeps one persistent `## Codex Workpad` comment on the work item and updates it in
  place during planning, validation, push, land, and cleanup.
- PR linkage priority is:
  1. direct work-item link using the PR `artifactId`;
  2. `AB#<work-item-id>` in the PR title/body;
  3. PR URL stored in the workpad if direct linking is blocked.
- The recommended Azure cleanup hook is `mix workspace.before_remove --provider azure_devops --repo <repo>`.

The current implementation does not add a dedicated `tracker.repo` or `tracker.target_branch`
frontmatter key. Keep those values in the workflow prompt, repo-local docs, or repo-local skills so
the Azure Repos flow has the inputs it needs.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
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
