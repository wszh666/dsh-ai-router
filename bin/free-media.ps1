# free-media.ps1
#
# Generate an image or a video with a FREE provider, then save it to disk.
#
# Providers:
#   pollinations : keyless image API, no signup, best for quick drafts.
#   zhipu        : BigModel's free models -- cogview-3-flash (image) and
#                  cogvideox-flash (video). Officially priced at 0 and they do
#                  not draw down the new-user token gift. Needs ZHIPU_API_KEY.
#
# Workflow, both providers:
#   create -> poll (video is async, submit then query) -> download -> print path.
#
# ASCII-only source: Windows PowerShell reads a BOM-less .ps1 as ANSI.
# Chinese prompts are fine because arguments arrive as UTF-16 and the body is
# explicitly encoded as UTF-8.
#
# Exit codes: 0 ok / 1 request or task failure / 2 empty result / 3 missing key.
#
# Examples:
#   .\free-media.cmd -Kind image -Prompt "silver-haired anime girl portrait"
#   .\free-media.cmd -Kind video -Provider zhipu -Prompt "orange cat yawning"

[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('image', 'video')][string]$Kind,
  [string]$Prompt,
  [ValidateSet('pollinations', 'zhipu', 'dashscope')][string]$Provider,
  [string]$Model,
  [string]$Out,
  [string]$Size = '1024x1024',
  [int]$Duration = 5,
  [string]$Resolution = '480P',
  [string]$BaseUrl,
  [string]$ImageUrl,
  [int]$TimeoutSec = 900
)

$ErrorActionPreference = 'Stop'

if (-not $Prompt) {
  [Console]::Error.WriteLine('Missing prompt: pass -Prompt.')
  exit 3
}
$Prompt = $Prompt.Trim()

if (-not $Provider) {
  if ($Kind -eq 'image') { $Provider = 'pollinations' } else { $Provider = 'zhipu' }
}
if (-not $Model) {
  if ($Provider -eq 'dashscope') {
    if ($Kind -eq 'image') { $Model = 'wan2.6-t2i' } else { $Model = 'wan3.0-video' }
  } elseif ($Provider -eq 'zhipu') {
    if ($Kind -eq 'image') { $Model = 'cogview-3-flash' } else { $Model = 'cogvideox-flash' }
  } else {
    if ($Kind -eq 'image') { $Model = 'flux' } else { $Model = 'flux' }
  }
}

if (-not $Out) {
  $ext = if ($Kind -eq 'image') { '.jpg' } else { '.mp4' }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $Out = Join-Path (Get-Location).Path ('free-' + $Provider + '-' + $Kind + '-' + $stamp + $ext)
}
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(120)

function Normalize-Ext([string]$path) {
  # Providers label their result URLs loosely: BigModel hands back JPEG bytes
  # under a .png name. Sniff the magic bytes and rename so the file is honest.
  $head = [System.IO.File]::ReadAllBytes($path)
  if ($head.Length -lt 12) { return $path }
  $ext = [System.IO.Path]::GetExtension($path)
  $real = $ext
  if ($head[0] -eq 0x89 -and $head[1] -eq 0x50) { $real = '.png' }
  elseif ($head[0] -eq 0xFF -and $head[1] -eq 0xD8) { $real = '.jpg' }
  elseif ($head[0] -eq 0x52 -and $head[1] -eq 0x49 -and $head[8] -eq 0x57) { $real = '.webp' }
  elseif ($head[4] -eq 0x66 -and $head[5] -eq 0x74 -and $head[6] -eq 0x79 -and $head[7] -eq 0x70) { $real = '.mp4' }
  if ($real -eq $ext) { return $path }
  $target = [System.IO.Path]::ChangeExtension($path, $real)
  Move-Item -Path $path -Destination $target -Force
  [Console]::Error.WriteLine('[warn] bytes are ' + $real + ', renamed -> ' + $target)
  return $target
}

function Save-Url([string]$url, [string]$path) {
  $res = $client.GetAsync($url).GetAwaiter().GetResult()
  if (-not $res.IsSuccessStatusCode) {
    [Console]::Error.WriteLine('Download failed: HTTP ' + [int]$res.StatusCode)
    return ''
  }
  $bytes = $res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
  [System.IO.File]::WriteAllBytes($path, $bytes)
  return (Normalize-Ext $path)
}

function Invoke-Json([string]$method, [string]$url, [string]$json, [string]$key, $extraHeaders = $null) {
  $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::$method, $url)
  if ($key) { $req.Headers.Add('Authorization', 'Bearer ' + $key) }
  if ($extraHeaders) { foreach ($h in $extraHeaders.Keys) { $req.Headers.Add($h, $extraHeaders[$h]) } }
  if ($json) { $req.Content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, 'application/json') }
  $res = $client.SendAsync($req).GetAwaiter().GetResult()
  $bytes = $res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  return @{ Status = [int]$res.StatusCode; Text = $text }
}

function Show-Error([string]$label, $r) {
  [Console]::Error.WriteLine($label + ' HTTP ' + $r.Status)
  [Console]::Error.WriteLine($r.Text)
}

function Get-ApiKey([string]$name) {
  # Env var first, then the DSH credential store, so no export step is needed.
  $v = [Environment]::GetEnvironmentVariable($name)
  if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  $credPath = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
  if (Test-Path $credPath) {
    $hit = Select-String -Path $credPath -Pattern ('^\s*' + $name + ':\s*(\S+)\s*$') | Select-Object -First 1
    if ($hit) { return $hit.Matches[0].Groups[1].Value }
  }
  return ''
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------------------
# pollinations: GET returns the image bytes directly, no key, no task.
# ---------------------------------------------------------------------------
if ($Provider -eq 'pollinations') {
  if ($Kind -eq 'video') {
    [Console]::Error.WriteLine('pollinations does not do video. Use -Provider zhipu.')
    exit 3
  }
  $parts = $Size -split 'x'
  if ($parts.Count -ne 2) { [Console]::Error.WriteLine('Bad -Size, expected WxH.'); exit 3 }
  $encoded = [System.Uri]::EscapeDataString($Prompt)
  $url = 'https://image.pollinations.ai/prompt/' + $encoded +
         '?width=' + $parts[0] + '&height=' + $parts[1] + '&nologo=true&model=' + $Model
  # Anonymous pollinations is rate limited and answers 402 (or 429) when the
  # per-IP window is full. It is a wait, not a failure -- back off and retry.
  $saved = $false
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    $res = $client.GetAsync($url).GetAwaiter().GetResult()
    $code = [int]$res.StatusCode
    if ($code -eq 200) {
      $bytes = $res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
      [System.IO.File]::WriteAllBytes($Out, $bytes)
      $Out = Normalize-Ext $Out
      $saved = $true
      break
    }
    [Console]::Error.WriteLine('[pollinations] attempt ' + $attempt + ' HTTP ' + $code)
    if ($code -ne 402 -and $code -ne 429) { break }
    Start-Sleep -Seconds 15
  }
  if (-not $saved) { exit 1 }
  $sw.Stop()
  $size = (Get-Item $Out).Length
  [Console]::Error.WriteLine('[pollinations/' + $Model + '] ' + $sw.ElapsedMilliseconds + ' ms, ' + $size + ' bytes -> ' + $Out)
  $Out
  exit 0
}

# ---------------------------------------------------------------------------
# dashscope: Alibaba Cloud Bailian (Wan 2.6). Async for both image and video:
# submit -> GET /api/v1/tasks/{id} -> result url. Free trial quota is generous
# for new accounts (100 images / 50 seconds of video).
# ---------------------------------------------------------------------------
if ($Provider -eq 'dashscope') {
  $dsKey = Get-ApiKey 'DASHSCOPE_API_KEY'
  if ([string]::IsNullOrWhiteSpace($dsKey)) {
    [Console]::Error.WriteLine('Missing credential: DASHSCOPE_API_KEY is not set.')
    [Console]::Error.WriteLine('Create one at https://bailian.console.aliyun.com/ after activating Bailian.')
    exit 3
  }
  $dsBase = $BaseUrl
  if ([string]::IsNullOrWhiteSpace($dsBase)) { $dsBase = Get-ApiKey 'DASHSCOPE_BASE_URL' }
  if ([string]::IsNullOrWhiteSpace($dsBase)) { $dsBase = 'https://dashscope.aliyuncs.com/api/v1' }
  $dsBase = $dsBase.TrimEnd('/')
  $dsHeaders = @{ 'X-DashScope-Async' = 'enable' }

  if ($Kind -eq 'image') {
    $px = $Size -replace 'x', '*'
    $body = @{ model = $Model; input = @{ prompt = $Prompt }; parameters = @{ size = $px; n = 1 } } | ConvertTo-Json -Depth 6 -Compress
    $r = Invoke-Json 'Post' ($dsBase + '/services/aigc/text2image/image-synthesis') $body $dsKey $dsHeaders
  } else {
    # wan3.0-video uses resolution/ratio; the 2.x line uses size.
    if ($Model -like 'wan3*') {
      $vparams = @{ resolution = $Resolution; ratio = 'adaptive'; duration = $Duration }
    } else {
      $vparams = @{ size = '1280*720'; duration = $Duration }
    }
    $body = @{ model = $Model; input = @{ prompt = $Prompt }; parameters = $vparams } | ConvertTo-Json -Depth 6 -Compress
    $r = Invoke-Json 'Post' ($dsBase + '/services/aigc/video-generation/video-synthesis') $body $dsKey $dsHeaders
  }

  if ($r.Status -ne 200) { Show-Error ('[dashscope/' + $Model + ']') $r; exit 1 }
  $taskId = ($r.Text | ConvertFrom-Json).output.task_id
  if (-not $taskId) { [Console]::Error.WriteLine('No task id: ' + $r.Text); exit 2 }
  [Console]::Error.WriteLine('[dashscope/' + $Model + '] task ' + $taskId + ' submitted')

  $resultUrl = $null
  $last = ''
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    Start-Sleep -Seconds 6
    $p = Invoke-Json 'Get' ($dsBase + '/tasks/' + $taskId) $null $dsKey
    if ($p.Status -ne 200) { Show-Error '[dashscope/task]' $p; exit 1 }
    $task = $p.Text | ConvertFrom-Json
    $status = $task.output.task_status
    if ($status -ne $last) {
      [Console]::Error.WriteLine('[dashscope] status=' + $status)
      $last = $status
    }
    if ($status -eq 'SUCCEEDED') {
      if ($Kind -eq 'image') { $resultUrl = $task.output.results[0].url }
      else { $resultUrl = $task.output.video_url }
      break
    }
    if ($status -eq 'FAILED') {
      [Console]::Error.WriteLine('Task failed: ' + $p.Text)
      exit 1
    }
  }

  if (-not $resultUrl) {
    [Console]::Error.WriteLine('Timed out after ' + $TimeoutSec + ' s.')
    exit 1
  }
  $Out = Save-Url $resultUrl $Out
  if (-not $Out) { exit 1 }
  $sw.Stop()
  [Console]::Error.WriteLine('[dashscope/' + $Model + '] ' + [int]$sw.Elapsed.TotalSeconds + ' s -> ' + $Out)
  $Out
  exit 0
}

# ---------------------------------------------------------------------------
# zhipu: needs a key. Same host for image and video, different paths.
# ---------------------------------------------------------------------------
$key = Get-ApiKey 'ZHIPU_API_KEY'
if ([string]::IsNullOrWhiteSpace($key)) {
  [Console]::Error.WriteLine('Missing credential: ZHIPU_API_KEY is not set.')
  [Console]::Error.WriteLine('Get a free key at https://open.bigmodel.cn/ (cogview-3-flash and cogvideox-flash are 0 yuan).')
  exit 3
}
$base = 'https://open.bigmodel.cn/api/paas/v4'

if ($Kind -eq 'image') {
  $payload = @{ model = $Model; prompt = $Prompt; size = $Size } | ConvertTo-Json -Compress
  # The free tier answers 429 (code 1305) when it is busy. That is a queue, not
  # a failure -- back off and retry.
  $r = $null
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $r = Invoke-Json 'Post' ($base + '/images/generations') $payload $key
    if ($r.Status -eq 200) { break }
    [Console]::Error.WriteLine('[zhipu-image] attempt ' + $attempt + ' HTTP ' + $r.Status)
    if ($r.Status -ne 429) { break }
    Start-Sleep -Seconds 12
  }
  if ($r.Status -ne 200) { Show-Error ('[zhipu-image/' + $Model + ']') $r; exit 1 }
  $doc = $r.Text | ConvertFrom-Json
  $url = $doc.data[0].url
  if (-not $url) { [Console]::Error.WriteLine('No image url: ' + $r.Text); exit 2 }
  $Out = Save-Url $url $Out
  if (-not $Out) { exit 1 }
  $sw.Stop()
  [Console]::Error.WriteLine('[zhipu-image/' + $Model + '] ' + $sw.ElapsedMilliseconds + ' ms -> ' + $Out)
  $Out
  exit 0
}

# video: submit, then poll async-result until SUCCESS.
# With -ImageUrl this becomes image-to-video; the URL must be publicly reachable.
$vpayload = @{ model = $Model; prompt = $Prompt }
if ($ImageUrl) { $vpayload['image_url'] = $ImageUrl }
$vpayload = $vpayload | ConvertTo-Json -Compress
$r = $null
for ($attempt = 1; $attempt -le 8; $attempt++) {
  $r = Invoke-Json 'Post' ($base + '/videos/generations') $vpayload $key
  if ($r.Status -eq 200) { break }
  [Console]::Error.WriteLine('[zhipu-video] attempt ' + $attempt + ' HTTP ' + $r.Status)
  if ($r.Status -ne 429) { break }
  Start-Sleep -Seconds 20
}
if ($r.Status -ne 200) { Show-Error ('[zhipu-video/' + $Model + ']') $r; exit 1 }
$taskId = ($r.Text | ConvertFrom-Json).id
if (-not $taskId) { [Console]::Error.WriteLine('No task id: ' + $r.Text); exit 2 }
[Console]::Error.WriteLine('[zhipu-video/' + $Model + '] task ' + $taskId + ' submitted')

$videoUrl = $null
$last = ''
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
  Start-Sleep -Seconds 6
  $p = Invoke-Json 'Get' ($base + '/async-result/' + $taskId) $null $key
  if ($p.Status -ne 200) { Show-Error '[zhipu-video/task]' $p; exit 1 }
  $task = $p.Text | ConvertFrom-Json
  if ($task.task_status -ne $last) {
    [Console]::Error.WriteLine('[zhipu-video] status=' + $task.task_status)
    $last = $task.task_status
  }
  if ($task.task_status -eq 'SUCCESS') { $videoUrl = $task.video_result[0].url; break }
  if ($task.task_status -eq 'FAIL') {
    [Console]::Error.WriteLine('Task failed: ' + $p.Text)
    exit 1
  }
}

if (-not $videoUrl) {
  [Console]::Error.WriteLine('Timed out after ' + $TimeoutSec + ' s.')
  exit 1
}
$Out = Save-Url $videoUrl $Out
if (-not $Out) { exit 1 }
$sw.Stop()
[Console]::Error.WriteLine('[zhipu-video/' + $Model + '] ' + [int]$sw.Elapsed.TotalSeconds + ' s -> ' + $Out)
$Out
exit 0
