---
name: push
description:
  Push current branch changes to the configured remote and create or update the
  corresponding PR; use when asked to push, publish updates, or create a pull
  request.
---

# Push

## Goals

- Push the current branch safely.
- Keep GitHub behavior unchanged.
- Support Azure Repos create/update/recreate flows through Symphony's
  `azure_devops_request` tool when `tracker.kind: azure_devops`.

## Provider Selection

1. Read `tracker.kind` from `WORKFLOW.md`.
2. If the tracker is `azure_devops`, follow the Azure Repos path below.
3. Otherwise, use the GitHub path exactly as before.

## Shared Steps

1. Identify the current branch and validate locally before any push.
2. Push the branch to the configured git remote.
3. If push is rejected because the branch is stale or non-fast-forward, use the
   `pull` skill, revalidate, and retry.
4. If push fails for auth, permission, or workflow restrictions, stop and
   surface the exact error.

## GitHub Path

### Prerequisites

- `gh` CLI is installed and authenticated for this repo.

### Steps

1. Run local validation with `make -C elixir all`.
2. Push with `git push -u origin HEAD`.
3. Ensure a PR exists for the branch:
   - create one if none exists;
   - update the existing open PR if one already exists;
   - if the branch points at a closed or merged PR, create a new branch + PR.
4. Refresh the PR title and body so they match the current total scope.
5. Validate the PR body with `mix pr_body.check`.
6. Reply with the PR URL from `gh pr view`.

### Commands

```sh
branch=$(git branch --show-current)
make -C elixir all
git push -u origin HEAD

pr_state=$(gh pr view --json state -q .state 2>/dev/null || true)
if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
  echo "Current branch is tied to a closed PR; create a new branch + PR." >&2
  exit 1
fi

pr_title="<clear PR title written for this change>"
if [ -z "$pr_state" ]; then
  gh pr create --title "$pr_title"
else
  gh pr edit --title "$pr_title"
fi

tmp_pr_body=$(mktemp)
gh pr view --json body -q .body > "$tmp_pr_body"
(cd elixir && mix pr_body.check --file "$tmp_pr_body")
rm -f "$tmp_pr_body"

gh pr view --json url -q .url
```

## Azure Repos Path

### Prerequisites

- The Symphony app-server session exposes `azure_devops_request`.
- `tracker.endpoint`, `tracker.project`, and the Azure DevOps token are already
  configured in `WORKFLOW.md`.
- You know the Azure repository name or id and the target branch for the PR.

### Rules

- Use `azure_devops_request` for repo and work-item mutations; do not shell out
  to ad-hoc tokenized `curl`.
- Keep exactly one persistent `## Codex Workpad` comment on the active Azure
  Boards work item unless the workflow explicitly resets it during `Rework`.
- Apply Symphony metadata to the PR via Azure labels when possible; if labels
  are unavailable, carry the equivalent metadata in the PR title/body.
- Link the PR to the work item in this order:
  1. direct work-item link;
  2. `AB#<id>` in the PR title/body as a safety net;
  3. PR URL recorded in the workpad comment as blocked-but-recorded evidence.

### Steps

1. Run local validation with `make -C elixir all`.
2. Push with `git push -u origin HEAD`.
3. Query active PRs for the source branch with:
   `GET /{project}/_apis/git/pullrequests?searchCriteria.repositoryId=<repo>&searchCriteria.sourceRefName=refs/heads/<branch>&searchCriteria.status=active`
4. If an active Azure PR exists, update it. If only completed or abandoned PRs
   exist for the branch, create a fresh PR instead of reusing them.
5. Create a PR with:
   `POST /{project}/_apis/git/repositories/{repo}/pullrequests`
   Include `sourceRefName`, `targetRefName`, `title`, `description`, and any
   reviewer ids already mandated by the workflow.
6. Update an existing PR with:
   `PATCH /{project}/_apis/git/repositories/{repo}/pullrequests/{pullRequestId}`
   Refresh the title/body whenever the effective scope changes.
7. Apply Symphony metadata:
   - Prefer `POST /{project}/_apis/git/repositories/{repo}/pullRequests/{pullRequestId}/labels`
     for labels/tags.
   - If label creation is not available, encode the same metadata in the title
     or description.
8. Try to establish a direct PR/work-item link before handoff. If the direct
   link cannot be written from the current session, ensure the PR title or body
   contains the Azure Boards key such as `AB#123`.
9. Upsert the Azure Boards workpad comment:
   - list comments on the work item;
   - reuse the one whose text starts with `## Codex Workpad`;
   - create it if missing;
   - update it with the latest PR URL, status, blockers, and handoff state.
10. If direct PR/work-item linking is still unavailable, leave the PR URL in the
    workpad comment and state that the direct link is blocked but recorded.
11. Reply with the PR URL.

### Azure request patterns

Create or update the persistent workpad comment:

```json
{
  "method": "POST",
  "path": "/Symphony/_apis/wit/workItems/101/comments",
  "body": {
    "text": "## Codex Workpad\n- PR: https://dev.azure.com/org/project/_git/repo/pullrequest/42\n- Status: ready for review"
  }
}
```

List active PRs for a branch:

```json
{
  "method": "GET",
  "path": "/Symphony/_apis/git/pullrequests",
  "query": {
    "searchCriteria.repositoryId": "repo-name-or-id",
    "searchCriteria.sourceRefName": "refs/heads/feature/my-branch",
    "searchCriteria.status": "active"
  }
}
```

Create a PR:

```json
{
  "method": "POST",
  "path": "/Symphony/_apis/git/repositories/repo-name-or-id/pullrequests",
  "body": {
    "sourceRefName": "refs/heads/feature/my-branch",
    "targetRefName": "refs/heads/main",
    "title": "AB#101 Make Azure push provider-aware",
    "description": "Symphony metadata goes here."
  }
}
```

## Notes

- Do not use `--force`; only use `--force-with-lease` when history was
  intentionally rewritten.
- The GitHub path must remain behaviorally identical for non-Azure trackers.
- For Azure, keep the PR body and workpad synchronized before handoff.
