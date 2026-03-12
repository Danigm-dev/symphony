---
name: azure_devops
description: |
  Use Symphony's `azure_devops_request` tool for raw Azure DevOps REST work
  during Azure Boards and Azure Repos flows.
---

# Azure DevOps REST

Use this skill when `tracker.kind: azure_devops` and you need an Azure Boards
or Azure Repos operation that is not already covered by a narrower skill.

## Primary Tool

Use the `azure_devops_request` tool exposed by Symphony's app-server session.
It reuses the Azure DevOps endpoint and token already configured in Symphony.

Tool input:

```json
{
  "method": "GET | POST | PUT | PATCH | DELETE",
  "path": "/relative/path/on/the/configured/endpoint",
  "query": {
    "optional": "query params object"
  },
  "body": {
    "optional": "json body"
  }
}
```

## Required Inputs Before Real Validation

Do not proceed blind. If any of these are missing, stop and ask for them in one
short list:

- Azure DevOps endpoint
- project
- repository id or name
- PR target branch
- real work item id (`AB#...`)
- token with Repos PR read/write, threads/comments read/write, policy read, and
  Boards comments read/write
- mandatory reviewers or branch-policy constraints, if any

## Usage Rules

- Send one Azure REST operation per tool call.
- Keep `path` on the configured Azure DevOps endpoint.
- Treat non-2xx responses as failures even if the tool call itself succeeded.
- Prefer Azure Boards comments for persistent workpad state.
- Reuse the existing `## Codex Workpad` comment instead of creating duplicates.
- PR linkage priority is:
  1. direct work-item link;
  2. `AB#<id>` in title/body;
  3. PR URL stored in the workpad if direct linking is blocked.

## Common Workflows

### List comments for the work item

```json
{
  "method": "GET",
  "path": "/Symphony/_apis/wit/workItems/123/comments"
}
```

### Create the persistent workpad comment

```json
{
  "method": "POST",
  "path": "/Symphony/_apis/wit/workItems/123/comments",
  "body": {
    "text": "## Codex Workpad\n- Status: in progress"
  }
}
```

### Update the existing workpad comment

```json
{
  "method": "PATCH",
  "path": "/Symphony/_apis/wit/workItems/123/comments/88",
  "body": {
    "text": "## Codex Workpad\n- PR: https://dev.azure.com/org/project/_git/repo/pullrequest/42\n- Status: ready for review"
  }
}
```

### Find PRs for a branch

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

### Get the full PR and its `artifactId`

```json
{
  "method": "GET",
  "path": "/Symphony/_apis/git/repositories/repo-name-or-id/pullRequests/42",
  "query": {
    "includeWorkItemRefs": "true"
  }
}
```

### Add a root discussion thread during cleanup

```json
{
  "method": "POST",
  "path": "/Symphony/_apis/git/repositories/repo-name-or-id/pullRequests/42/threads",
  "body": {
    "comments": [
      {
        "parentCommentId": 0,
        "content": "[codex] Cleanup is abandoning this PR because the tracked work item reached a terminal state without merge.",
        "commentType": 1
      }
    ],
    "status": 1
  }
}
```

### Add a Symphony label if the repo supports it

```json
{
  "method": "POST",
  "path": "/Symphony/_apis/git/repositories/repo-name-or-id/pullRequests/42/labels",
  "body": {
    "name": "symphony"
  }
}
```

## Workpad Policy

- Keep exactly one live `## Codex Workpad` comment per active work item.
- Update it in place during push, review, land, and cleanup.
- Only reset it intentionally during `Rework`.

## PR Linkage Policy

- Prefer a direct work-item link using the PR `artifactId`.
- Keep `AB#<id>` in the title/body even after the direct link succeeds.
- If direct linking is blocked, document that in the workpad and keep the PR URL
  there as the fallback evidence.
