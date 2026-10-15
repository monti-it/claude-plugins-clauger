#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Azure DevOps REST helper for the sonar-pr skill: SonarCloud findings on a PR.
  Fallback path: prefer an Azure DevOps MCP server when one is connected.

.DESCRIPTION
  Subcommands:
    status   -PrId <n>
             one-shot readiness check. Reports the PR, its latest iteration,
             its build validation state and the latest "SonarCloud/quality
             gate" status for that iteration, plus { ready, reason }.
             ready = the build passed for the current merge commit AND a
             quality gate status for the latest iteration was posted at least
             4 min after the build started (SonarCloud first posts a
             placeholder "passed" ~1-2 min in, the real result 6-12 min in).
             reason "build failed" = the build was rejected; stop there.
    wait     -PrId <n> [-TimeoutMinutes 9] [-IntervalSeconds 60]
             polls `status` until ready, build failed, PR no longer active,
             or the timeout; same output plus
             { timedOut }. Default timeout stays under the 10 min tool limit -
             call it again to keep waiting.
    threads  -PrId <n>
             the SonarCloud threads of the PR, one per ISSUE_KEY (the newest
             thread wins - Sonar deletes and reposts threads on re-analysis),
             threads with no live comment skipped. Each item:
             { threadId, status, filePath, line, issueKey, rule, message,
               url, replied }. replied = a sonar-pr reply naming that
             ISSUE_KEY already exists on ANY thread of the PR.
    reply    -PrId <n> -ThreadId <n> -IssueKey <key> -Content <markdown>
             posts a reply in the thread, with a "sonar-pr: issue <key>"
             footer that `threads` uses to detect it. Refuses if a sonar-pr
             reply for that key already exists. Never changes thread status.

  Sonar threads are posted under a person's account, not a service account,
  so they are recognised by the [ISSUE_KEY]: / [PROJECT_KEY]: markers in the
  comment, never by author.

  Auth: reads a PAT from $env:ADO_PAT_FILE, else %TEMP%\ado_pat.txt.
  The PAT is never printed and never written anywhere.
  PAT scopes: Code (Read & Write) - same PAT as process-work-item.

  Config via environment (all optional):
    ADO_ORG_URL   default https://dev.azure.com/clauger3e
    ADO_PROJECT   default MyClauger-Evolution
    ADO_REPO      default: repo name parsed from `git remote get-url origin`
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)]
  [ValidateSet('status', 'wait', 'threads', 'reply')]
  [string]$Command,

  [Parameter(Mandatory)]
  [int]$PrId,
  [int]$ThreadId,
  [string]$IssueKey,
  [string]$Content,
  [string]$Repo,
  [int]$TimeoutMinutes = 9,
  [int]$IntervalSeconds = 60
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
$headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")) }

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

function Invoke-Ado {
  param(
    [string]$Method,
    [string]$Uri,
    [object]$Body
  )
  $params = @{
    Method      = $Method
    Uri         = $Uri
    Headers     = $headers
    ContentType = 'application/json; charset=utf-8'
  }
  if ($null -ne $Body) {
    # Sent as UTF-8 bytes so accented text survives.
    $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20))
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

$repoName = Get-RepoName
$prBase = "$org/$project/_apis/git/repositories/$repoName/pullRequests/$PrId"
$replyMarker = 'sonar-pr: issue'

# A gate status this long after the build started is the real analysis; the
# earlier one (~1-2 min after start) is SonarCloud's placeholder "passed".
$realGateDelay = [timespan]::FromMinutes(4)

function ConvertTo-Utc($value) {
  if ($null -eq $value) { return $null }
  if ($value -is [datetime]) { return $value.ToUniversalTime() }
  ([datetimeoffset]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
}

function Get-Status {
  $pr = Invoke-Ado -Method GET -Uri "$prBase`?api-version=7.1"
  $iterations = (Invoke-Ado -Method GET -Uri "$prBase/iterations?api-version=7.1").value
  $lastIteration = if ($iterations) { [int]($iterations | Measure-Object -Property id -Maximum).Maximum } else { $null }

  $mergeCommit = if ($pr.PSObject.Properties['lastMergeCommit'] -and $pr.lastMergeCommit) { $pr.lastMergeCommit.commitId } else { $null }

  # The build validation policy evaluation carries the PR build state with the
  # PR's own permissions (the builds API would need a Build-scoped PAT).
  $artifactId = "vstfs:///CodeReview/CodeReviewId/$($pr.repository.project.id)/$PrId"
  $evaluations = (Invoke-Ado -Method GET -Uri ("$org/$project/_apis/policy/evaluations?artifactId=" +
      [uri]::EscapeDataString($artifactId) + '&api-version=7.1-preview.1')).value
  $build = @($evaluations | Where-Object { $_.configuration.type.displayName -eq 'Build' }) | Select-Object -First 1
  $buildCtx = if ($build -and $build.PSObject.Properties['context'] -and $build.context) { $build.context } else { $null }
  $buildStarted = if ($buildCtx -and $buildCtx.PSObject.Properties['buildStartedUtc']) { ConvertTo-Utc $buildCtx.buildStartedUtc } else { $null }
  $buildCurrent = [bool]($buildCtx -and $mergeCommit -and $buildCtx.lastMergeCommitId -eq $mergeCommit -and -not $buildCtx.buildIsNotCurrent)

  $statuses = (Invoke-Ado -Method GET -Uri "$prBase/statuses?api-version=7.1").value
  $gates = @($statuses | Where-Object {
      $_.context.genre -eq 'SonarCloud' -and $_.context.name -like '*quality gate*' -and
      $_.PSObject.Properties['iterationId'] -and $_.iterationId -eq $lastIteration
    } | Sort-Object { ConvertTo-Utc $_.creationDate } -Descending)
  $gate = if ($gates.Count) { $gates[0] } else { $null }
  $gateCreated = if ($gate) { ConvertTo-Utc $gate.creationDate } else { $null }

  $ready = $false
  $reason =
  if ($pr.status -ne 'active') { "PR is $($pr.status)" }
  elseif (-not $build) { 'no build validation policy evaluation on this PR' }
  elseif (-not $buildCurrent) { 'the build is not for the current merge commit yet' }
  elseif ($build.status -eq 'rejected') { 'build failed' }
  elseif ($build.status -ne 'approved') { "build is $($build.status)" }
  elseif (-not $gate) { "no SonarCloud quality gate status for iteration $lastIteration yet" }
  elseif ($buildStarted -and $gateCreated -lt $buildStarted + $realGateDelay) { 'only the early placeholder quality gate status so far' }
  else { $ready = $true; 'build completed and SonarCloud analysis posted' }

  [ordered]@{
    ready       = $ready
    reason      = $reason
    pr          = [ordered]@{
      id           = $pr.pullRequestId
      status       = $pr.status
      sourceBranch = $pr.sourceRefName -replace '^refs/heads/', ''
      targetBranch = $pr.targetRefName -replace '^refs/heads/', ''
      mergeCommit  = $mergeCommit
      iteration    = $lastIteration
    }
    build       = if ($build) {
      [ordered]@{
        id         = if ($buildCtx -and $buildCtx.PSObject.Properties['buildId']) { $buildCtx.buildId } else { $null }
        status     = $build.status
        startedUtc = $buildStarted
        current    = $buildCurrent
      }
    } else { $null }
    qualityGate = if ($gate) {
      [ordered]@{
        state       = $gate.state
        description = if ($gate.PSObject.Properties['description']) { $gate.description } else { $null }
        iterationId = $gate.iterationId
        createdUtc  = $gateCreated
        url         = if ($gate.PSObject.Properties['targetUrl']) { $gate.targetUrl } else { $null }
      }
    } else { $null }
  }
}

function Get-LiveComments($thread) {
  if (-not $thread.PSObject.Properties['comments']) { return @() }
  @($thread.comments | Where-Object { -not ($_.PSObject.Properties['isDeleted'] -and $_.isDeleted) -and $_.content })
}

function Get-RepliedKeys($threads) {
  $keys = @{}
  foreach ($t in $threads) {
    foreach ($c in (Get-LiveComments $t)) {
      foreach ($m in [regex]::Matches($c.content, [regex]::Escape($replyMarker) + '\s+`?([^\s`]+)')) {
        $keys[$m.Groups[1].Value] = $true
      }
    }
  }
  $keys
}

function Get-SonarThreads {
  $threads = @((Invoke-Ado -Method GET -Uri "$prBase/threads?api-version=7.1").value)
  $replied = Get-RepliedKeys $threads
  $byKey = [ordered]@{}
  foreach ($t in ($threads | Sort-Object { [datetime]$_.publishedDate })) {
    $first = (Get-LiveComments $t) | Select-Object -First 1
    if (-not $first) { continue }
    $text = $first.content
    $key = [regex]::Match($text, '\[ISSUE_KEY\]:\s*(\S+)')
    if (-not $key.Success -or $text -notmatch '\[PROJECT_KEY\]:') { continue }
    $url = [regex]::Match($text, '\[See it in SonarQube Cloud\]\((https://sonarcloud\.io/\S+?)\)')
    # The markers alone are easy to imitate in a human comment; require the
    # SonarCloud issue link too.
    if (-not $url.Success) { continue }
    $rule = [regex]::Match($text, '\(\[([\w.-]+:[\w.-]+)\]')
    $ctx = if ($t.PSObject.Properties['threadContext'] -and $t.threadContext) { $t.threadContext } else { $null }
    $byKey[$key.Groups[1].Value] = [ordered]@{
      threadId = $t.id
      status   = $t.status
      filePath = if ($ctx) { $ctx.filePath } else { $null }
      line     = if ($ctx -and $ctx.PSObject.Properties['rightFileStart'] -and $ctx.rightFileStart) { $ctx.rightFileStart.line } else { $null }
      issueKey = $key.Groups[1].Value
      rule     = if ($rule.Success) { $rule.Groups[1].Value } else { $null }
      message  = (($text -split '\(\[', 2)[0]).Trim()
      url      = $url.Groups[1].Value
      replied  = $replied.ContainsKey($key.Groups[1].Value)
    }
  }
  @($byKey.Values)
}

switch ($Command) {

  'status' {
    Get-Status | ConvertTo-Json -Depth 10
  }

  'wait' {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
      $s = Get-Status
      if ($s.ready -or $s.pr.status -ne 'active' -or $s.reason -eq 'build failed' -or (Get-Date) -ge $deadline) { break }
      Start-Sleep -Seconds $IntervalSeconds
    }
    $s['timedOut'] = -not $s.ready -and $s.pr.status -eq 'active' -and $s.reason -ne 'build failed'
    $s | ConvertTo-Json -Depth 10
  }

  'threads' {
    ConvertTo-Json -InputObject @(Get-SonarThreads) -Depth 10
  }

  'reply' {
    if (-not $ThreadId) { Fail 'reply needs -ThreadId.' }
    if (-not $IssueKey) { Fail 'reply needs -IssueKey.' }
    if (-not $Content) { Fail 'reply needs -Content.' }
    $threads = @((Invoke-Ado -Method GET -Uri "$prBase/threads?api-version=7.1").value)
    if ((Get-RepliedKeys $threads).ContainsKey($IssueKey)) {
      [ordered]@{ posted = $false; reason = "a sonar-pr reply for $IssueKey already exists" } | ConvertTo-Json
      break
    }
    $thread = $threads | Where-Object { $_.id -eq $ThreadId } | Select-Object -First 1
    if (-not $thread) { Fail "Thread $ThreadId not found on PR $PrId." }
    $root = (Get-LiveComments $thread) | Select-Object -First 1
    $body = @{
      parentCommentId = if ($root) { $root.id } else { 0 }
      content         = "$Content`n`n_$replyMarker ``$IssueKey``_"
      commentType     = 1
    }
    $c = Invoke-Ado -Method POST -Uri "$prBase/threads/$ThreadId/comments?api-version=7.1" -Body $body
    [ordered]@{ posted = $true; threadId = $ThreadId; commentId = $c.id } | ConvertTo-Json
  }
}
