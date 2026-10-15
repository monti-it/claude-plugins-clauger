#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Thin wrapper over the Azure DevOps REST API for the story-to-feature skill.

.DESCRIPTION
  Subcommands:
    get-workitem  -Id <n>
    get-comments  -Id <n>
    change-type   -Id <n> [-Type <string>] [-State <string>]
                  changes System.WorkItemType in place (default target: Feature),
                  keeping the id, history and existing links
    relink        -Id <n> [-NewParentId <n>] [-PredecessorId <n>]
                  replaces the item's parent (Hierarchy) link with NewParentId
                  and/or adds PredecessorId as a Predecessor (Dependency) link
    create-child  -ParentId <n> -Title <string> [-Description <string>]
                  [-AcceptanceCriteria <string>] [-Type <string>]
                  [-AreaPath <string>] [-IterationPath <string>]
                  [-CopyFields <ref[,ref...]>]
                  creates a work item (default type: User Story) linked as a
                  child of ParentId; Area/Iteration default to the parent's;
                  CopyFields copies the listed field reference names (e.g. the
                  MEP Number and PP custom fields) verbatim from the parent

  Auth: reads a PAT from $env:ADO_PAT_FILE, else %TEMP%\ado_pat.txt.
  The PAT is never printed and never written anywhere.
  PAT scopes: Work Items (Read & Write).

  Config via environment (all optional):
    ADO_ORG_URL   default https://dev.azure.com/clauger3e
    ADO_PROJECT   default MyClauger-Evolution
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)]
  [ValidateSet('get-workitem', 'get-comments', 'change-type', 'relink', 'create-child')]
  [string]$Command,

  [int]$Id,
  [int]$ParentId,
  [int]$NewParentId,
  [int]$PredecessorId,
  [string]$Type,
  [string]$Title,
  [string]$Description,
  [string]$AcceptanceCriteria,
  [string]$AreaPath,
  [string]$IterationPath,
  [string]$State,
  [string]$CopyFields
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
  Fail "PAT file not found: $patFile`nCreate it with: Set-Content -Path `"$patFile`" -Value `"YOUR_PAT`" -NoNewline"
}
$pat = (Get-Content -Raw -Path $patFile).Trim()
if (-not $pat) { Fail "PAT file is empty: $patFile" }
$authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = $authHeader }

# --- config ---------------------------------------------------------------
$org = if ($env:ADO_ORG_URL) { $env:ADO_ORG_URL.TrimEnd('/') } else { 'https://dev.azure.com/clauger3e' }
$project = if ($env:ADO_PROJECT) { $env:ADO_PROJECT } else { 'MyClauger-Evolution' }

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

function Get-WorkItem($wid) {
  Invoke-Ado -Method GET -Uri "$org/_apis/wit/workitems/$wid`?`$expand=all&api-version=7.1"
}

switch ($Command) {

  'get-workitem' {
    if (-not $Id) { Fail '-Id is required.' }
    $wi = Get-WorkItem $Id
    [pscustomobject]@{
      id     = $wi.id
      url    = "$org/_workitems/edit/$($wi.id)"
      type   = $wi.fields.'System.WorkItemType'
      title  = $wi.fields.'System.Title'
      state  = $wi.fields.'System.State'
      fields = $wi.fields
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

  'change-type' {
    if (-not $Id) { Fail '-Id is required.' }
    $target = if ($Type) { $Type } else { 'Feature' }
    $patch = @(
      @{ op = 'add'; path = '/fields/System.WorkItemType'; value = $target }
    )
    if ($State) { $patch += @{ op = 'add'; path = '/fields/System.State'; value = $State } }
    $uri = "$org/_apis/wit/workitems/$Id`?api-version=7.1"
    $wi = Invoke-Ado -Method PATCH -Uri $uri `
      -Body ($patch | ConvertTo-Json -Depth 10 -AsArray) `
      -ContentType 'application/json-patch+json'
    [pscustomobject]@{
      id    = $wi.id
      url   = "$org/_workitems/edit/$($wi.id)"
      type  = $wi.fields.'System.WorkItemType'
      state = $wi.fields.'System.State'
    } | ConvertTo-Json
  }

  'relink' {
    if (-not $Id) { Fail '-Id is required.' }
    if (-not $NewParentId -and -not $PredecessorId) {
      Fail 'Pass -NewParentId and/or -PredecessorId.'
    }
    $wi = Get-WorkItem $Id
    $relations = @()
    if (($wi.PSObject.Properties.Name -contains 'relations') -and $wi.relations) {
      $relations = @($wi.relations)
    }

    $patch = @()
    if ($NewParentId) {
      # Remove existing parent link(s); descending index order keeps paths valid.
      $parentIdx = for ($i = 0; $i -lt $relations.Count; $i++) {
        if ($relations[$i].rel -eq 'System.LinkTypes.Hierarchy-Reverse') { $i }
      }
      foreach ($i in @($parentIdx | Where-Object { $null -ne $_ } | Sort-Object -Descending)) {
        $patch += @{ op = 'test'; path = "/relations/$i/url"; value = $relations[$i].url }
        $patch += @{ op = 'remove'; path = "/relations/$i" }
      }
      $patch += @{
        op    = 'add'; path = '/relations/-'
        value = @{
          rel = 'System.LinkTypes.Hierarchy-Reverse'
          url = "$org/_apis/wit/workItems/$NewParentId"
        }
      }
    }
    if ($PredecessorId) {
      $patch += @{
        op    = 'add'; path = '/relations/-'
        value = @{
          rel = 'System.LinkTypes.Dependency-Reverse'
          url = "$org/_apis/wit/workItems/$PredecessorId"
        }
      }
    }

    $uri = "$org/_apis/wit/workitems/$Id`?api-version=7.1"
    $res = Invoke-Ado -Method PATCH -Uri $uri `
      -Body ($patch | ConvertTo-Json -Depth 10 -AsArray) `
      -ContentType 'application/json-patch+json'

    $newParent = $null
    $preds = @()
    foreach ($r in @($res.relations)) {
      switch ($r.rel) {
        'System.LinkTypes.Hierarchy-Reverse' { $newParent = ($r.url -split '/')[-1] }
        'System.LinkTypes.Dependency-Reverse' { $preds += ($r.url -split '/')[-1] }
      }
    }
    [pscustomobject]@{
      id             = $res.id
      url            = "$org/_workitems/edit/$($res.id)"
      parentId       = $newParent
      predecessorIds = $preds
    } | ConvertTo-Json
  }

  'create-child' {
    if (-not $ParentId) { Fail '-ParentId is required.' }
    if (-not $Title) { Fail '-Title is required.' }
    $childType = if ($Type) { $Type } else { 'User Story' }

    $parent = Get-WorkItem $ParentId
    $area = if ($AreaPath) { $AreaPath } else { $parent.fields.'System.AreaPath' }
    $iter = if ($IterationPath) { $IterationPath } else { $parent.fields.'System.IterationPath' }

    $patch = @(
      @{ op = 'add'; path = '/fields/System.Title'; value = $Title }
      @{ op = 'add'; path = '/fields/System.AreaPath'; value = $area }
      @{ op = 'add'; path = '/fields/System.IterationPath'; value = $iter }
      @{
        op    = 'add'; path = '/relations/-'
        value = @{
          rel = 'System.LinkTypes.Hierarchy-Reverse'
          url = "$org/_apis/wit/workItems/$ParentId"
        }
      }
    )
    if ($Description) {
      $patch += @{ op = 'add'; path = '/fields/System.Description'; value = $Description }
    }
    if ($AcceptanceCriteria) {
      $patch += @{ op = 'add'; path = '/fields/Microsoft.VSTS.Common.AcceptanceCriteria'; value = $AcceptanceCriteria }
    }

    # Copy extra fields (e.g. MEP Number, PP) verbatim from the parent.
    $copied = @()
    $missing = @()
    if ($CopyFields) {
      foreach ($ref in ($CopyFields -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $prop = $parent.fields.PSObject.Properties[$ref]
        if ($prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') {
          $patch += @{ op = 'add'; path = "/fields/$ref"; value = $prop.Value }
          $copied += $ref
        }
        else {
          $missing += $ref
        }
      }
    }

    $typePath = [uri]::EscapeDataString("`$$childType")
    $uri = "$org/$project/_apis/wit/workitems/$typePath`?api-version=7.1"
    $wi = Invoke-Ado -Method POST -Uri $uri `
      -Body ($patch | ConvertTo-Json -Depth 10 -AsArray) `
      -ContentType 'application/json-patch+json'
    [pscustomobject]@{
      id            = $wi.id
      url           = "$org/_workitems/edit/$($wi.id)"
      type          = $wi.fields.'System.WorkItemType'
      title         = $wi.fields.'System.Title'
      parentId      = $ParentId
      copiedFields  = $copied
      missingFields = $missing
    } | ConvertTo-Json
  }
}
