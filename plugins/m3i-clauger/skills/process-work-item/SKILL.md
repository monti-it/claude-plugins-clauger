---
name: process-work-item
description: Process an Azure DevOps work item end to end - fetch it, claim it, branch from the release branch named by its "MEP Number", implement the change in small intelligible commits, push, open a pull request back to that release branch, and move the item to PR Done, then hand the SonarCloud findings to the sonar-pr skill in a background subagent. Only ever writes the states New, Active and PR Done. Uses an Azure DevOps MCP server when one is available, else a PAT-based REST script. When details are missing, ask the user directly in the session (never comment on the work item). Invoke as /process-work-item <id>, or when the user says "process work item N", "traiter le work item N", "handle ADO item N".
---

# Process an Azure DevOps work item

End-to-end handling of one Azure DevOps work item: read it, do the work on a
fresh branch cut from the correct release branch, and open the PR.

## Step 0. Pick the Azure DevOps access path

**Prefer an Azure DevOps MCP server. The PAT script is the fallback.**

Look for MCP tools whose names end in `wit_get_work_item`,
`wit_list_work_item_comments`, `wit_update_work_item`, `repo_create_pull_request`
(server prefix varies: `mcp__ado__`, `mcp__azure-devops__`, ...). If they only
appear in the deferred tools reminder, load the ones you need with a **single**
`ToolSearch` call.

- **Found** -> use MCP for every operation it covers. No PAT needed.
- **Not found** -> use `scripts/ado.ps1`, which needs a PAT file at
  `$env:ADO_PAT_FILE`, else `%TEMP%\ado_pat.txt`. If it is missing, tell the user:
  `Set-Content -Path "$env:TEMP\ado_pat.txt" -Value "YOUR_PAT" -NoNewline`
  (scopes: Work Items Read & Write, Code Read & Write, Pull Request).
- **Partial** -> decide per operation; mixing is fine and expected.

One standing exception to MCP-first: **step 5 opens the PR through `ado.ps1`
whenever a PAT is available**, connected MCP server or not, because the script
also switches on squash auto-complete in the same step.

Tell the user in one line which path you are on. `references/mcp-tools.md` has the
per-tool mapping, parameter gotchas, and the fallback rules - read it before your
first MCP call.

Work item writes, whichever path: the **only** ones allowed are assigning the item
and setting its state (the claim in step 3, the hand-off in step 5). Never comment
on it - missing info is asked in-session. Never print the PAT, never write it to a
file, never commit it.

**Allowed states.** This skill writes exactly three work item states - **New**,
**Active** and **PR Done** - and no others, whichever path you are on. Active on
the claim, PR Done once the PR exists; New only if the user explicitly asks to put
an item back. Any other state (Resolved, Closed, Removed, ...) is out of scope:
if a situation seems to call for one, ask the user instead. `ado.ps1` enforces
this with a `ValidateSet` on `-State`; over MCP, nothing enforces it but you.

Also check before starting:

1. The working tree must be clean. If not, stop and ask the user what to do.
2. Prefer a fresh context. This isn't enforceable from inside the skill, but a
   session already loaded with unrelated work risks bleeding prior assumptions
   into the implementation and burns token budget before the work item is done.
   If the current session has substantial unrelated history, suggest the user
   `/clear` (or start a new session) and re-invoke. Not needed when the session
   is already fresh or was only doing closely related work.

Config the PAT script reads from env (all optional, sensible defaults):
`ADO_ORG_URL` (default `https://dev.azure.com/clauger3e`),
`ADO_PROJECT` (default `MyClauger-Evolution`),
`ADO_REPO` (default: repo name from `git remote get-url origin`).
An MCP server carries its own org/project config; pass the project when its
schema asks for one.

## Workflow

### 1. Fetch the work item

MCP: `<prefix>wit_get_work_item` then `<prefix>wit_list_work_item_comments`.
Fallback:

```
pwsh <skill>/scripts/ado.ps1 get-workitem -Id <id>
pwsh <skill>/scripts/ado.ps1 get-comments -Id <id>
```

Read: title, type, description, acceptance criteria, state, and the **MEP Number**
field (a custom field - look through all `fields` keys *and* values for something
version-shaped, e.g. `14.1`). Comments often carry the real requirement.

If the MCP response has no MEP-like field, ask for the widest `expand` the tool
supports, or re-read through `ado.ps1 get-workitem` (it always expands
everything), before concluding the field is empty.

Summarise the work item back to the user in 2-4 lines before touching code.

### 2. Determine the release branch

- MEP Number `X.Y` -> target branch `release/X.Y`.
- Verify it exists: `git ls-remote --heads origin release/X.Y`.
- If MEP Number is empty, ambiguous, or the branch does not exist: **do not guess.**
  Ask the user directly in the session (see step 7) and wait for their answer.

### 3. Claim the work item, prune finished branches, create the working branch

Assign the item to yourself and move it to **Active** (one of the three allowed
states - see step 0).

MCP: `<prefix>wit_update_work_item`, setting `System.AssignedTo` and
`System.State` = `Active`. The MCP server has no notion of "the PAT owner", so if
you cannot resolve who to assign, ask the user - or use the script form below,
which resolves the identity itself. Fallback:

```
pwsh <skill>/scripts/ado.ps1 start-workitem -Id <id>
```

Defaults the assignee to the PAT owner; pass `-AssignTo "someone@clauger.fr"` to
assign someone else. If the item is already Active / assigned, this is a harmless
no-op; if the API rejects a backward state transition, report it and carry on.

Then refresh, prune finished local branches, and cut the new one:

```
git fetch origin --prune
```

**Prune first.** Delete local branches left over from earlier runs of this skill
that have since finished, so the working copy doesn't accumulate dead branches.
A branch qualifies for cleanup only when **all** of these hold:

- its name matches this skill's pattern - `^(fix|feat|chore)/[0-9]+_`;
- it is not the branch currently checked out, and not a long-lived branch
  (`release/*`, `master`, `main`);
- its PR has completed, or the branch is already merged.

For each candidate branch:

- **`git branch -d <branch>` succeeds** - git already sees it as merged into its
  upstream; nothing more to do (the safe delete refuses if git disagrees).
- **It refuses** - the PR may have been **squash-merged** with the source branch
  deleted (the usual outcome here), so the tip is not an ancestor of anything
  local. Check the PR:
  ```
  pwsh <skill>/scripts/ado.ps1 pr-state -Branch <branch>
  ```
  (No PAT? use `<prefix>repo_list_pull_requests_by_repo` filtered on
  `sourceRefName` = `refs/heads/<branch>`, `status` = `all`, newest first, and
  read its `status`.)
  - `status: "completed"` (`merged: true`) -> the PR landed; `git branch -D <branch>`.
  - `status: "abandoned"` -> PR abandoned without merging; **leave it** and tell
    the user (the work may still be wanted).
  - `status: "active"` or `found: false` -> still in flight; **leave it**.

Never `git branch -D` a branch that doesn't match the skill pattern, and never
delete anything the user created by hand. When unsure, keep the branch and say so.

**Then cut the new branch:**

```
git switch -c <type>/<id>_<short_slug> origin/release/X.Y
```

`<type>` = `feat` for User Story / Feature, `fix` for Bug, else `chore`.
`<short_slug>` = 2-4 lowercase words from the title, `_`-separated.
Match the style of recent branches in this repo (`git branch -a --sort=-committerdate | head`).

### 4. Implement in small intelligible commits

- Follow the repo's `CLAUDE.md` and existing conventions.
- One coherent change per commit; message in the repo's prevailing style
  (check `git log --oneline -20`). Conventional-commits `type: summary` if that
  is what the repo uses.
- Build / run tests after meaningful steps. For this repo: `dotnet build` and
  `dotnet test` (backend) or `npm run build` / `npm run test` / `npm run lint`
  (frontend) as relevant to the change.
- End commit messages with the Co-Authored-By trailer per the harness rules.
- Do NOT push or commit anything the user did not ask for; do NOT skip hooks.

### 5. Push and open the PR

```
git push -u origin <branch>
```

Auto-complete is part of the contract here and `ado.ps1 create-pr` sets it in the
same call, so **this step prefers the script even when an MCP server is
connected**:

```
pwsh <skill>/scripts/ado.ps1 create-pr -Source <branch> -Target release/X.Y `
  -Title "<type>: <title>" -Description "<body>" -WorkItemId <id>
```

It turns on **auto-complete** with a **squash** merge and delete-source-branch, so
the PR merges itself once policies pass. It also sets
`completionOptions.transitionWorkItems` = **false** ("complete associated work
items after merging" unticked): the skill owns the work item state, so the merge
must not move it past `PR Done`.

Only when no PAT is available: create the PR with
`<prefix>repo_create_pull_request` (repo name from `git remote get-url origin`,
source `<branch>`, target `release/X.Y`, title, description; pass the work item id
if the schema has a parameter for it). Then set auto-complete through the server's
PR update tool if it has one, with `transitionWorkItems` false where the schema
exposes it - and if it does not, say plainly that auto-complete is **not** enabled
and the user can switch it on in the ADO UI, leaving "complete associated work
items after merging" unticked.

PR description: short "what / why", a bullet list of the commits, and
`Closes AB#<id>`. Report the PR URL and whether auto-complete is set. Do not
manually complete/merge it. If the user wants a plain PR with no auto-complete,
they can clear it in the ADO UI.

Once the PR is created, move the work item to **PR Done** - the last of the three
allowed states. Never Resolved or Closed: merging the PR handles the rest.

```
pwsh <skill>/scripts/ado.ps1 set-state -Id <id> -State "PR Done"
```

Over MCP: `<prefix>wit_update_work_item` with `System.State` = `PR Done`, nothing
else in the patch. If the transition is rejected (the state is not on this work
item type's workflow), report it in one line and carry on - the PR is what
matters, and the run is not a failure.

### 6. Sonar follow-up (background)

Once the PR exists and the item is at `PR Done`, hand the SonarCloud findings
to the `sonar-pr` skill (same plugin) in a **background subagent**, so the
session stays free while the analysis runs (6-12 min after the push):

- Agent tool, `run_in_background: true`, `isolation: "worktree"` (it may commit
  on the PR branch; the worktree keeps this checkout untouched).
- Prompt: "Use the `m3i-clauger:sonar-pr` skill on PR <prId>. Source branch
  `<branch>`, target `release/X.Y`, work item <id>. Return its report."

Tell the user in one line that the Sonar follow-up is running in the
background, then end the run. When the subagent's report arrives, relay it:
what it fixed (commits), what it justified (replied as false positive), and
what is left for the user. It never touches the work item, which stays at
`PR Done`.

Skip this step when the user asked for a plain PR with no follow-up, or when
the run stopped before the PR was created.

### 7. Asking for missing information

When you need input the work item does not provide (missing/ambiguous MEP Number,
unclear acceptance criteria, a design decision, etc.), **ask the user directly in
this session** and wait for their answer. Never route the question through the
work item - no comments, no field edits beyond the step 3 claim and the step 5
`PR Done`. That rules out the MCP server's `wit_add_work_item_comment`, and limits
`wit_update_work_item` to those two writes, with `System.State` never leaving
`New` / `Active` / `PR Done`.
Prefer `AskUserQuestion` for a bounded choice; plain text for open questions.

## Notes

- All git operations use the user's existing credential manager auth. The PAT, if
  used at all, is only for the REST API (work item read, assign + activate,
  stale-branch PR lookup, PR creation).
- An MCP failure that is about auth/config -> fall back to `ado.ps1` for that
  operation and say so. A failure about the data itself (item not found, branch
  missing, PR exists) -> surface it and stop; do not retry via the other path.
- If any `ado.ps1` call returns a non-zero exit / error JSON, surface the message
  to the user and stop rather than retrying blindly.
