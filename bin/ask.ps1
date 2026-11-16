#Requires -Version 5.1
<#
.SYNOPSIS
  Ask one free model a single question, with automatic fallback across channels.

.DESCRIPTION
  The "second opinion" entry point used during a conversation: one prompt in,
  one answer out, printed to stdout with the winning channel and latency on
  stderr. Workers are tried in order; a channel that is missing a key, rate
  limited (HTTP 402/429) or times out is skipped and the next one is used.

  Default chain (all free): zhipu/glm-4-flash-250414 -> zhipu/glm-4-flash
  -> zhipu/glm-z1-flash -> pollinations/openai-fast.

  Thinking models put their reasoning inline before the answer; everything up
  to and including `</think>` is stripped.

  ASCII-only source (Windows PowerShell reads a BOM-less .ps1 as ANSI); the
  prompt arrives as an argument or from a UTF-8 file via -PromptFile.

.EXAMPLE
  ask.cmd -PromptFile question.txt
  ask.cmd -Prompt "Explain TCP slow start in one sentence" -MaxTokens 256
#>
[CmdletBinding()]
param(
  [string]$Prompt,
  [string]$PromptFile,
  [string]$System,
  [string[]]$Workers,
  [int]$MaxTokens = 1024,
  [double]$Temperature = 0.3,
  [int]$TimeoutSec = 90
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

if (-not $Workers -or $Workers.Count -eq 0) {
  $Workers = @(
    'zhipu/glm-4-flash-250414',
    'zhipu/glm-4-flash',
    'zhipu/glm-z1-flash',
    'pollinations/openai-fast'
  )
}
$Workers = @($Workers | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })

if (-not $Prompt -and $PromptFile) {
  if (-not (Test-Path $PromptFile)) { [Console]::Error.WriteLine('Prompt file not found: ' + $PromptFile); exit 3 }
  $Prompt = [System.IO.File]::ReadAllText((Resolve-Path $PromptFile), [System.Text.Encoding]::UTF8)
}
if ([string]::IsNullOrWhiteSpace($Prompt)) { [Console]::Error.WriteLine('Nothing to ask: pass -Prompt or -PromptFile.'); exit 3 }

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

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

$skipReason = @()
foreach ($spec in $Workers) {
  $parts = $spec.Split('/')
  if ($parts.Count -lt 2) { $skipReason += ($spec + ': bad worker spec'); continue }
  $prov = $parts[0]
  $mdl = ($parts[1..($parts.Count - 1)] -join '/')
  if (-not $endpoints.ContainsKey($prov)) { $skipReason += ($spec + ': unknown provider'); continue }
  $ep = $endpoints[$prov]
  $hdrs = @{}
  if ($ep.KeyEnv) {
    $key = Get-Cred $ep.KeyEnv
    if ([string]::IsNullOrWhiteSpace($key)) { $skipReason += ($spec + ': missing ' + $ep.KeyEnv); continue }
    $hdrs['Authorization'] = 'Bearer ' + $key
  } elseif ($prov -eq 'pollinations') {
    $hdrs['Authorization'] = 'Bearer pollinations'
  }

  $messages = @()
  if ($System) { $messages += @{ role = 'system'; content = $System } }
  $messages += @{ role = 'user'; content = $Prompt }
  $body = @{ model = $mdl; messages = $messages; max_tokens = $MaxTokens; temperature = $Temperature; stream = $false } | ConvertTo-Json -Depth 8 -Compress
  $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, ($ep.BaseUrl + '/chat/completions'))
  $req.Content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
  foreach ($h in $hdrs.Keys) { [void]$req.Headers.Add($h, $hdrs[$h]) }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
    $sw.Stop()
    if (-not $resp.IsSuccessStatusCode) {
      $skipReason += ($spec + ': HTTP ' + [int]$resp.StatusCode)
      continue
    }
    $parsed = $text | ConvertFrom-Json
    $content = $parsed.choices[0].message.content
    $finish = $parsed.choices[0].finish_reason
    if ([string]::IsNullOrWhiteSpace($content)) {
      $skipReason += ($spec + ': empty content (finish=' + $finish + '), raise -MaxTokens')
      continue
    }
    if ($content -match '</think>') {
      $clean = ($content -split '</think>')[-1].Trim()
      if ($clean.Length -gt 0) { $content = $clean }
    }
    $content
    # Meta goes to the host stream, not stderr: a .cmd wrapper turns stderr into
    # a NativeCommandError for the caller and poisons its exit code.
    Write-Host ('[' + $spec + '] ' + $sw.ElapsedMilliseconds + ' ms, finish=' + $finish + ', tokens out=' + $parsed.usage.completion_tokens)
    if ($skipReason.Count -gt 0) { Write-Host ('[skipped earlier] ' + ($skipReason -join ' | ')) }
    exit 0
  } catch {
    $sw.Stop()
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    $skipReason += ($spec + ': ' + $e.Message)
  }
}

[Console]::Error.WriteLine('All workers failed:')
foreach ($r in $skipReason) { [Console]::Error.WriteLine('  - ' + $r) }
exit 1
