#Requires -Version 5.1
<#
.SYNOPSIS
  Fan independent TEXT tasks out to one or more free-model workers in parallel.

.DESCRIPTION
  Cheap "subagent" for branchable text work: every task is sent to a configured
  OpenAI-compatible endpoint and each answer is written to its own file. Workers
  cannot call tools, so they are meant for copying, extracting, listing,
  rewriting, and reformatting; the caller owns judgement, file edits and
  verification.

  With -Workers the tasks are dealt round-robin across channels. Channels that
  allow parallel requests (zhipu) run in a concurrent batch; a rate-limited
  channel (pollinations, one reply per IP per 45 s) is queued and executed one
  task at a time with a wait between calls.

  Measured 2026-11-14: glm-4-flash-250414 0.5-0.9 s per small task,
  glm-z1-flash 6-14 s (thinking; needs max_tokens >= 2048 and its `<think>`
  prefix is stripped into a sibling .raw.md), pollinations/openai-fast 15-18 s.

  Source is ASCII-only on purpose (Windows PowerShell reads a BOM-less .ps1 as
  ANSI); Chinese task text lives in UTF-8 files read with an explicit decoder.

.EXAMPLE
  fanout.ps1 -TasksFile tasks.txt -Workers zhipu/glm-4-flash-250414,zhipu/glm-z1-flash,pollinations/openai-fast
  fanout.ps1 -TasksFile one.txt -PromptFile one.txt -Workers zhipu/glm-4-flash-250414
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$TasksFile,
  [string]$PromptFile,
  [string]$TaskSeparator,
  [string[]]$Workers,
  [string]$Provider = 'zhipu',
  [string]$Model = 'glm-4-flash-250414',
  [string]$OutDir = 'fanout-out',
  [int]$MaxParallel = 4,
  [int]$MaxTokens = 2048,
  [double]$Temperature = 0.3,
  [string]$SystemPromptFile,
  [int]$TimeoutSec = 180,
  [int]$RateLimitGapSec = 46
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$endpoints = @{
  zhipu        = @{ BaseUrl = 'https://open.bigmodel.cn/api/paas/v4'; KeyEnv = 'ZHIPU_API_KEY' }
  pollinations = @{ BaseUrl = 'https://text.pollinations.ai/openai'; KeyEnv = $null }
  modelscope   = @{ BaseUrl = 'https://api-inference.modelscope.cn/v1'; KeyEnv = 'MODELSCOPE_API_KEY' }
  openrouter   = @{ BaseUrl = 'https://openrouter.ai/api/v1'; KeyEnv = 'OPENROUTER_API_KEY' }
  groq         = @{ BaseUrl = 'https://api.groq.com/openai/v1'; KeyEnv = 'GROQ_API_KEY' }
  gemini       = @{ BaseUrl = 'https://generativelanguage.googleapis.com/v1beta/openai'; KeyEnv = 'GEMINI_API_KEY' }
  siliconflow  = @{ BaseUrl = 'https://api.siliconflow.cn/v1'; KeyEnv = 'SILICONFLOW_API_KEY' }
  deepseek     = @{ BaseUrl = 'https://api.deepseek.com'; KeyEnv = 'DEEPSEEK_API_KEY' }
  doubao       = @{ BaseUrl = 'https://ark.cn-beijing.volces.com/api/v3'; KeyEnv = 'ARK_API_KEY' }
  tokenhub     = @{ BaseUrl = 'https://tokenhub.tencentmaas.com/v1'; KeyEnv = 'TOKENHUB_API_KEY' }
  ollama       = @{ BaseUrl = 'http://127.0.0.1:11434/v1'; KeyEnv = $null }
}

$credFile = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
function Get-Cred([string]$name) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  if (-not (Test-Path $credFile)) { return $null }
  foreach ($line in Get-Content $credFile) {
    if ($line -match ('^\s*' + [regex]::Escape($name) + '\s*:\s*(.+?)\s*$')) {
      $c = $Matches[1].Trim().Trim('"').Trim("'"); if ($c) { return $c }
    }
  }
  return $null
}

# ---- resolve channels ---------------------------------------------------
if (-not $Workers -or $Workers.Count -eq 0) { $Workers = @($Provider + '/' + $Model) }
# The .cmd wrapper hands a quoted "a,b,c" over as ONE argv element, so split on
# commas here as well; a native PowerShell call with -Workers a,b,c arrives as
# three elements and passes through unchanged.
$Workers = @($Workers | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
if ($Workers.Count -eq 0) { [Console]::Error.WriteLine('No worker given.'); exit 3 }
$channels = @()
foreach ($spec in $Workers) {
  $parts = $spec.Split('/')
  if ($parts.Count -lt 2) { [Console]::Error.WriteLine('Bad -Workers entry (need provider/model): ' + $spec); exit 3 }
  $prov = $parts[0]
  $mdl = ($parts[1..($parts.Count - 1)] -join '/')
  if (-not $endpoints.ContainsKey($prov)) {
    [Console]::Error.WriteLine('Unknown provider in -Workers: ' + $prov + '. Known: ' + ($endpoints.Keys -join ', '))
    exit 3
  }
  $ep = $endpoints[$prov]
  $hdrs = @{}
  if ($ep.KeyEnv) {
    $key = Get-Cred $ep.KeyEnv
    if ([string]::IsNullOrWhiteSpace($key)) {
      [Console]::Error.WriteLine('Missing credential: ' + $ep.KeyEnv + ' for worker ' + $spec + '.')
      exit 3
    }
    $hdrs['Authorization'] = 'Bearer ' + $key
  } elseif ($prov -eq 'pollinations') {
    $hdrs['Authorization'] = 'Bearer pollinations'
  }
  $channels += [pscustomobject]@{
    Spec        = $spec
    Provider    = $prov
    Model       = $mdl
    Url         = $ep.BaseUrl
    Headers     = $hdrs
    RateLimited = ($prov -eq 'pollinations')
  }
}

$systemPrompt = ''
if ($SystemPromptFile) {
  if (-not (Test-Path $SystemPromptFile)) { [Console]::Error.WriteLine('System prompt file not found: ' + $SystemPromptFile); exit 3 }
  $systemPrompt = [System.IO.File]::ReadAllText((Resolve-Path $SystemPromptFile), [System.Text.Encoding]::UTF8)
}

# ---- read tasks ---------------------------------------------------------
if (-not (Test-Path $TasksFile)) { [Console]::Error.WriteLine('Tasks file not found: ' + $TasksFile); exit 3 }
$tasks = @()
if ($PromptFile) {
  if (-not (Test-Path $PromptFile)) { [Console]::Error.WriteLine('Prompt file not found: ' + $PromptFile); exit 3 }
  $one = [System.IO.File]::ReadAllText((Resolve-Path $PromptFile), [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($one)) { [Console]::Error.WriteLine('Empty prompt file: ' + $PromptFile); exit 3 }
  $tasks += $one
} elseif ($TaskSeparator) {
  $whole = [System.IO.File]::ReadAllText((Resolve-Path $TasksFile), [System.Text.Encoding]::UTF8)
  foreach ($chunk in ($whole -split [regex]::Escape($TaskSeparator))) {
    $t = $chunk.Trim()
    if ($t.Length -gt 0 -and -not $t.StartsWith('#')) { $tasks += $t }
  }
} else {
  foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path $TasksFile), [System.Text.Encoding]::UTF8)) {
    $t = $line.Trim()
    if ($t.Length -eq 0) { continue }
    if ($t.StartsWith('#')) { continue }
    $tasks += $t
  }
}
if ($tasks.Count -eq 0) { [Console]::Error.WriteLine('No task lines in ' + $TasksFile); exit 3 }

if ($MaxParallel -lt 1) { $MaxParallel = 1 }
if ($MaxParallel -gt 8) { $MaxParallel = 8 }

# ---- plan ---------------------------------------------------------------
$plan = @()
for ($i = 0; $i -lt $tasks.Count; $i++) {
  $plan += [pscustomobject]@{ Index = $i; Text = $tasks[$i]; Channel = $channels[$i % $channels.Count] }
}
$fast = @($plan | Where-Object { -not $_.Channel.RateLimited })
$slow = @($plan | Where-Object { $_.Channel.RateLimited })

[System.Net.ServicePointManager]::DefaultConnectionLimit = 32
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path $OutDir).Path

# ---- one request per task, shared by both phases ------------------------
function New-TaskRequest($item) {
  $ch = $item.Channel
  $messages = @()
  if ($systemPrompt) { $messages += @{ role = 'system'; content = $systemPrompt } }
  $messages += @{ role = 'user'; content = $item.Text }
  $body = @{
    model       = $ch.Model
    messages    = $messages
    max_tokens  = $MaxTokens
    temperature = $Temperature
    stream      = $false
  } | ConvertTo-Json -Depth 8 -Compress
  $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, ($ch.Url + '/chat/completions'))
  $req.Content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
  foreach ($h in $ch.Headers.Keys) { [void]$req.Headers.Add($h, $ch.Headers[$h]) }
  return $req
}

function Save-TaskResult($item, $task, $watch) {
  $ch = $item.Channel
  $path = Join-Path $OutDir ('task-{0:D2}.md' -f ($item.Index + 1))
  $res = [pscustomobject]@{ Index = $item.Index + 1; Worker = $ch.Spec; Status = ''; Ms = 0; Chars = 0; Detail = '' }
  try {
    $resp = $task.GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
    $watch.Stop()
    $res.Ms = $watch.ElapsedMilliseconds
    if (-not $resp.IsSuccessStatusCode) {
      $res.Status = 'HTTP ' + [int]$resp.StatusCode
      $body = $text; if ($body.Length -gt 300) { $body = $body.Substring(0, 300) }
      $res.Detail = ($body -replace '\s+', ' ')
      Set-Content -LiteralPath $path -Value ('<!-- HTTP ' + [int]$resp.StatusCode + ' -->' + "`n" + $text) -Encoding UTF8
      return $res
    }
    $parsed = $text | ConvertFrom-Json
    $content = $parsed.choices[0].message.content
    $finish = $parsed.choices[0].finish_reason
    if ([string]::IsNullOrWhiteSpace($content)) {
      $res.Status = 'EMPTY/' + $finish
      $res.Detail = 'raise -MaxTokens or use a non-thinking model'
      Set-Content -LiteralPath $path -Value ('<!-- empty content, finish=' + $finish + ' -->') -Encoding UTF8
      return $res
    }
    if ($content -match '</think>') {
      $clean = ($content -split '</think>')[-1].Trim()
      if ($clean.Length -gt 0) {
        Set-Content -LiteralPath ($path -replace '\.md$', '.raw.md') -Value $content -Encoding UTF8
        $content = $clean
      }
    }
    $thinkOnly = $false
    if ($content -match '<think>') { $thinkOnly = $true }
    Set-Content -LiteralPath $path -Value $content -Encoding UTF8
    if ($thinkOnly) {
      $res.Status = 'THINKONLY/' + $finish
      $res.Detail = 'reasoning ate the budget; raise -MaxTokens for thinking models'
      $res.Chars = $content.Length
      return $res
    }
    $res.Status = 'OK/' + $finish
    $res.Chars = $content.Length
    $firstLine = ($content -split "`n")[0]
    if ($firstLine.Length -gt 55) { $firstLine = $firstLine.Substring(0, 55) }
    $res.Detail = $firstLine.Trim()
    return $res
  } catch {
    $watch.Stop()
    $res.Ms = $watch.ElapsedMilliseconds
    $res.Status = 'FAIL'
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    $res.Detail = $e.Message
    return $res
  }
}

$results = New-Object System.Collections.ArrayList
$total = $tasks.Count
$done = 0

# Phase 1: concurrent batch over channels that allow parallel requests.
for ($i = 0; $i -lt $fast.Count; $i += $MaxParallel) {
  $batch = @($fast[$i..([Math]::Min($i + $MaxParallel - 1, $fast.Count - 1))])
  $inflight = @()
  foreach ($item in $batch) {
    $inflight += [pscustomobject]@{ Item = $item; Watch = [System.Diagnostics.Stopwatch]::StartNew(); Task = $client.SendAsync((New-TaskRequest $item)) }
  }
  foreach ($job in $inflight) {
    $res = Save-TaskResult $job.Item $job.Task $job.Watch
    [void]$results.Add($res)
    $done++
    [Console]::Error.WriteLine('[' + $done + '/' + $total + '] task-' + ('{0:D2}' -f $res.Index) + ' via ' + $res.Worker + ' ' + $res.Status)
  }
}

# Phase 2: rate-limited channels, one at a time with a gap between calls.
for ($i = 0; $i -lt $slow.Count; $i++) {
  $item = $slow[$i]
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $task = $client.SendAsync((New-TaskRequest $item))
  $res = Save-TaskResult $item $task $watch
  [void]$results.Add($res)
  $done++
  [Console]::Error.WriteLine('[' + $done + '/' + $total + '] task-' + ('{0:D2}' -f $res.Index) + ' via ' + $res.Worker + ' ' + $res.Status)
  if ($i -lt $slow.Count - 1) { Start-Sleep -Seconds $RateLimitGapSec }
}

$results | Sort-Object Index | Format-Table Index, Worker, Status, Ms, Chars, Detail -AutoSize | Out-String -Width 200 | Write-Host
[Console]::Error.WriteLine('[' + $total + ' tasks, workers=' + (@($channels.Spec) -join ' + ') + ', fast=' + $fast.Count + ', slow=' + $slow.Count + ', out=' + $OutDir + ']')
exit 0
