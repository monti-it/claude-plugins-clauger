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

# Authenticated access to the Azure DevOps REST API of one org/project/repo.
class AdoClient {
  [string]$Org
  [string]$Project
  [string]$RepoName
  hidden [hashtable]$Headers

  AdoClient([string]$repoOverride) {
    $this.Org = if ($env:ADO_ORG_URL) { $env:ADO_ORG_URL.TrimEnd('/') } else { 'https://dev.azure.com/clauger3e' }
    $this.Project = if ($env:ADO_PROJECT) { $env:ADO_PROJECT } else { 'MyClauger-Evolution' }
    $this.Headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$([AdoClient]::ReadPat())")) }
    $this.RepoName = [AdoClient]::ResolveRepoName($repoOverride)
  }

  [object] Get([string]$uri) {
    return $this.Invoke('GET', $uri, $null)
  }

  [object] Post([string]$uri, [object]$body) {
    return $this.Invoke('POST', $uri, $body)
  }

  hidden [object] Invoke([string]$method, [string]$uri, [object]$body) {
    $params = @{
      Method      = $method
      Uri         = $uri
      Headers     = $this.Headers
      ContentType = 'application/json; charset=utf-8'
    }
    if ($null -ne $body) {
      # Sent as UTF-8 bytes so accented text survives.
      $params.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 20))
    }
    try {
      return Invoke-RestMethod @params
    }
    catch {
      $detail = ''
      $resp = $_.Exception.Response
      if ($resp) {
        try { $detail = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch { }
      }
      throw "ADO API $method $uri failed: $($_.Exception.Message)`n$detail"
    }
  }

  hidden static [string] ReadPat() {
    $patFile = if ($env:ADO_PAT_FILE) { $env:ADO_PAT_FILE } else { Join-Path $env:TEMP 'ado_pat.txt' }
    if (-not (Test-Path $patFile)) {
      throw "PAT file not found: $patFile`nEither connect an Azure DevOps MCP server (no PAT needed), or create the file with:`nSet-Content -Path `"$patFile`" -Value `"YOUR_PAT`" -NoNewline"
    }
    $pat = (Get-Content -Raw -Path $patFile).Trim()
    if (-not $pat) { throw "PAT file is empty: $patFile" }
    return $pat
  }

  hidden static [string] ResolveRepoName([string]$repoOverride) {
    if ($env:ADO_REPO) { return $env:ADO_REPO }
    if ($repoOverride) { return $repoOverride }
    $url = (& git remote get-url origin 2>$null)
    if ($LASTEXITCODE -eq 0 -and $url) {
      return ($url -replace '\.git$', '' -split '/')[-1]
    }
    throw 'Could not determine repository name; pass -Repo or set $env:ADO_REPO.'
  }
}

# The SonarCloud side of one pull request: readiness, threads, replies.
class SonarPr {
  static [string]$ReplyMarker = 'sonar-pr: issue'

  # A gate status this long after the build started is the real analysis; the
  # earlier one (~1-2 min after start) is SonarCloud's placeholder "passed".
  static [timespan]$RealGateDelay = [timespan]::FromMinutes(4)

  hidden [AdoClient]$Ado
  hidden [int]$PrId
  hidden [string]$PrBase

  SonarPr([AdoClient]$ado, [int]$prId) {
    $this.Ado = $ado
    $this.PrId = $prId
    $this.PrBase = "$($ado.Org)/$($ado.Project)/_apis/git/repositories/$($ado.RepoName)/pullRequests/$prId"
  }

  [Collections.Specialized.OrderedDictionary] GetStatus() {
    $pr = $this.Ado.Get("$($this.PrBase)?api-version=7.1")
    $iterations = $this.Ado.Get("$($this.PrBase)/iterations?api-version=7.1").value
    $lastIteration = if ($iterations) { [int]($iterations | Measure-Object -Property id -Maximum).Maximum } else { $null }

    $mergeCommit = if ($pr.PSObject.Properties['lastMergeCommit'] -and $pr.lastMergeCommit) { $pr.lastMergeCommit.commitId } else { $null }

    # The build validation policy evaluation carries the PR build state with the
    # PR's own permissions (the builds API would need a Build-scoped PAT).
    $artifactId = "vstfs:///CodeReview/CodeReviewId/$($pr.repository.project.id)/$($this.PrId)"
    $evaluations = $this.Ado.Get("$($this.Ado.Org)/$($this.Ado.Project)/_apis/policy/evaluations?artifactId=" +
      [uri]::EscapeDataString($artifactId) + '&api-version=7.1-preview.1').value
    $build = @($evaluations | Where-Object { $_.configuration.type.displayName -eq 'Build' }) | Select-Object -First 1
    $buildCtx = if ($build -and $build.PSObject.Properties['context'] -and $build.context) { $build.context } else { $null }
    $buildStarted = if ($buildCtx -and $buildCtx.PSObject.Properties['buildStartedUtc']) { [SonarPr]::ToUtc($buildCtx.buildStartedUtc) } else { $null }
    $buildCurrent = [bool]($buildCtx -and $mergeCommit -and $buildCtx.lastMergeCommitId -eq $mergeCommit -and -not $buildCtx.buildIsNotCurrent)

    $statuses = $this.Ado.Get("$($this.PrBase)/statuses?api-version=7.1").value
    $gates = @($statuses | Where-Object {
        $_.context.genre -eq 'SonarCloud' -and $_.context.name -like '*quality gate*' -and
        $_.PSObject.Properties['iterationId'] -and $_.iterationId -eq $lastIteration
      } | Sort-Object { [SonarPr]::ToUtc($_.creationDate) } -Descending)
    $gate = if ($gates.Count) { $gates[0] } else { $null }
    $gateCreated = if ($gate) { [SonarPr]::ToUtc($gate.creationDate) } else { $null }

    $ready = $false
    $reason =
    if ($pr.status -ne 'active') { "PR is $($pr.status)" }
    elseif (-not $build) { 'no build validation policy evaluation on this PR' }
    elseif (-not $buildCurrent) { 'the build is not for the current merge commit yet' }
    elseif ($build.status -eq 'rejected') { 'build failed' }
    elseif ($build.status -ne 'approved') { "build is $($build.status)" }
    elseif (-not $gate) { "no SonarCloud quality gate status for iteration $lastIteration yet" }
    elseif ($buildStarted -and $gateCreated -lt $buildStarted + [SonarPr]::RealGateDelay) { 'only the early placeholder quality gate status so far' }
    else { $ready = $true; 'build completed and SonarCloud analysis posted' }

    return [ordered]@{
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

  [Collections.Specialized.OrderedDictionary] Wait([int]$timeoutMinutes, [int]$intervalSeconds) {
    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    while ($true) {
      $s = $this.GetStatus()
      if ($s.ready -or $s.pr.status -ne 'active' -or $s.reason -eq 'build failed' -or (Get-Date) -ge $deadline) {
        $s['timedOut'] = -not $s.ready -and $s.pr.status -eq 'active' -and $s.reason -ne 'build failed'
        return $s
      }
      Start-Sleep -Seconds $intervalSeconds
    }
    return $null # unreachable; PowerShell classes need a return on every path
  }

  [object[]] GetThreads() {
    $threads = $this.FetchThreads()
    $replied = [SonarPr]::RepliedKeys($threads)
    $byKey = [ordered]@{}
    foreach ($t in ($threads | Sort-Object { [datetime]$_.publishedDate })) {
      $first = [SonarPr]::LiveComments($t) | Select-Object -First 1
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
    return @($byKey.Values)
  }

  [Collections.Specialized.OrderedDictionary] Reply([int]$threadId, [string]$issueKey, [string]$content) {
    if (-not $threadId) { throw 'reply needs -ThreadId.' }
    if (-not $issueKey) { throw 'reply needs -IssueKey.' }
    if (-not $content) { throw 'reply needs -Content.' }
    $threads = $this.FetchThreads()
    if ([SonarPr]::RepliedKeys($threads).ContainsKey($issueKey)) {
      return [ordered]@{ posted = $false; reason = "a sonar-pr reply for $issueKey already exists" }
    }
    $thread = $threads | Where-Object { $_.id -eq $threadId } | Select-Object -First 1
    if (-not $thread) { throw "Thread $threadId not found on PR $($this.PrId)." }
    $root = [SonarPr]::LiveComments($thread) | Select-Object -First 1
    $body = @{
      parentCommentId = if ($root) { $root.id } else { 0 }
      content         = "$content`n`n_$([SonarPr]::ReplyMarker) ``$issueKey``_"
      commentType     = 1
    }
    $c = $this.Ado.Post("$($this.PrBase)/threads/$threadId/comments?api-version=7.1", $body)
    return [ordered]@{ posted = $true; threadId = $threadId; commentId = $c.id }
  }

  hidden [object[]] FetchThreads() {
    return @($this.Ado.Get("$($this.PrBase)/threads?api-version=7.1").value)
  }

  hidden static [object[]] LiveComments([object]$thread) {
    if (-not $thread.PSObject.Properties['comments']) { return @() }
    return @($thread.comments | Where-Object { -not ($_.PSObject.Properties['isDeleted'] -and $_.isDeleted) -and $_.content })
  }

  hidden static [hashtable] RepliedKeys([object[]]$threads) {
    $keys = @{}
    foreach ($t in $threads) {
      foreach ($c in [SonarPr]::LiveComments($t)) {
        foreach ($m in [regex]::Matches($c.content, [regex]::Escape([SonarPr]::ReplyMarker) + '\s+`?([^\s`]+)')) {
          $keys[$m.Groups[1].Value] = $true
        }
      }
    }
    return $keys
  }

  hidden static [object] ToUtc([object]$value) {
    if ($null -eq $value) { return $null }
    if ($value -is [datetime]) { return $value.ToUniversalTime() }
    return ([datetimeoffset]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
  }
}

try {
  $sonar = [SonarPr]::new([AdoClient]::new($Repo), $PrId)
  switch ($Command) {
    'status' { $sonar.GetStatus() | ConvertTo-Json -Depth 10 }
    'wait' { $sonar.Wait($TimeoutMinutes, $IntervalSeconds) | ConvertTo-Json -Depth 10 }
    'threads' { ConvertTo-Json -InputObject @($sonar.GetThreads()) -Depth 10 }
    'reply' { $sonar.Reply($ThreadId, $IssueKey, $Content) | ConvertTo-Json }
  }
}
catch {
  Write-Error $_.Exception.Message -ErrorAction Continue
  exit 1
}
