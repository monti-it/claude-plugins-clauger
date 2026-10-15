# process-work-item

A [Claude Code](https://claude.com/claude-code) **skill** that takes one Azure
DevOps work item from ticket to pull request.

## What it does

Given a work item id, it:

1. Fetches the work item (title, type, description, acceptance criteria, comments).
2. Reads the **MEP Number** field and derives the target release branch
   `release/{MEP Number}`.
3. Assigns the work item to the PAT owner, moves it to **Active**, prunes local
   branches from finished earlier runs (completed / squash-merged PRs), and cuts
   a fresh branch `<type>/<id>_<slug>` from `origin/release/{MEP Number}`.
4. Implements the change in small, self-contained conventional commits, building
   and testing as it goes.
5. Pushes and opens a pull request back to the release branch, linking the work
   item, with **auto-complete** enabled (squash merge, delete source branch, and
   *complete associated work items after merging* **off**), then moves the work
   item to **PR Done**.

When information is missing or ambiguous it **asks you directly in the session** —
it never comments on the work item. The only work item changes it makes are the
assign + activate in step 3 and the PR Done in step 5.

## Work item states

The skill writes **only three states**, and never any other:

| State     | When                                                        |
|-----------|-------------------------------------------------------------|
| `New`     | never automatically — only if you explicitly ask for it back |
| `Active`  | when the item is claimed, before branching                   |
| `PR Done` | once the pull request is created                             |

`Resolved`, `Closed`, `Removed` and friends are out of scope: the skill asks you
rather than writing one. `scripts/ado.ps1` enforces the set with a `ValidateSet`
on `-State`, so the fallback path cannot write anything else even by mistake.

For the same reason the PR is created with **“complete associated work items after
merging” off** (`completionOptions.transitionWorkItems = false`) — the merge is
not allowed to move the item past `PR Done` behind the skill’s back.

## Install

Ships in the `m3i-clauger` plugin - see the [repo README](../../../../README.md#install).

## Setup

Azure DevOps access has two paths. The skill picks the first one that is
available, per operation.

### 1. Azure DevOps MCP server (preferred, no PAT)

If an ADO MCP server is connected, the skill uses it for reading the work item
and its comments, for claiming it (assign + activate) and for the final
`PR Done`. Nothing else to
configure — it detects the server from its tool names (`…wit_get_work_item`,
`…wit_update_work_item`, …), whatever you named it.

Opening the PR still goes through `scripts/ado.ps1` when a PAT is available,
because the script also switches on squash auto-complete in the same step and
MCP servers generally cannot. With no PAT, the PR is created over MCP and you
enable auto-complete yourself in the ADO UI.

The official Microsoft server, for example:

```bash
claude mcp add ado -- npx -y @azure-devops/mcp <your-org>
```

Details of the mapping and its quirks live in `references/mcp-tools.md`.

### 2. PAT + REST script (fallback)

Used when no MCP server is connected, or for an operation the server does not
cover. Create a PAT file (default `%TEMP%\ado_pat.txt`, or point `ADO_PAT_FILE`
at your own path):

```powershell
Set-Content -Path "$env:TEMP\ado_pat.txt" -Value "YOUR_PAT" -NoNewline
```

PAT scopes: **Work Items (Read & Write)**, **Code (Read & Write)**, **Pull Request**.

Optional environment overrides:

| Var           | Default                             |
|---------------|-------------------------------------|
| `ADO_PAT_FILE`| `%TEMP%\ado_pat.txt`                 |
| `ADO_ORG_URL` | `https://dev.azure.com/clauger3e`    |
| `ADO_PROJECT` | `MyClauger-Evolution`               |
| `ADO_REPO`    | repo name from `git remote origin`  |

Requires PowerShell 7 (`pwsh`) on PATH.

Either way, git push/fetch uses your existing credential helper; the PAT is only
used for the REST API and is never printed or stored.

## Usage

```
/process-work-item 17808
```

or just: *"process work item 17808"*.

## Layout

```
process-work-item/
├── SKILL.md                    the workflow Claude follows
├── scripts/ado.ps1             Azure DevOps REST wrapper (get-workitem, get-comments, start-workitem, set-state, pr-state, create-pr w/ squash auto-complete)
├── references/mcp-tools.md     MCP server detection + tool mapping (preferred path)
└── references/conventions.md   branch / commit / PR rules
```
