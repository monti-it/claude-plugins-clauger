# story-to-feature

A [Claude Code](https://claude.com/claude-code) **skill** that promotes an
oversized Azure DevOps User Story into a Feature and splits it into child User
Stories.

## What it does

Given a work item id, it:

1. Fetches the item (title, description, acceptance criteria, area/iteration,
   parent, comments).
2. Proposes a breakdown in the session: the **Feature** (keeps the original text
   verbatim) plus a set of **child User Stories**, each with an enhanced title,
   description and acceptance criteria covering one slice of the original scope.
3. On your approval, re-parents the item: parent becomes its former
   **grandparent**, and its former **parent** is recorded as a **Predecessor**
   link.
4. Changes the item's type to **Feature** in place (same id, same history).
5. Creates each approved child User Story in ADO, linked under the Feature and
   inheriting its Area / Iteration path plus the original story's **MEP Number**
   and **PP** custom fields.
6. Reports the Feature url and every created story.

When information is missing or ambiguous it **asks you directly in the session** —
it never comments on any work item. The only writes it makes are the re-parenting,
the type change and the child creation.

## Install

Ships in the `m3i-clauger` plugin - see the [repo README](../../../../README.md#install).

## Setup

Create a PAT file (default `%TEMP%\ado_pat.txt`, or point `ADO_PAT_FILE` at your
own path):

```powershell
Set-Content -Path "$env:TEMP\ado_pat.txt" -Value "YOUR_PAT" -NoNewline
```

PAT scope: **Work Items (Read & Write)**.

Optional environment overrides:

| Var           | Default                             |
|---------------|-------------------------------------|
| `ADO_PAT_FILE`| `%TEMP%\ado_pat.txt`                 |
| `ADO_ORG_URL` | `https://dev.azure.com/clauger3e`    |
| `ADO_PROJECT` | `MyClauger-Evolution`               |

Requires PowerShell 7 (`pwsh`) on PATH. The PAT is only used for the REST API and
is never printed or stored.

## Usage

```
/story-to-feature 17808
```

or just: *"work item 17808 is really a feature, split it"*.

## Layout

```
story-to-feature/
├── SKILL.md              the workflow Claude follows
├── scripts/ado.ps1       Azure DevOps REST wrapper
│                         (get-workitem, get-comments, relink, change-type, create-child)
└── README.md             this file
```
