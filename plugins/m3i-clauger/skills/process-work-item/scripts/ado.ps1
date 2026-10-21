#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Thin wrapper over the Azure DevOps REST API for the process-work-item skill.
  Fallback path: prefer an Azure DevOps MCP server when one is connected.

.DESCRIPTION
  Subcommands:
    get-workitem   -Id <n>
    get-comments   -Id <n>
    start-workitem -Id <n> [-AssignTo <user>]
                   assigns the item (default: the PAT owner) and sets its
                   state to Active
    set-state      -Id <n> -State <New|Active|PR Done>
                   sets the work item state and nothing else
    pr-state       -Branch <branch> [-Repo <name>]
                   reports the most recent PR opened from <branch>:
                   { found, pullRequestId, status (active|completed|abandoned),
                     merged, url }
    create-pr      -Source <branch> -Target <branch> -Title <string>
                   -Description <string> [-WorkItemId <n>] [-Repo <name>]
                   (also enables auto-complete with a squash merge +
                    delete source branch, the web UI's "Merged PR <id>: <title>"
                    commit message, and turns "complete associated work
                    items after merging" off)

  Work item states: only New, Active and PR Done may ever be written. -State is
  validated against that set, so no other state can leave this script.

  Auth: reads a PAT from $env:ADO_PAT_FILE, else %TEMP%\ado_pat.txt.
  The PAT is never printed and never written anywhere.
  PAT scopes: Work Items (Read & Write), Code (Read & Write), Pull Request.

  Config via environment (all optional):
    ADO_ORG_URL   default https://dev.azure.com/clauger3e
    ADO_PROJECT   default MyClauger-Evolution
    ADO_REPO      default: repo name parsed from `git remote get-url origin`
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)]
  [ValidateSet('get-workitem', 'get-comments', 'start-workitem', 'set-state', 'pr-state', 'create-pr')]
  [string]$Command,

  [int]$Id,
  [string]$AssignTo,
  [string]$Branch,
  [string]$Source,
  [string]$Target,
  [string]$Title,
  [string]$Description,
  [int]$WorkItemId,
  [string]$Repo,
  # The only work item states this skill is allowed to write.
  [ValidateSet('New', 'Active', 'PR Done')]
  [string]$State = 'Active'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail($msg) {
  Write-Error $msg
  exit 1
}

# --- auth -------------------------------------------------------------------
$patFile = if ($env:ADO_PAT_FILE) { $env:ADO_PAT_FILE } else { Join-Path $env:TEMP 'ado_pat.txt' }
if (-not (Test-Path $patFile)) {
  Fail "PAT file not found: $patFile`nEither connect an Azure DevOps MCP server (no PAT needed), or create the file with:`nSet-Content -Path `"$patFile`" -Value `"YOUR_PAT`" -NoNewline"
}
$pat = (Get-Content -Raw -Path $patFile).Trim()
if (-not $pat) { Fail "PAT file is empty: $patFile" }
$authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = $authHeader }

# --- config ---------------------------------------------------------------
$org = if ($env:ADO_ORG_URL) { $env:ADO_ORG_URL.TrimEnd('/') } else { 'https://dev.azure.com/clauger3e' }
$project = if ($env:ADO_PROJECT) { $env:ADO_PROJECT } else { 'MyClauger-Evolution' }

function Get-RepoName {
  if ($env:ADO_REPO) { return $env:ADO_REPO }
  if ($Repo) { return $Repo }
  $url = (& git remote get-url origin 2>$null)
  if ($LASTEXITCODE -eq 0 -and $url) {
    return ($url -replace '\.git$', '' -split '/')[-1]
  }
  Fail 'Could not determine repository name; pass -Repo or set $env:ADO_REPO.'
}

function Get-MeIdentity {
  # Unique name / email of the PAT owner, for System.AssignedTo.
  $cd = Invoke-Ado -Method GET -Uri "$org/_apis/connectionData?api-version=7.1"
  $u = $cd.authenticatedUser
  foreach ($cand in @(
      $u.properties.Account.'$value',
      $u.uniqueName,
      $u.providerDisplayName)) {
    if ($cand) { return $cand }
  }
  Fail 'Could not resolve the current user; pass -AssignTo explicitly.'
}

function Invoke-Ado {
  param(
    [string]$Method,
    [string]$Uri,
    [object]$Body,
    [string]$ContentType = 'application/json'
  )
  $params = @{
    Method      = $Method
    Uri         = $Uri
    Headers     = $headers
    ContentType = $ContentType
  }
  if ($null -ne $Body) {
    $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 }
  }
  try {
    return Invoke-RestMethod @params
  }
  catch {
    $resp = $_.Exception.Response
    $detail = ''
    if ($resp) {
      try {
        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        $detail = $reader.ReadToEnd()
      }
      catch { }
    }
    Fail "ADO API $Method $Uri failed: $($_.Exception.Message)`n$detail"
  }
}

switch ($Command) {

  'get-workitem' {
    if (-not $Id) { Fail '-Id is required.' }
    $uri = "$org/_apis/wit/workitems/$Id`?`$expand=all&api-version=7.1"
    $wi = Invoke-Ado -Method GET -Uri $uri
    # Emit the full fields bag plus a convenience projection.
    [pscustomobject]@{
      id        = $wi.id
      url       = "$org/_workitems/edit/$($wi.id)"
      type      = $wi.fields.'System.WorkItemType'
      title     = $wi.fields.'System.Title'
      state     = $wi.fields.'System.State'
      fields    = $wi.fields
    } | ConvertTo-Json -Depth 20
  }

  'get-comments' {
    if (-not $Id) { Fail '-Id is required.' }
    $uri = "$org/$project/_apis/wit/workItems/$Id/comments?api-version=7.1-preview.4"
    $res = Invoke-Ado -Method GET -Uri $uri
    $res.comments |
      Select-Object @{n = 'author'; e = { $_.createdBy.displayName } },
                    @{n = 'date'; e = { $_.createdDate } },
                    text |
      ConvertTo-Json -Depth 10
  }

  'start-workitem' {
    if (-not $Id) { Fail '-Id is required.' }
    $assignee = if ($AssignTo) { $AssignTo } else { Get-MeIdentity }
    $patch = @(
      @{ op = 'add'; path = '/fields/System.AssignedTo'; value = $assignee }
      @{ op = 'add'; path = '/fields/System.State'; value = $State }
    )
    $uri = "$org/_apis/wit/workitems/$Id`?api-version=7.1"
    $wi = Invoke-Ado -Method PATCH -Uri $uri `
      -Body ($patch | ConvertTo-Json -Depth 10 -AsArray) `
      -ContentType 'application/json-patch+json'
    [pscustomobject]@{
      id         = $wi.id
      assignedTo = $wi.fields.'System.AssignedTo'.displayName
      state      = $wi.fields.'System.State'
    } | ConvertTo-Json
  }

  'set-state' {
    if (-not $Id) { Fail '-Id is required.' }
    # $State is already constrained to New / Active / PR Done by its ValidateSet.
    $patch = @(
      @{ op = 'add'; path = '/fields/System.State'; value = $State }
    )
    $uri = "$org/_apis/wit/workitems/$Id`?api-version=7.1"
    $wi = Invoke-Ado -Method PATCH -Uri $uri `
      -Body ($patch | ConvertTo-Json -Depth 10 -AsArray) `
      -ContentType 'application/json-patch+json'
    [pscustomobject]@{
      id    = $wi.id
      state = $wi.fields.'System.State'
    } | ConvertTo-Json
  }

  'pr-state' {
    if (-not $Branch) { Fail '-Branch is required.' }
    $repoName = Get-RepoName
    $branch = ($Branch -replace '^refs/heads/', '')
    $uri = "$org/$project/_apis/git/repositories/$repoName/pullrequests" +
           "?searchCriteria.sourceRefName=refs/heads/$branch" +
           '&searchCriteria.status=all&api-version=7.1'
    $res = Invoke-Ado -Method GET -Uri $uri
    $prs = @($res.value) | Sort-Object -Property pullRequestId -Descending
    if (-not $prs -or $prs.Count -eq 0) {
      [pscustomobject]@{ branch = $branch; found = $false } | ConvertTo-Json
    }
    else {
      $pr = $prs[0]
      [pscustomobject]@{
        branch        = $branch
        found         = $true
        pullRequestId = $pr.pullRequestId
        status        = $pr.status
        merged        = ($pr.status -eq 'completed')
        url           = "$org/$project/_git/$repoName/pullrequest/$($pr.pullRequestId)"
      } | ConvertTo-Json
    }
  }

  'create-pr' {
    foreach ($p in 'Source', 'Target', 'Title') {
      if (-not (Get-Variable -Name $p -ValueOnly)) { Fail "-$p is required." }
    }
    $repoName = Get-RepoName
    $body = @{
      sourceRefName = "refs/heads/$($Source -replace '^refs/heads/', '')"
      targetRefName = "refs/heads/$($Target -replace '^refs/heads/', '')"
      title         = $Title
      description   = $Description
    }
    if ($WorkItemId) { $body.workItemRefs = @(@{ id = "$WorkItemId" }) }
    $baseUri = "$org/$project/_apis/git/repositories/$repoName/pullrequests"
    $pr = Invoke-Ado -Method POST -Uri "$baseUri`?api-version=7.1" -Body $body

    # Enable auto-complete with a squash merge (set by the PR creator).
    $autoComplete = $false
    if ($pr.createdBy.id) {
      # Same squash message the ADO web UI pre-fills; without it the server falls
      # back to "Merge pull request <id> from <source> into <target>".
      $mergeMessage = "Merged PR $($pr.pullRequestId): $Title"
      if ($Description) { $mergeMessage += "`n`n$Description" }
      if ($WorkItemId) { $mergeMessage += "`n`nRelated work items: #$WorkItemId" }
      $patch = @{
        autoCompleteSetBy = @{ id = $pr.createdBy.id }
        completionOptions = @{
          mergeStrategy       = 'squash'
          mergeCommitMessage  = $mergeMessage
          deleteSourceBranch  = $true
          # "Complete associated work items after merging": off. The skill owns
          # the work item state (New / Active / PR Done) and must not let the
          # merge transition it to anything else.
          transitionWorkItems = $false
        }
      }
      $pr = Invoke-Ado -Method PATCH -Uri "$baseUri/$($pr.pullRequestId)?api-version=7.1" -Body $patch
      $autoComplete = $null -ne $pr.autoCompleteSetBy
    }

    [pscustomobject]@{
      pullRequestId       = $pr.pullRequestId
      url                 = "$org/$project/_git/$repoName/pullrequest/$($pr.pullRequestId)"
      autoComplete        = $autoComplete
      mergeStrategy       = 'squash'
      transitionWorkItems = $false
    } | ConvertTo-Json
  }
}
