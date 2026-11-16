#Requires -Version 5.1
<#
.SYNOPSIS
  One command that answers "which model channels work right now?".

.DESCRIPTION
  Probes every declared route with a one-line JSON task and prints a table:
  OK / HTTP status / NOKEY / EMPTY. Credentials are read from the environment
  first, then from ~/.dsh/.credentials.yaml, so it works from any directory and
  any session. ASCII-only source (Windows PowerShell reads BOM-less .ps1 as
  ANSI); the probe prompt is built from ASCII text only.

  Pollinations allows one reply per 45 seconds per IP, so a 402 there means
  "rate limited", not "broken".

.EXAMPLE
  smoke.cmd
  smoke.cmd -Quick     # skip the slow channels
#>
[CmdletBinding()]
param(
  [switch]$Quick,
  [int]$TimeoutSec = 60
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$channels = @(
  @{ Provider = 'zhipu'; Model = 'glm-4-flash-250414'; Url = 'https://open.bigmodel.cn/api/paas/v4'; KeyEnv = 'ZHIPU_API_KEY'; Tag = 'free' },
  @{ Provider = 'zhipu'; Model = 'glm-4-flash'; Url = 'https://open.bigmodel.cn/api/paas/v4'; KeyEnv = 'ZHIPU_API_KEY'; Tag = 'free' },
  @{ Provider = 'zhipu'; Model = 'glm-4v-flash'; Url = 'https://open.bigmodel.cn/api/paas/v4'; KeyEnv = 'ZHIPU_API_KEY'; Tag = 'free' },
  @{ Provider = 'pollinations'; Model = 'openai-fast'; Url = 'https://text.pollinations.ai/openai'; KeyEnv = $null; Tag = 'keyless/45s' },
  @{ Provider = 'ollama'; Model = 'qwen2.5vl:7b'; Url = 'http://127.0.0.1:11434/v1'; KeyEnv = $null; Tag = 'local' },
  @{ Provider = 'modelscope'; Model = 'deepseek-ai/DeepSeek-V4.1-Flash'; Url = 'https://api-inference.modelscope.cn/v1'; KeyEnv = 'MODELSCOPE_API_KEY'; Tag = 'needs key' },
  @{ Provider = 'openrouter'; Model = 'baidu/ernie-5.5-flash-preview:free'; Url = 'https://openrouter.ai/api/v1'; KeyEnv = 'OPENROUTER_API_KEY'; Tag = 'needs key' },
  @{ Provider = 'deepseek'; Model = 'deepseek-v4-flash'; Url = 'https://api.deepseek.com'; KeyEnv = 'DEEPSEEK_API_KEY'; Tag = 'paid' },
  @{ Provider = 'tokenhub'; Model = 'hy3'; Url = 'https://tokenhub.tencentmaas.com/v1'; KeyEnv = 'TOKENHUB_API_KEY'; Tag = 'paid' },
  @{ Provider = 'doubao'; Model = 'doubao-seed-2-1-pro-260915'; Url = 'https://ark.cn-beijing.volces.com/api/v3'; KeyEnv = 'ARK_API_KEY'; Tag = 'paid' }
)

if ($Quick) {
  $channels = @($channels | Where-Object { $_.Tag -in @('free', 'keyless/45s') })
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

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

$payload = @{
  model       = 'probe'
  messages    = @(@{ role = 'user'; content = 'Reply with only this JSON and nothing else: {"ok":true}' })
  max_tokens  = 64
  temperature = 0
  stream      = $false
} | ConvertTo-Json -Depth 8 -Compress

$rows = @()
foreach ($ch in $channels) {
  $label = ($ch.Provider + '/' + $ch.Model)
  $headers = @{}
  if ($ch.KeyEnv) {
    $key = Get-Cred $ch.KeyEnv
    if ([string]::IsNullOrWhiteSpace($key)) {
      $rows += [pscustomobject]@{ Channel = $label; Tag = $ch.Tag; Status = 'NOKEY'; Ms = 0; Sample = ('missing ' + $ch.KeyEnv) }
      continue
    }
    $headers['Authorization'] = 'Bearer ' + $key
  } elseif ($ch.Provider -eq 'pollinations') {
    $headers['Authorization'] = 'Bearer pollinations'
  }

  $body = $payload -replace '"model":"probe"', ('"model":' + (ConvertTo-Json $ch.Model))
  $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, ($ch.Url + '/chat/completions'))
  $req.Content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
  foreach ($h in $headers.Keys) { [void]$req.Headers.Add($h, $headers[$h]) }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
    $sw.Stop()
    if (-not $resp.IsSuccessStatusCode) {
      $code = [int]$resp.StatusCode
      $note = 'HTTP ' + $code
      if ($code -eq 402) { $note = 'HTTP 402 rate-limited' }
      if ($code -eq 429) { $note = 'HTTP 429 busy' }
      $short = $text; if ($short.Length -gt 90) { $short = $short.Substring(0, 90) }
      $rows += [pscustomobject]@{ Channel = $label; Tag = $ch.Tag; Status = $note; Ms = $sw.ElapsedMilliseconds; Sample = ($short -replace '\s+', ' ') }
      continue
    }
    $parsed = $text | ConvertFrom-Json
    $content = $parsed.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) {
      $rows += [pscustomobject]@{ Channel = $label; Tag = $ch.Tag; Status = 'EMPTY/' + $parsed.choices[0].finish_reason; Ms = $sw.ElapsedMilliseconds; Sample = 'raise max_tokens or use non-thinking model' }
      continue
    }
    $sample = ($content -replace '\s+', ' ').Trim(); if ($sample.Length -gt 70) { $sample = $sample.Substring(0, 70) }
    $verdict = 'OK'
    if ($content -notmatch '"ok"\s*:\s*true') { $verdict = 'OK (off-format)' }
    $rows += [pscustomobject]@{ Channel = $label; Tag = $ch.Tag; Status = $verdict; Ms = $sw.ElapsedMilliseconds; Sample = $sample }
  } catch {
    $sw.Stop()
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    $rows += [pscustomobject]@{ Channel = $label; Tag = $ch.Tag; Status = 'FAIL'; Ms = $sw.ElapsedMilliseconds; Sample = $e.Message }
  }
  if ($ch.Provider -eq 'pollinations') { Start-Sleep -Seconds 3 }
}

$rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$ok = @($rows | Where-Object { $_.Status -like 'OK*' }).Count
Write-Host ('[' + $ok + '/' + $rows.Count + '] channels answered')
if ($ok -eq 0) { exit 1 }
exit 0
