# Conventions for process-work-item

## Release branches
- Pattern: `release/{MEP Number}` where MEP Number is the version on the work item
  (e.g. MEP Number `14.1` -> `release/14.1`).
- The PR always targets this branch, never `master`/`main`.
- Never create the release branch; it must already exist on `origin`.

## Work item states
- The skill writes **only** these three states, whichever access path it uses:
  - `New` - never written automatically; only if the user explicitly asks to put
    an item back.
  - `Active` - set when the item is claimed (step 3).
  - `PR Done` - set once the pull request is created (step 5).
- Anything else (`Resolved`, `Closed`, `Removed`, ...) is out of scope. If a
  situation seems to need one, ask the user rather than writing it.
- `ado.ps1` enforces this with a `ValidateSet` on `-State`, shared by
  `start-workitem` and `set-state`. Over MCP there is no enforcement: the same
  restriction applies to `wit_update_work_item` by discipline.
- A rejected state transition (backward, or a state absent from the work item
  type's workflow) is reported to the user and does not stop the run.

## Claiming the work item
- Before branching, `start-workitem` assigns the item to the PAT owner
  (override with `-AssignTo`) and sets `System.State` = `Active`.
- Already-active / already-assigned items: harmless.

## Handing the work item off
- Right after the PR is created: `ado.ps1 set-state -Id <id> -State "PR Done"`
  (or `wit_update_work_item` with `System.State` = `PR Done` and nothing else).
- Never Resolved/Closed - completing the PR takes care of the rest.

## Working branch
- Name: `<type>/<workItemId>_<short_slug>`
  - `feat/` - User Story, Feature, Product Backlog Item
  - `fix/`  - Bug
  - `chore/` - Task, everything else
  - `<short_slug>`: 2-4 lowercase words from the title, `_`-separated
    (e.g. `feat/17808_unit_cmi`).
- Always branched from `origin/release/{MEP Number}` after `git fetch`.

## Local branch cleanup
- Runs at the start of step 3, before the new branch is cut, so successive runs
  don't leave a trail of dead branches.
- Only ever touches branches matching this skill's own name pattern
  (`^(fix|feat|chore)/[0-9]+_`) - branches the user made by hand are never
  deleted.
- Skips the current branch and long-lived branches (`release/*`, `master`, `main`).
- `git branch -d` succeeds (git sees it as merged) -> done.
- Otherwise ask `ado.ps1 pr-state -Branch <branch>` (or
  `repo_list_pull_requests_by_repo` filtered on the source ref when there is no
  PAT): `completed` -> `git branch -D`; `abandoned` -> leave it and tell the
  user; `active` / no PR -> leave it. The source branch is normally deleted on
  completion (delete-source-branch auto-complete), so the squash-merge case is
  the common one.

## Commits
- Small and self-contained: one reviewable idea per commit.
- Message style: match `git log --oneline -20` of the target repo. These repos use
  Conventional Commits: `feat: ...`, `fix: ...`, `chore: ...`.
- Always append the harness Co-Authored-By trailer.
- Never `--no-verify`, never `--amend` an existing pushed commit.

## Pull request
- Title: `<type>: <work item title>` (or a crisper summary).
- Description:
  - **What / Why** - 1-3 sentences.
  - **Changes** - bullet list mirroring the commits.
  - Footer: `Closes AB#<workItemId>` (links the work item).
- Link the work item: `ado.ps1 create-pr -WorkItemId` (sends `workItemRefs`), or
  the MCP PR tool's work-item parameter when it has one. Either way keep the
  `Closes AB#<id>` footer, which links it too.
- Auto-complete is enabled on creation with **squash** merge strategy and
  delete-source-branch (`ado.ps1 create-pr` PATCHes `autoCompleteSetBy` +
  `completionOptions` right after creating the PR). Do not merge it by hand.
- The squash commit message is the one the ADO web UI pre-fills -
  `Merged PR <id>: <title>`, blank line, the description, blank line,
  `Related work items: #<id>` - sent as `completionOptions.mergeCommitMessage`.
  Without it, a server-side auto-complete writes
  `Merge pull request <id> from <source> into <target>` instead.
- **"Complete associated work items after merging" is off** -
  `completionOptions.transitionWorkItems = false`. The skill owns the work item
  state and leaves it at `PR Done`; the merge must not transition it further.
  Over MCP, if the PR tool exposes the flag, set it to false; if it does not,
  tell the user to untick the box in the PR's auto-complete dialog.
  This is why the PR step prefers the script even when an MCP server is
  connected - see `references/mcp-tools.md`.

## Missing information
- The only work item writes allowed are assign + activate (the claim above) and
  the `PR Done` hand-off, whether via `ado.ps1` or the MCP `wit_update_work_item`.
- Never comment on the work item - that rules out `wit_add_work_item_comment`.
  Ask the user directly in the session and wait for the answer:
  `AskUserQuestion` for a bounded choice, plain text for open questions.

## Access model
- Azure DevOps API access, in order of preference:
  1. **An Azure DevOps MCP server**, when one is connected - no PAT involved.
     Detection and tool mapping: `references/mcp-tools.md`.
  2. **`scripts/ado.ps1` with a PAT** from `$env:ADO_PAT_FILE` or
     `%TEMP%\ado_pat.txt` (scopes: Work Items Read & Write, Code Read & Write,
     Pull Request), when no MCP server covers the operation.
- The choice is made per operation: MCP for the work item read and `ado.ps1` for
  the PR is the expected combination, not a fallback.
- git push / fetch never uses either - it goes through the user's Windows
  credential manager (already configured).
