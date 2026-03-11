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
- Keep the GitHub path behaviorally unchanged.
- Support Azure Repos create, update, and recreate flows when
  `tracker.kind: azure_devops`.

## Provider Selection

1. Read `tracker.kind` from `WORKFLOW.md`.
2. If it is `azure_devops`, follow the Azure Repos path below.
3. Otherwise, use the GitHub path.

## Shared Steps

1. Identify the current branch and run local validation before any push.
2. Push to the configured remote with `git push -u origin HEAD`.
3. If the push fails because the branch is stale or non-fast-forward, use the
   `pull` skill, revalidate, and retry.
4. If the push fails because of auth, permissions, or workflow restrictions,
   stop and surface the exact error.

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
- The operator has provided the Azure project, repository id or name, target
  branch, and the real work item id.
- If any of those inputs are missing, stop and ask for the missing values
  before mutating Azure.

### Rules

- Use `azure_devops_request` for Azure Repos and Azure Boards mutations.
- Keep exactly one persistent `## Codex Workpad` comment on the active work item
  unless the workflow explicitly resets it during `Rework`.
- PR linkage priority is:
  1. direct work-item link;
  2. `AB#<id>` in the PR title/body as a safety net;
  3. PR URL recorded in the workpad if direct linking is blocked.
- Preserve Symphony metadata via Azure PR labels or tags if available. If the
  repo does not support that, carry the equivalent metadata in the PR title,
  body, or work-item link note.

### Steps

1. Run local validation with `make -C elixir all`.
2. Push with `git push -u origin HEAD`.
3. Find PRs for the source branch:
   `GET /{project}/_apis/git/pullrequests?searchCriteria.repositoryId=<repo>&searchCriteria.sourceRefName=refs/heads/<branch>&searchCriteria.status=<active|completed|abandoned>`
4. If an active PR exists, update that PR.
5. If no active PR exists but the branch is tied to completed or abandoned PRs,
   create a fresh branch name, push it, and create a new PR instead of trying
   to reuse the closed one.
6. Create or update the PR with:
   - `sourceRefName`
   - `targetRefName`
   - title that includes `AB#<id>`
   - body that reflects the current total scope
7. Try to apply Symphony metadata with Azure labels:
   `POST /{project}/_apis/git/repositories/{repo}/pullRequests/{pullRequestId}/labels`
   If labels are not supported in the target repo, preserve the same metadata
   in the title or body.
8. Fetch the full PR and capture `artifactId`:
   `GET /{project}/_apis/git/repositories/{repo}/pullRequests/{pullRequestId}?includeWorkItemRefs=true`
9. Ensure the work item is linked to the PR:
   - first, check existing PR work-item refs;
   - if the work item is not already linked, patch the work item with the PR
     `artifactId` as an `ArtifactLink`;
   - keep `AB#<id>` in the title or body even when the direct link succeeds.
10. Upsert the workpad comment on the work item:
   - list comments;
   - reuse the one whose text starts with `## Codex Workpad`;
   - create it if missing;
   - update it in place with the latest PR URL, status, blockers, and handoff.
11. If the direct work-item link is rejected, keep the `AB#<id>` safety net and
    record the PR URL in the workpad as the documented fallback.
12. Reply with the PR URL and state whether direct linking succeeded or fell
    back.

### Azure Request Patterns

List PRs for a branch:

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
    "targetRefName": "refs/heads/devops-wrapper",
    "title": "AB#123 Add Azure repo operational skills",
    "description": "Symphony metadata and handoff details."
  }
}
```

Update the existing workpad comment:

```json
{
  "method": "PATCH",
  "path": "/Symphony/_apis/wit/workItems/123/comments/88",
  "body": {
    "text": "## Codex Workpad\n- PR: https://dev.azure.com/org/project/_git/repo/pullrequest/42\n- Status: ready for review"
  }
}
```

## Notes

- Do not use `--force`; only use `--force-with-lease` when history was
  intentionally rewritten.
- Keep the GitHub path unchanged for non-Azure trackers.
- For Azure, do not leave duplicate `## Codex Workpad` comments behind.
