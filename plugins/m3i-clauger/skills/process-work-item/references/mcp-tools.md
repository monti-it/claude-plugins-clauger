# Azure DevOps MCP server - tool mapping

The skill prefers an Azure DevOps MCP server over the PAT script. This file maps
each workflow operation to the MCP tools and records the gotchas.

## Detecting the server

Tools are named `mcp__<server>__<tool>`. The server name is whatever the user
configured (`ado`, `azure-devops`, `azuredevops`, ...), so **never hardcode it** -
match on the tool suffix instead.

Recognition markers - if any of these suffixes exist, an ADO MCP server is present:

| Suffix                        | Purpose                          |
|-------------------------------|----------------------------------|
| `wit_get_work_item`           | read a work item                 |
| `wit_list_work_item_comments` | read its comments                |
| `wit_update_work_item`        | claim it, then set `PR Done`     |
| `repo_create_pull_request`    | open a PR                        |
| `repo_list_pull_requests_by_repo` | check for an existing PR     |
| `core_list_projects`          | (presence signal only)           |

Other servers exist with different naming (`get_work_item`, `create_pull_request`,
`ado_*`). Judge by what the tool actually does, not by an exact string.

Where to look, in order:

1. **Your own available tool list** - this is the ground truth. Includes the
   deferred-tools `<system-reminder>`: an ADO tool listed there is available, it
   just needs `ToolSearch` first. Load every one you will need in a **single**
   call, e.g.
   `ToolSearch("select:mcp__ado__wit_get_work_item,mcp__ado__wit_list_work_item_comments,mcp__ado__wit_update_work_item")`.
2. If that is inconclusive, a config file may name the server (a hint, not proof -
   a configured server can still be disconnected):
   `.mcp.json`, `.claude/settings.json` (project), `~/.claude.json`,
   `~/.claude/settings.json`.

## Operation mapping

| Operation | MCP tool (suffix) | PAT script |
|---|---|---|
| Read work item | `wit_get_work_item` | `ado.ps1 get-workitem -Id <id>` |
| Read comments | `wit_list_work_item_comments` | `ado.ps1 get-comments -Id <id>` |
| Claim (assign + Active) | `wit_update_work_item` | `ado.ps1 start-workitem -Id <id>` |
| Hand off (state `PR Done`, step 5) | `wit_update_work_item` | `ado.ps1 set-state -Id <id> -State "PR Done"` |
| Check a stale branch's PR (step 3 cleanup) | `repo_list_pull_requests_by_repo` filtered on `sourceRefName` | `ado.ps1 pr-state -Branch <branch>` |
| Create PR | `repo_create_pull_request` (**last resort**, see below) | `ado.ps1 create-pr ...` |

Choose **per operation**, not once globally: MCP for the reads and the claim,
`ado.ps1` for the PR, is the expected split rather than a degraded mode.

## Calling notes

Read the tool's own input schema before calling; the details below vary by server
version.

### wit_get_work_item

- Usually takes `id` and `project`; often `expand` and/or `fields`.
- **`expand` matters here.** The default projection frequently drops custom
  fields, and `MEP Number` is a custom field. Pass the widest expand the schema
  offers (`all`, sometimes `Fields`/`Relations`). If the response still has no
  MEP-like field, do **not** conclude it is empty - re-read via
  `ado.ps1 get-workitem`, which always expands everything, before asking the user.
- The custom field key is a reference name such as
  `Custom.MEPNumber` / `Custom.MEP_Number`, not the display label. Scan every key
  *and* value for a version-shaped string (`14.1`).

### wit_list_work_item_comments

- Takes the work item `id` (+ `project`), sometimes `top`.
- Read-only. **Never** call the sibling `wit_add_work_item_comment`: this skill
  never comments on a work item, it asks the user in-session.

### wit_update_work_item

- The **only** work item writes this skill may perform, both through this tool:
  1. the claim in step 3 - `System.AssignedTo` = the assignee,
     `System.State` = `Active`;
  2. the hand-off in step 5 - `System.State` = `PR Done`, nothing else.
- **States are restricted to `New`, `Active` and `PR Done`.** `New` is only for an
  explicit user request to put an item back; never write any other state
  (`Resolved`, `Closed`, ...) - ask the user instead. `ado.ps1` enforces this with
  a `ValidateSet`; here nothing does, so it is on you.
- Usually takes `id`, `project` and a list of field updates (op / path / value,
  mirroring the JSON-patch REST shape).
- **Identity.** The script defaults the assignee to the PAT owner (resolved from
  `connectionData`); the MCP server has no equivalent notion, and most expose no
  "who am I" tool. If the server cannot tell you who to assign, either ask the
  user for the account, or run `ado.ps1 start-workitem`, which resolves it itself.
- A rejected state transition - backward, or a state the work item type's workflow
  does not have - is reported to the user and does not stop the run; same
  tolerance as the script path.

### repo_list_pull_requests_by_repo

- Used only for the step 3 local-branch cleanup: given a leftover branch, is its
  PR completed, abandoned, or still active?
- Filter on `sourceRefName` = `refs/heads/<branch>` and `status` = `all`; take the
  newest (highest `pullRequestId`). Read its `status` (`completed` -> delete the
  local branch, `abandoned`/`active` -> keep it).
- Prefer `ado.ps1 pr-state` when a PAT is available - same standing reason as the
  PR creation step, one code path for the Git side.

### repo_create_pull_request

Prefer `ado.ps1 create-pr` whenever a PAT is available. The PR must be created
**with squash auto-complete and delete-source-branch enabled, and
`transitionWorkItems` off**, which the script does in the same step (POST the PR,
then PATCH `autoCompleteSetBy` + `completionOptions`, including the web UI's
`Merged PR <id>: <title>` squash message). Most MCP servers only
create the PR.

Use the MCP tool only when there is no PAT at all. Then:

- Typically `repositoryId` (name or GUID), `sourceRefName`, `targetRefName`,
  `title`, `description`, sometimes `isDraft` / `workItems`.
- Ref names: some versions want `refs/heads/<branch>`, some the bare branch name.
  If the call is rejected for a ref, retry with the other form.
- `repositoryId` = the repo name from `git remote get-url origin` (the last path
  segment, `.git` stripped), unless `$env:ADO_REPO` says otherwise.
- If the schema has a work-item link parameter, pass the id. If not, the
  `Closes AB#<id>` footer in the description does the linking.
- Then try to switch on auto-complete with the server's PR update tool
  (`repo_update_pull_request` or similar) if it exposes those fields, passing
  `transitionWorkItems` = false when the schema has it - "complete associated work
  items after merging" must stay off, since the skill owns the state and stops at
  `PR Done`. Also pass `mergeCommitMessage` when the schema has it, built like
  the web UI's default: `Merged PR <id>: <title>`, blank line, description, blank
  line, `Related work items: #<id>`; otherwise the server writes
  `Merge pull request <id> from <source> into <target>`. If it does not, tell the user auto-complete is **not** set and they
  can enable it in the ADO UI, leaving that box unticked - do not leave that
  silent.

## Failure handling

An MCP call that fails for **auth/config** reasons (server not connected, no
organization configured, 401) -> fall back to `ado.ps1` for that operation and
tell the user in one line which path you used and why.

An MCP call that fails for **data** reasons (work item not found, branch missing,
PR already exists) -> that is a real answer. Surface it and stop; do not retry the
same thing through the PAT script hoping for a different result.
