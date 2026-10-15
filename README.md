# claude-plugins-clauger

Claude Code skills for Clauger's Azure DevOps workflow (org `clauger3e`, project
`MyClauger-Evolution`), packaged as a plugin marketplace.

| Skill | What it does |
|---|---|
| `process-work-item` | One ADO work item from ticket to PR: claim it, branch from `release/{MEP Number}`, small commits, PR with squash auto-complete, item to `PR Done`, then launch `sonar-pr` in the background. |
| `sonar-pr` | Waits for the PR build and the SonarCloud analysis, then fixes the clear findings in new commits, replies with the reason on false positives, and reports the rest. |
| `story-to-feature` | Promotes an oversized User Story to a Feature in place and splits it into child User Stories. |

All three ship in one plugin, `m3i-clauger`.

## Install

In Claude Code:

```
/plugin marketplace add monti-it/claude-plugins-clauger
/plugin install m3i-clauger@monti-it-clauger
```

Or for a whole repo, so teammates get it offered on first open, add to the
repo's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "monti-it-clauger": {
      "source": { "source": "github", "repo": "monti-it/claude-plugins-clauger" }
    }
  },
  "enabledPlugins": {
    "m3i-clauger@monti-it-clauger": true
  }
}
```

Skills are then available as `/m3i-clauger:process-work-item <id>`,
`/m3i-clauger:sonar-pr <prId>` and `/m3i-clauger:story-to-feature <id>` (or just
by asking, e.g. "process work item 18069").

## Setup

**Azure DevOps access.** The skills prefer a connected Azure DevOps MCP server
and fall back to small PowerShell scripts (`pwsh`) calling the REST API with a
personal access token. Some steps always use the script when a PAT exists (PR
creation with auto-complete, Sonar thread handling), so a PAT is recommended:

```powershell
Set-Content -Path "$env:TEMP\ado_pat.txt" -Value "YOUR_PAT" -NoNewline
```

Or point `ADO_PAT_FILE` at another path. Scopes: **Work Items (Read & Write)**,
**Code (Read & Write)**. The scripts never print or store the PAT.

Optional environment overrides: `ADO_ORG_URL` (default
`https://dev.azure.com/clauger3e`), `ADO_PROJECT` (default
`MyClauger-Evolution`), `ADO_REPO` (default: from `git remote get-url origin`).

## What the skills will and won't do

- Work item writes are limited to assign + state, and the state only ever goes
  to `New`, `Active` or `PR Done`. They never comment on a work item; missing
  information is asked in the session.
- PRs merge with squash auto-complete, with "complete associated work items
  after merging" **off**.
- `sonar-pr` only pushes new commits (never amends or force-pushes), only
  touches code the PR changed, never resolves threads, never merges, and stops
  after two fix rounds. It can't dismiss issues in SonarCloud itself: false
  positives get an ADO reply, and someone with SonarCloud access marks them.

## License

[MIT](LICENSE)
