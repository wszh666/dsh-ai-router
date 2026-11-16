#Requires -Version 5.1
<#
.SYNOPSIS
  Call a configured LLM endpoint directly, bypassing the DSH model routes.

.DESCRIPTION
  Endpoints mirror ai-router/cordis.patch.yml. Credentials are read from the
  process environment first, then from ~/.dsh/.credentials.yaml (the same file
  the free-media scripts read), so a key stored by the harness is enough.

  Free routes that need no signup at all:
    -Provider pollinations -Model openai-fast     (1 reply per 45 s per IP)
    -Provider ollama       -Model qwen2.5vl:7b    (local, offline)

  Free routes that use keys already present in this profile:
    -Provider zhipu -Model glm-4-flash            (ZHIPU_API_KEY)

  hunyuan is kept for completeness only: as of 2026-11-14 that endpoint rejects
  the configured key with HTTP 401, so use tokenhub/hy3 for Tencent Hunyuan.

  Two deliberate choices:
  - ASCII-only source: Windows PowerShell reads a BOM-less .ps1 as ANSI.
  - System.Net.Http instead of Invoke-RestMethod: Windows PowerShell decodes a
    JSON body without a charset parameter as Latin-1, which corrupts every
    non-ASCII reply. Reading raw bytes and decoding UTF-8 keeps Chinese intact.

.EXAMPLE
  .\llm.ps1 -Provider zhipu -Model glm-4-flash -Prompt "1+1=?" -MaxTokens 128

.EXAMPLE
  .\llm.ps1 -Provider zhipu -ListModels
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet(
    'ollama', 'zhipu', 'pollinations', 'modelscope', 'openrouter', 'groq',
    'gemini', 'siliconflow', 'deepseek', 'doubao', 'hunyuan', 'tokenhub')][string]$Provider,
  [string]$Model,
  [string]$Prompt,
  [string]$System,
  [int]$MaxTokens = 1024,
  [double]$Temperature = 0,
  [int]$TimeoutSec = 180,
  [switch]$ListModels,
  [switch]$Raw
)

$ErrorActionPreference = 'Stop'

$endpoints = @{
  ollama       = @{ BaseUrl = 'http://127.0.0.1:11434/v1'; KeyEnv = $null }
  zhipu        = @{ BaseUrl = 'https://open.bigmodel.cn/api/paas/v4'; KeyEnv = 'ZHIPU_API_KEY' }
  pollinations = @{ BaseUrl = 'https://text.pollinations.ai/openai'; KeyEnv = $null }
  modelscope   = @{ BaseUrl = 'https://api-inference.modelscope.cn/v1'; KeyEnv = 'MODELSCOPE_API_KEY' }
  openrouter   = @{ BaseUrl = 'https://openrouter.ai/api/v1'; KeyEnv = 'OPENROUTER_API_KEY' }
  groq         = @{ BaseUrl = 'https://api.groq.com/openai/v1'; KeyEnv = 'GROQ_API_KEY' }
  gemini       = @{ BaseUrl = 'https://generativelanguage.googleapis.com/v1beta/openai'; KeyEnv = 'GEMINI_API_KEY' }
  siliconflow  = @{ BaseUrl = 'https://api.siliconflow.cn/v1'; KeyEnv = 'SILICONFLOW_API_KEY' }
  doubao       = @{ BaseUrl = 'https://ark.cn-beijing.volces.com/api/v3'; KeyEnv = 'ARK_API_KEY' }
  deepseek     = @{ BaseUrl = 'https://api.deepseek.com'; KeyEnv = 'DEEPSEEK_API_KEY' }
  hunyuan      = @{ BaseUrl = 'https://api.hunyuan.cloud.tencent.com/v1'; KeyEnv = 'HUNYUAN_API_KEY' }
  tokenhub     = @{ BaseUrl = 'https://tokenhub.tencentmaas.com/v1'; KeyEnv = 'TOKENHUB_API_KEY' }
}

$endpoint = $endpoints[$Provider]
$credFile = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'

function Get-CredentialValue([string]$name) {
  $value = [Environment]::GetEnvironmentVariable($name)
  if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
  if (-not (Test-Path $credFile)) { return $null }
  foreach ($line in Get-Content $credFile) {
    if ($line -match ('^\s*' + [regex]::Escape($name) + '\s*:\s*(.+?)\s*$')) {
      $candidate = $Matches[1].Trim().Trim('"').Trim("'")
      if ($candidate) { return $candidate }
    }
  }
  return $null
}

$headers = @{}
if ($endpoint.KeyEnv) {
  $key = Get-CredentialValue $endpoint.KeyEnv
  if ([string]::IsNullOrWhiteSpace($key)) {
    [Console]::Error.WriteLine('Missing credential: ' + $endpoint.KeyEnv + ' is neither in the environment nor in ' + $credFile + '.')
    exit 3
  }
  $headers['Authorization'] = 'Bearer ' + $key
} elseif ($Provider -eq 'pollinations') {
  $headers['Authorization'] = 'Bearer pollinations'
}

Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

function Get-Reason($ex) {
  $e = $ex
  while ($e.InnerException) { $e = $e.InnerException }
  return $e.Message
}

function Send-Request([System.Net.Http.HttpRequestMessage]$request) {
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
  } catch {
    return @{ Error = (Get-Reason $_.Exception) }
  }
  return @{
    Status = [int]$response.StatusCode
    Ok     = $response.IsSuccessStatusCode
    Text   = [System.Text.Encoding]::UTF8.GetString($bytes)
  }
}

function New-AuthRequest([System.Net.Http.HttpMethod]$method, [string]$url) {
  $request = New-Object System.Net.Http.HttpRequestMessage($method, $url)
  foreach ($name in $headers.Keys) { [void]$request.Headers.Add($name, $headers[$name]) }
  return $request
}

if ($ListModels) {
  $request = New-AuthRequest 'Get' ($endpoint.BaseUrl + '/models')
  $result = Send-Request $request
  if ($result.Error) {
    [Console]::Error.WriteLine('[' + $Provider + '] list models failed: ' + $result.Error)
    exit 1
  }
  if (-not $result.Ok) {
    [Console]::Error.WriteLine('[' + $Provider + '] HTTP ' + $result.Status)
    [Console]::Error.WriteLine($result.Text)
    exit 1
  }
  if ($Raw) { $result.Text; exit 0 }
  $parsed = $result.Text | ConvertFrom-Json
  $ids = @()
  if ($parsed.data) { $ids = @($parsed.data | ForEach-Object { $_.id }) }
  elseif ($parsed.models) { $ids = @($parsed.models | ForEach-Object { $_.name }) }
  $ids | Sort-Object -Unique
  [Console]::Error.WriteLine('[' + $Provider + '] ' + $ids.Count + ' models')
  exit 0
}

if (-not $Model) {
  [Console]::Error.WriteLine('Missing -Model (or pass -ListModels to enumerate).')
  exit 3
}
if (-not $Prompt) {
  [Console]::Error.WriteLine('Missing -Prompt.')
  exit 3
}

$messages = @()
if ($System) { $messages += @{ role = 'system'; content = $System } }
$messages += @{ role = 'user'; content = $Prompt }
$payload = @{
  model       = $Model
  messages    = $messages
  max_tokens  = $MaxTokens
  temperature = $Temperature
  stream      = $false
}
$json = $payload | ConvertTo-Json -Depth 8 -Compress

$label = '[' + $Provider + '/' + $Model + ']'
$request = New-AuthRequest 'Post' ($endpoint.BaseUrl + '/chat/completions')
$request.Content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, 'application/json')

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$result = Send-Request $request
$sw.Stop()

if ($result.Error) {
  [Console]::Error.WriteLine($label + ' failed after ' + $sw.ElapsedMilliseconds + ' ms: ' + $result.Error)
  exit 1
}

if (-not $result.Ok) {
  [Console]::Error.WriteLine($label + ' HTTP ' + $result.Status + ' after ' + $sw.ElapsedMilliseconds + ' ms')
  [Console]::Error.WriteLine($result.Text)
  exit 1
}

if ($Raw) {
  $result.Text
  exit 0
}

$parsed = $result.Text | ConvertFrom-Json
$msg = $parsed.choices[0].message
$content = $msg.content
$finish = $parsed.choices[0].finish_reason
$completionTokens = $parsed.usage.completion_tokens

if ([string]::IsNullOrWhiteSpace($content)) {
  [Console]::Error.WriteLine($label + ' empty content (finish=' + $finish + ', completion_tokens=' + $completionTokens + ').')
  [Console]::Error.WriteLine('Thinking models burn the budget on reasoning over OpenAI-compatible endpoints; use a non-thinking model or raise MaxTokens.')
  exit 2
}

$content
[Console]::Error.WriteLine($label + ' ' + $sw.ElapsedMilliseconds + ' ms, prompt=' + $parsed.usage.prompt_tokens + ' completion=' + $completionTokens + ' finish=' + $finish)
