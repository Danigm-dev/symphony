---
name: land
description:
  Land a PR by monitoring conflicts, resolving them, waiting for checks, and
  completing the merge once the provider-specific gates are green.
---

# Land

## Goals

- Keep the current GitHub landing flow unchanged.
- Add an Azure Repos landing flow that blocks on unresolved feedback and policy
  failures, then completes with squash semantics.
- Keep looping until the PR is landed or an explicit blocker remains.

## Provider Selection

1. Read `tracker.kind` from `WORKFLOW.md`.
2. If it is `azure_devops`, use the Azure Repos flow.
3. Otherwise, use the GitHub flow.

## Shared Preconditions

- You are on the PR branch with a clean working tree, or you commit/push first.
- Local validation for the branch is green before attempting to land.
- If review feedback requires code changes, respond first, then edit, then push.

## GitHub Flow

### Prerequisites

- `gh` CLI is authenticated.

### Steps

1. Locate the PR for the current branch.
2. Confirm the gauntlet is green locally.
3. If the branch has local changes, commit with the `commit` skill and publish
   with the `push` skill.
4. Check mergeability against `main`.
5. If conflicts exist, use the `pull` skill, resolve, and push again.
6. Acknowledge and address Codex or human review comments before merging.
7. Watch checks until complete.
8. If checks fail, pull logs, fix, commit, push, and restart the watch.
9. When all checks are green and feedback is resolved, squash-merge the PR.
10. Do not stop until the PR is merged or a blocker is explicit.

### Commands

```sh
branch=$(git branch --show-current)
pr_number=$(gh pr view --json number -q .number)
pr_title=$(gh pr view --json title -q .title)
pr_body=$(gh pr view --json body -q .body)
mergeable=$(gh pr view --json mergeable -q .mergeable)

if [ "$mergeable" = "CONFLICTING" ]; then
  echo "Use the pull skill, resolve conflicts, then push again." >&2
  exit 1
fi

python3 .codex/skills/land/land_watch.py
gh pr merge --squash --subject "$pr_title" --body "$pr_body"
```

## Azure Repos Flow

### Prerequisites

- The Symphony app-server session exposes `azure_devops_request`.
- The Azure repository name or id is known.
- The PR was created by the `push` flow and already carries the expected
  Symphony metadata, direct link attempt, and workpad update.

### Rules

- Use `azure_devops_request` for Azure PR, reviewer, thread, label, and policy
  operations.
- Block on unresolved review threads, negative reviewer votes, and non-approved
  blocking policies.
- Preserve the same "keep looping until landed unless blocked" posture as the
  GitHub path.
- Complete with squash semantics and delete the source branch when the server
  allows it.

### Steps

1. Find the active PR for the current source branch:
   `GET /{project}/_apis/git/pullrequests?searchCriteria.repositoryId=<repo>&searchCriteria.sourceRefName=refs/heads/<branch>&searchCriteria.status=active`
2. If there are uncommitted changes, use `commit` and `push` before continuing.
3. Fetch the full PR:
   `GET /{project}/_apis/git/repositories/{repo}/pullrequests/{pullRequestId}`
   Use it to read `reviewers`, `status`, `mergeStatus`, `lastMergeSourceCommit`,
   `artifactId`, and the project id embedded in the response.
4. Ensure required reviewers exist. If the workflow needs to add reviewers, use:
   `POST /{project}/_apis/git/repositories/{repo}/pullRequests/{pullRequestId}/reviewers`
5. Fetch discussion threads:
   `GET /{project}/_apis/git/repositories/{repo}/pullRequests/{pullRequestId}/threads`
   Treat active threads or unresolved feedback as blocking until you reply and
   the thread is resolved or closed.
6. Evaluate policies with:
   `GET /{project}/_apis/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/<projectId>/<pullRequestId>&api-version=7.1-preview.1`
   Block while any required policy is queued, running, rejected, or failed.
7. If `mergeStatus` reports conflicts or a merge failure, rebase/merge locally,
   push, and restart the land loop.
8. Once reviewers, threads, and policies are clear, complete the PR with:
   `PATCH /{project}/_apis/git/repositories/{repo}/pullrequests/{pullRequestId}`
   Include:
   - `status: "completed"`
   - `lastMergeSourceCommit.commitId`
   - `completionOptions.deleteSourceBranch: true`
   - `completionOptions.transitionWorkItems: true`
   - squash semantics via `completionOptions.mergeStrategy: "squash"` when
     accepted by the server, or `completionOptions.squashMerge: true` as the
     compatibility fallback.
9. Poll until the PR status becomes `completed`, or stop only if Azure returns a
   concrete blocker.

### Azure request patterns

List unresolved threads:

```json
{
  "method": "GET",
  "path": "/Symphony/_apis/git/repositories/repo-name-or-id/pullRequests/42/threads"
}
```

Check policy evaluations:

```json
{
  "method": "GET",
  "path": "/Symphony/_apis/policy/evaluations",
  "query": {
    "artifactId": "vstfs:///CodeReview/CodeReviewId/<projectId>/42",
    "api-version": "7.1-preview.1"
  }
}
```

Complete with squash semantics:

```json
{
  "method": "PATCH",
  "path": "/Symphony/_apis/git/repositories/repo-name-or-id/pullrequests/42",
  "body": {
    "status": "completed",
    "lastMergeSourceCommit": {
      "commitId": "<current-head-sha>"
    },
    "completionOptions": {
      "deleteSourceBranch": true,
      "transitionWorkItems": true,
      "mergeStrategy": "squash",
      "squashMerge": true
    }
  }
}
```

## Review Handling

- For GitHub, keep using the existing `gh`-based review flow.
- For Azure, respond in the relevant PR thread before pushing follow-up code.
- When a reviewer or policy blocker is intentionally deferred, record that in
  the Azure workpad before stopping.

## Notes

- Do not enable auto-complete if it would bypass required policy waiting.
- Do not merge while any Azure thread is unresolved or any required policy is
  not approved.
- GitHub behavior must remain unchanged for non-Azure trackers.
