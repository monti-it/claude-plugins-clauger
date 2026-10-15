---
name: story-to-feature
description: Promote an oversized Azure DevOps User Story into a Feature and break it into child User Stories. Convert the item's type in place (keeping its id, history and original text verbatim), re-parent it under its former grandparent with its former parent as a Predecessor link, then propose a set of child stories and on the user's approval create them in ADO linked under the Feature. When details are missing, ask the user directly in the session - never write to the work item beyond the type change, the re-parenting and the child creation. Invoke as /story-to-feature <id>, or when the user says "this story is really a feature", "split story N into a feature", "promote work item N to a feature", "transformer la user story N en feature".
---

# Promote a User Story to a Feature and split it into stories

Some Azure DevOps User Stories grow until their scope is really a Feature. This
skill converts one such item to a **Feature** in place, keeps its original text
untouched, and carves the work into as many child **User Stories** as the content
needs.

## Prerequisites (check once, fail early)

1. A PAT file must exist. Path = `$env:ADO_PAT_FILE`, else `%TEMP%\ado_pat.txt`.
   If missing, tell the user to create it:
   `Set-Content -Path "$env:TEMP\ado_pat.txt" -Value "YOUR_PAT" -NoNewline`
   PAT scope needed: **Work Items (Read & Write)**.
2. The helper script `scripts/ado.ps1` (in this skill dir) wraps every REST call.
   Never print the PAT; never write it into a file or commit.
3. No git work happens here - this skill only restructures work items.

Config the script reads from env (all optional, sensible defaults):
`ADO_ORG_URL` (default `https://dev.azure.com/clauger3e`),
`ADO_PROJECT` (default `MyClauger-Evolution`).

The **only** writes this skill makes are: re-parenting the source item (step 4),
the type change on it (step 5) and creating the child stories (step 6). It never
comments on any item - missing info is asked in-session.

## Workflow

### 1. Fetch the source item

```
pwsh <skill>/scripts/ado.ps1 get-workitem -Id <id>
pwsh <skill>/scripts/ado.ps1 get-comments -Id <id>
```

Read: title, type, `System.Description`, `Microsoft.VSTS.Common.AcceptanceCriteria`,
state, `System.AreaPath`, `System.IterationPath`, `System.Parent`, and the comments.

Also find, in the `fields` bag, the **reference names** of two custom fields the
child stories must inherit:

- **MEP Number** - a version-looking value like `14.1` (same field the
  `process-work-item` skill keys the release branch off).
- **PP** - a project-phase / programme field.

Note both reference names (e.g. `Custom.MEPNumber`, `Custom.PP` - the exact keys
vary by process) and their current values. If either can't be found, ask the user
which field it is rather than guessing.

Then resolve the hierarchy around the item (needed for step 4):

- **P** = the item's current parent (`System.Parent`).
- **GP** = P's parent - fetch P with `get-workitem -Id <P>` and read its
  `System.Parent`.

After the promotion the new Feature should sit where P sat: parent **GP**, with
**P** recorded as its **Predecessor**.

### 2. Sanity-check

- If the type is already `Feature`, skip step 5 (only re-parent + create children).
- If the type is not `User Story` / `Product Backlog Item`, stop and confirm with
  the user before treating it as promotable.
- If the item already has child links, list them to the user and ask how to
  proceed before creating more.
- If the item has **no parent (P)**, there is nothing to re-parent against - tell
  the user and ask whether to set a parent / predecessor manually before step 4.
- If P exists but has **no parent (GP)**, the new Feature would end up with no
  parent - confirm that with the user (predecessor P is still set).

Summarise the item back to the user in 2-4 lines, including P and GP.

### 3. Propose the breakdown

Analyse the description, acceptance criteria and comments, then draft:

- **The Feature** - keeps the *original title and description verbatim*. Do not
  rewrite the Feature text. (You may note a suggested cleaner title separately,
  but only apply it if the user asks.)
- **Child User Stories** - one per independently-deliverable slice of the work.
  For each: a clear title, a `<As a... I want... so that...>`-style description,
  and acceptance criteria. Enhance freely here: reword, split, fill gaps, and add
  acceptance criteria so each story stands on its own. Every requirement in the
  original text must land in exactly one child story (no scope lost, no overlap).

Present the proposal in the session as a numbered list (title + description +
acceptance criteria per story). **Wait for the user's approval.** Incorporate any
edits, add/remove/merge stories as they direct, and re-confirm if the changes are
substantial.

### 4. Re-parent the item

Only after approval. Do this **before** the type change, so the item never sits
in the invalid "Feature under a Feature" state during conversion.

```
pwsh <skill>/scripts/ado.ps1 relink -Id <id> -NewParentId <GP> -PredecessorId <P>
```

This drops the existing parent link (to P), adds a parent link to **GP**, and
adds **P** as a Predecessor (`System.LinkTypes.Dependency-Reverse`). Pass only the
flags that apply (e.g. omit `-NewParentId` when there is no GP).

### 5. Convert the source item to a Feature

```
pwsh <skill>/scripts/ado.ps1 change-type -Id <id>
```

Pass `-Type "<name>"` for a non-default target type, `-State "<name>"` if the
Feature workflow needs a different state than the item currently has. If the API
rejects the in-place type change (some process configs disallow it), tell the
user to change the type in the ADO UI, then re-run the skill - it will see the
item is already a Feature and skip straight to step 6. On a re-run, check the
item's current links first: only call `relink` for a link that is still missing
(re-adding an existing relation is rejected by the API).

### 6. Create the child stories

For each approved story, in order:

```
pwsh <skill>/scripts/ado.ps1 create-child -ParentId <id> `
  -Title "<title>" -Description "<html or text>" `
  -AcceptanceCriteria "<html or text>" `
  -CopyFields "<MEP ref>,<PP ref>"
```

`Area Path` and `Iteration Path` are inherited from the parent automatically;
override with `-AreaPath` / `-IterationPath` only if the user asks. Pass `-Type`
for a non-default child type.

`-CopyFields` copies the given field reference names verbatim from the parent
(the promoted item, which kept the original story's values through the type
change) - use it to carry the **MEP Number** and **PP** onto every child story.
Check each result's `copiedFields` / `missingFields`: if a field lands in
`missingFields`, the parent had no value for that reference name - stop and
confirm the reference name with the user.

If a call fails partway through, stop and report exactly which stories were
created (with ids/urls) and which were not, so the run can be resumed by hand.

### 7. Report

Give the user:
- the Feature url, its new type, its new parent (GP) and its predecessor (P),
- a bullet list of every created story (`AB#<id>` + title + url),
- the MEP Number and PP values copied onto the child stories,
- a one-line confirmation that the Feature text was left unchanged.

### 8. Asking for missing information

When you need input the item does not provide (how finely to slice, an unclear
requirement, a target area/iteration, a design decision, an absent P/GP), **ask
the user directly in this session** and wait. Never write anything to the work
item beyond steps 4-6. Prefer `AskUserQuestion` for a bounded choice; plain text
for open ones.

## Notes

- Descriptions and acceptance criteria in ADO are HTML fields - simple text is
  fine, but use `<br>`/`<ul><li>` if you want structure to render.
- If any `ado.ps1` call returns a non-zero exit / error JSON, surface the message
  to the user and stop rather than retrying blindly.
