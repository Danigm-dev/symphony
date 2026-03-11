---
name: azure_devops
description: |
  Use Symphony's `azure_devops_request` tool for raw Azure DevOps REST work
  during app-server sessions, including Azure Boards comments and Azure Repos
  pull request operations.
---

# Azure DevOps REST

Use this skill when Symphony is running against `tracker.kind: azure_devops`
and you need raw Azure DevOps operations that are not covered by a narrower
skill.

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

## Usage Rules

- Send one Azure REST operation per tool call.
- Keep `path` on the configured Azure DevOps endpoint.
- Treat non-2xx responses as failures even if the tool call itself succeeded.
- Prefer Azure Boards comments for persistent workpad state.
- Reuse the existing `## Codex Workpad` comment instead of creating duplicates.

## Common Workflows

### List comments for an Azure Boards work item

```json
{
  "method": "GET",
  "path": "/Symphony/_apis/wit/workItems/101/comments"
}
```

### Create the persistent workpad comment

```json
{
  "method": "POST",
  "path": "/Symphony/_apis/wit/workItems/101/comments",
  "body": {
    "text": "## Codex Workpad\n- Status: in progress"
  }
}
```

### Update the existing workpad comment

```json
{
  "method": "PATCH",
  "path": "/Symphony/_apis/wit/workItems/101/comments/88",
  "body": {
    "text": "## Codex Workpad\n- PR: https://dev.azure.com/org/project/_git/repo/pullrequest/42\n- Status: ready for review"
  }
}
```

### Find active PRs for a branch

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

### Get a full Azure Repos PR

```json
{
  "method": "GET",
  "path": "/Symphony/_apis/git/repositories/repo-name-or-id/pullrequests/42"
}
```

### Add a root PR discussion thread

```json
{
  "method": "POST",
  "path": "/Symphony/_apis/git/repositories/repo-name-or-id/pullRequests/42/threads",
  "body": {
    "comments": [
      {
        "parentCommentId": 0,
        "content": "[codex] Cleanup is abandoning this PR because the work item reached a terminal state without merge.",
        "commentType": 1
      }
    ],
    "status": 1
  }
}
```

### Add a PR label

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

- Keep exactly one live `## Codex Workpad` comment per active Azure Boards work
  item.
- Update it in place during push, review, land, and cleanup.
- Only reset it intentionally during `Rework`.

## PR Linkage Policy

When connecting a PR to an Azure Boards work item, follow this order:

1. direct work-item link;
2. `AB#<id>` in title/body as a safety net;
3. PR URL recorded in the workpad if direct linking is blocked.

If you cannot complete step 1 from the current session, do not skip the other
two.
