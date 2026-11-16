# media.ps1
#
# Generate an image (Seedream) or a video (Seedance) on Volcengine Ark,
# download the result to disk, and print the local path.
#
# Why this exists: Ark returns a presigned URL (not bytes), so a generation is
# useless unless it is downloaded within the URL's lifetime. This script does
# create -> poll -> download in one step.
#
# ASCII-only source: Windows PowerShell reads a BOM-less .ps1 as ANSI.
# Chinese prompts still arrive correctly because arguments are passed as UTF-16
# by the calling shell; the HTTP body is always encoded as UTF-8 explicitly.
#
# Exit codes: 0 ok / 1 request or task failure / 2 empty result / 3 missing key.
#
# Examples:
#   .\media.cmd -Kind image -Prompt "a silver-haired anime girl portrait" -Out out\a.png
#   .\media.cmd -Kind video -Prompt "a cat yawning on a sunlit windowsill" -Out out\a.mp4

[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('image', 'video')][string]$Kind,
  [string]$Prompt,
  [string]$PromptFile,
  [string]$Model,
  [string]$Out,
  [string]$Size = '1024x1024',
  [string]$Resolution = '720p',
  [int]$Duration = 5,
  [string]$Ratio = '16:9',
  [int]$TimeoutSec = 900,
  [switch]$NoWatermark
)

$ErrorActionPreference = 'Stop'

# --- provider config -------------------------------------------------------
# Credential resolution mirrors the other bin scripts: process environment
# first, then the harness credential file, so a key stored by DSH works here.
function Get-Cred([string]$name) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  $file = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
  if (-not (Test-Path $file)) { return $null }
  foreach ($line in Get-Content $file) {
    if ($line -match ('^\s*' + [regex]::Escape($name) + '\s*:\s*(.+?)\s*$')) {
      $c = $Matches[1].Trim().Trim('"').Trim("'"); if ($c) { return $c }
    }
  }
  return $null
}

$apiKey = Get-Cred 'ARK_API_KEY'
if ([string]::IsNullOrWhiteSpace($apiKey)) {
  [Console]::Error.WriteLine('Missing credential: ARK_API_KEY is neither in the environment nor in ~/.dsh/.credentials.yaml.')
  exit 3
}
$baseUrl = 'https://ark.cn-beijing.volces.com/api/v3'

if (-not $Model) {
  if ($Kind -eq 'image') { $Model = 'doubao-seedream-5-5-261028' }
  else { $Model = 'doubao-seedance-2-5-260628' }
}

# --- prompt ----------------------------------------------------------------
if (-not $Prompt -and $PromptFile) {
  $Prompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
}
if ([string]::IsNullOrWhiteSpace($Prompt)) {
  [Console]::Error.WriteLine('Missing prompt: pass -Prompt or -PromptFile.')
  exit 3
}
$Prompt = $Prompt.Trim()

# --- output path -----------------------------------------------------------
if (-not $Out) {
  $ext = if ($Kind -eq 'image') { '.png' } else { '.mp4' }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $Out = Join-Path (Get-Location).Path ('ark-' + $Kind + '-' + $stamp + $ext)
}
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# --- shared HTTP client ----------------------------------------------------
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$handler = New-Object System.Net.Http.HttpClientHandler
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(120)

function Invoke-ArkJson([string]$Method, [string]$Path, [string]$JsonBody) {
  $url = $baseUrl + $Path
  $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::$Method, $url)
  $request.Headers.Add('Authorization', ('Bearer ' + $apiKey))
  if ($JsonBody) {
    $request.Content = New-Object System.Net.Http.StringContent($JsonBody, [System.Text.Encoding]::UTF8, 'application/json')
  }
  $response = $client.SendAsync($request).GetAwaiter().GetResult()
  $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  return @{ Status = [int]$response.StatusCode; Text = $text }
}

function Show-ArkError([string]$label, $result) {
  [Console]::Error.WriteLine($label + ' HTTP ' + $result.Status)
  [Console]::Error.WriteLine($result.Text)
  # Surface Ark's machine-readable error code, which is far more useful than 404.
  try {
    $err = $result.Text | ConvertFrom-Json
    if ($err.error.code) { [Console]::Error.WriteLine('code: ' + $err.error.code) }
    if ($err.error.code -eq 'ModelNotOpen') {
      [Console]::Error.WriteLine('This model is not activated for your account. Activate it in the Ark Console first.')
    }
  } catch { }
}

# --- build request ---------------------------------------------------------
if ($Kind -eq 'image') {
  $payload = @{
    model           = $Model
    prompt          = $Prompt
    size            = $Size
    response_format = 'url'
    watermark       = (-not $NoWatermark)
  }
} else {
  $suffix = ' --resolution ' + $Resolution + ' --duration ' + $Duration + ' --ratio ' + $Ratio
  if (-not $NoWatermark) { $suffix = $suffix + ' --watermark true' }
  $payload = @{
    model   = $Model
    content = @(@{ type = 'text'; text = ($Prompt + $suffix) })
  }
}
$json = $payload | ConvertTo-Json -Depth 10 -Compress

# --- image: one shot -------------------------------------------------------
if ($Kind -eq 'image') {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $r = Invoke-ArkJson 'Post' '/images/generations' $json
  $sw.Stop()
  if ($r.Status -ne 200) { Show-ArkError ('[image/' + $Model + ']') $r; exit 1 }

  $doc = $r.Text | ConvertFrom-Json
  $url = $doc.data[0].url
  if (-not $url) {
    [Console]::Error.WriteLine('No image url in response: ' + $r.Text)
    exit 2
  }
  $dl = $client.GetAsync($url).GetAwaiter().GetResult()
  if (-not $dl.IsSuccessStatusCode) {
    [Console]::Error.WriteLine('Download failed: HTTP ' + [int]$dl.StatusCode)
    exit 1
  }
  $data = $dl.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
  [System.IO.File]::WriteAllBytes($Out, $data)
  [Console]::Error.WriteLine('[image/' + $Model + '] ' + $sw.ElapsedMilliseconds + ' ms, ' + $data.Length + ' bytes -> ' + $Out)
  $Out
  exit 0
}

# --- video: create then poll ----------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-ArkJson 'Post' '/contents/generations/tasks' $json
if ($r.Status -ne 200) { Show-ArkError ('[video/' + $Model + ']') $r; exit 1 }
$taskId = ($r.Text | ConvertFrom-Json).id
if (-not $taskId) {
  [Console]::Error.WriteLine('No task id in response: ' + $r.Text)
  exit 2
}
[Console]::Error.WriteLine('[video/' + $Model + '] task ' + $taskId + ' queued')

$videoUrl = $null
$lastStatus = ''
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
  Start-Sleep -Seconds 5
  $p = Invoke-ArkJson 'Get' ('/contents/generations/tasks/' + $taskId) $null
  if ($p.Status -ne 200) { Show-ArkError '[video/task]' $p; exit 1 }
  $task = $p.Text | ConvertFrom-Json
  if ($task.status -ne $lastStatus) {
    [Console]::Error.WriteLine('[video] status=' + $task.status)
    $lastStatus = $task.status
  }
  if ($task.status -eq 'succeeded') { $videoUrl = $task.content.video_url; break }
  if ($task.status -eq 'failed' -or $task.status -eq 'cancelled') {
    [Console]::Error.WriteLine('Task ended as ' + $task.status + ': ' + $p.Text)
    exit 1
  }
}

if (-not $videoUrl) {
  [Console]::Error.WriteLine('Timed out after ' + $TimeoutSec + ' s waiting for the video task.')
  exit 1
}

$dl = $client.GetAsync($videoUrl).GetAwaiter().GetResult()
if (-not $dl.IsSuccessStatusCode) {
  [Console]::Error.WriteLine('Download failed: HTTP ' + [int]$dl.StatusCode)
  exit 1
}
$data = $dl.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
[System.IO.File]::WriteAllBytes($Out, $data)
[Console]::Error.WriteLine('[video/' + $Model + '] ' + [int]$sw.Elapsed.TotalSeconds + ' s, ' + $data.Length + ' bytes -> ' + $Out)
$Out
exit 0
