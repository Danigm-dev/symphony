---
name: land
description:
  Land a PR by monitoring conflicts, resolving them, waiting for checks, and
  completing the merge once the provider-specific gates are green.
---

# Land

## Goals

- Keep the GitHub landing flow unchanged.
- Add an Azure Repos landing flow that blocks on unresolved feedback, reviewer
  votes, and policy failures before completing with squash semantics.
- Keep looping until the PR is landed or an explicit blocker remains.

## Provider Selection

1. Read `tracker.kind` from `WORKFLOW.md`.
2. If it is `azure_devops`, use the Azure Repos flow.
3. Otherwise, use the GitHub flow.

## Shared Preconditions

- You are on the PR branch with a clean working tree, or you commit and push
  first.
- Local validation is green before attempting to land.
- If review feedback requires code changes, reply first, then edit, then push.

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
- The Azure project, repository id or name, target branch, and real work item
  id are known for this PR.
- The PR was already created by the `push` flow and the workpad exists.

### Rules

- Use `azure_devops_request` for Azure PR, reviewer, thread, label, and policy
  operations.
- Treat unresolved review threads, negative reviewer votes, and non-approved
  required policies as blocking.
- Do not enable auto-complete if that would bypass waiting.
- Keep the same "loop until landed unless blocked" posture as the GitHub path.

### Steps

1. Find the active PR for the current source branch:
   `GET /{project}/_apis/git/pullrequests?searchCriteria.repositoryId=<repo>&searchCriteria.sourceRefName=refs/heads/<branch>&searchCriteria.status=active`
2. If the branch has local changes, use `commit` and `push` before continuing.
3. Fetch the full PR:
   `GET /{project}/_apis/git/repositories/{repo}/pullRequests/{pullRequestId}`
   Capture `status`, `mergeStatus`, `reviewers`, `artifactId`,
   `lastMergeSourceCommit.commitId`, and the embedded project id.
4. Ensure required reviewers exist. Add a missing reviewer with:
   `PUT /{project}/_apis/git/repositories/{repo}/pullRequests/{pullRequestId}/reviewers/{reviewerId}`
5. Fetch threads:
   `GET /{project}/_apis/git/repositories/{repo}/pullRequests/{pullRequestId}/threads`
   Treat active or unresolved threads as blocking until you reply and resolve
   them.
6. Inspect reviewers. Treat blocking votes such as `-10` or `-5` as unresolved
   feedback unless the workflow explicitly allows proceeding.
7. Evaluate policies with:
   `GET /{project}/_apis/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/<projectId>/<pullRequestId>&api-version=7.1-preview.1`
   Wait while any required policy is queued, running, rejected, or failed.
8. If `mergeStatus` reports conflicts or merge failure, resolve locally, push,
   and restart the land loop.
9. Once reviewers, threads, and policies are clear, complete the PR with:
   `PATCH /{project}/_apis/git/repositories/{repo}/pullRequests/{pullRequestId}`
   Include:
   - `status: "completed"`
   - `lastMergeSourceCommit.commitId`
   - `completionOptions.deleteSourceBranch: true`
   - `completionOptions.transitionWorkItems: true`
   - `completionOptions.mergeStrategy: "squash"` when supported, otherwise
     `completionOptions.squashMerge: true`
10. Poll until the PR status becomes `completed`.
11. Update the existing `## Codex Workpad` comment with the landed state, or if
    you stop on a blocker, record the blocker there before yielding.

### Azure Request Patterns

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
  "path": "/Symphony/_apis/git/repositories/repo-name-or-id/pullRequests/42",
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

## Notes

- Do not merge while any Azure thread is unresolved or any required policy is
  not approved.
- Keep the GitHub path unchanged for non-Azure trackers.
- If the Azure repo has mandatory reviewers or branch policies, respect them
  instead of trying to bypass them.
