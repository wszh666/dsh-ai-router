# Grade every available model on the same 10 KB extraction task.
# ASCII-only source. Prompt and ground truth are read from UTF-8 files.
# Optional: -Only <substring> limits the run to matching model labels, -Light
# skips the slow/paid channels (free + keyless only).
param(
  [string]$Only,
  [switch]$Light
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$promptFile = Join-Path $PSScriptRoot '..\worker-test\prompt-10kb.txt'
$expectedFile = Join-Path $PSScriptRoot '..\worker-test\expected.json'
$prompt = [System.IO.File]::ReadAllText($promptFile, [System.Text.Encoding]::UTF8)
$exp = [System.IO.File]::ReadAllText($expectedFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$truth = @{}
foreach ($r in $exp.rows) { $truth[$r.provider] = $r.key }

$credFile = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
function Get-Cred([string]$name) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  foreach ($line in Get-Content $credFile) {
    if ($line -match ('^\s*' + [regex]::Escape($name) + '\s*:\s*(.+?)\s*$')) {
      $c = $Matches[1].Trim().Trim('"').Trim("'"); if ($c) { return $c }
    }
  }
  return $null
}

$targets = @(
  @{ P='zhipu'; M='glm-4-flash-250414'; U='https://open.bigmodel.cn/api/paas/v4'; K='ZHIPU_API_KEY' },
  @{ P='zhipu'; M='glm-4-flash'; U='https://open.bigmodel.cn/api/paas/v4'; K='ZHIPU_API_KEY' },
  @{ P='zhipu'; M='glm-4v-flash'; U='https://open.bigmodel.cn/api/paas/v4'; K='ZHIPU_API_KEY' },
  @{ P='zhipu'; M='glm-4.5-flash'; U='https://open.bigmodel.cn/api/paas/v4'; K='ZHIPU_API_KEY' },
  @{ P='zhipu'; M='glm-z1-flash'; U='https://open.bigmodel.cn/api/paas/v4'; K='ZHIPU_API_KEY' },
  @{ P='zhipu'; M='glm-4.7-flash'; U='https://open.bigmodel.cn/api/paas/v4'; K='ZHIPU_API_KEY' },
  @{ P='ollama'; M='qwen2.5vl:7b'; U='http://127.0.0.1:11434/v1'; K=$null },
  @{ P='ollama'; M='qwen2.5vl:3b'; U='http://127.0.0.1:11434/v1'; K=$null },
  @{ P='pollinations'; M='openai-fast'; U='https://text.pollinations.ai/openai'; K=$null },
  @{ P='tokenhub'; M='hy3'; U='https://tokenhub.tencentmaas.com/v1'; K='TOKENHUB_API_KEY' },
  @{ P='tokenhub'; M='deepseek-v4-pro'; U='https://tokenhub.tencentmaas.com/v1'; K='TOKENHUB_API_KEY' },
  @{ P='tokenhub'; M='glm-5.3'; U='https://tokenhub.tencentmaas.com/v1'; K='TOKENHUB_API_KEY' },
  @{ P='tokenhub'; M='kimi-k3.1-pro'; U='https://tokenhub.tencentmaas.com/v1'; K='TOKENHUB_API_KEY' },
  @{ P='doubao'; M='doubao-seed-2-1-pro-260915'; U='https://ark.cn-beijing.volces.com/api/v3'; K='ARK_API_KEY' }
)

$freeProviders = @('zhipu', 'ollama', 'pollinations')
if ($Light) { $targets = @($targets | Where-Object { $freeProviders -contains $_.P }) }
if ($Only) { $targets = @($targets | Where-Object { ($_.P + '/' + $_.M) -like ('*' + $Only + '*') }) }
if ($targets.Count -eq 0) { Write-Host 'no target matched'; exit 2 }

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(240)

$results = @()
foreach ($t in $targets) {
  $label = $t.P + '/' + $t.M
  $headers = @{}
  if ($t.K) {
    $key = Get-Cred $t.K
    if ([string]::IsNullOrWhiteSpace($key)) { $results += [pscustomobject]@{ Model=$label; Verdict='NOKEY'; Ms=0; Detail='' }; continue }
    $headers['Authorization'] = 'Bearer ' + $key
  } elseif ($t.P -eq 'pollinations') {
    $headers['Authorization'] = 'Bearer pollinations'
  }
  $body = @{
    model = $t.M
    messages = @(@{ role = 'user'; content = $prompt })
    max_tokens = 2000
    temperature = 0
    stream = $false
  } | ConvertTo-Json -Depth 8 -Compress
  $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, ($t.U + '/chat/completions'))
  $req.Content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
  foreach ($h in $headers.Keys) { [void]$req.Headers.Add($h, $headers[$h]) }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
    $sw.Stop()
    if (-not $resp.IsSuccessStatusCode) {
      $results += [pscustomobject]@{ Model=$label; Verdict=('HTTP ' + [int]$resp.StatusCode); Ms=$sw.ElapsedMilliseconds; Detail=($text.Substring(0,[Math]::Min(80,$text.Length)) -replace '\s+',' ') }
      if ($t.P -eq 'pollinations') { Start-Sleep -Seconds 46 }
      continue
    }
    $parsed = $text | ConvertFrom-Json
    $content = $parsed.choices[0].message.content
    $finish = $parsed.choices[0].finish_reason
    if ([string]::IsNullOrWhiteSpace($content)) {
      $results += [pscustomobject]@{ Model=$label; Verdict=('EMPTY/' + $finish); Ms=$sw.ElapsedMilliseconds; Detail='no content' }
      if ($t.P -eq 'pollinations') { Start-Sleep -Seconds 46 }
      continue
    }
    $m = [regex]::Match($content, '\[[\s\S]*\]')
    if (-not $m.Success) {
      $results += [pscustomobject]@{ Model=$label; Verdict='NOJSON'; Ms=$sw.ElapsedMilliseconds; Detail=(($content -replace '\s+',' ').Substring(0,[Math]::Min(70,$content.Length))) }
      if ($t.P -eq 'pollinations') { Start-Sleep -Seconds 46 }
      continue
    }
    try { $arr = $m.Value | ConvertFrom-Json } catch {
      $results += [pscustomobject]@{ Model=$label; Verdict='BADJSON'; Ms=$sw.ElapsedMilliseconds; Detail='parse error' }
      if ($t.P -eq 'pollinations') { Start-Sleep -Seconds 46 }
      continue
    }
    $got = @{}
    foreach ($item in $arr) {
      if ($null -ne $item.provider) { $got[[string]$item.provider] = $item.key }
    }
    $right = 0; $wrongList = @()
    foreach ($p in $truth.Keys) {
      $tv = $truth[$p]
      if ($got.ContainsKey($p)) {
        $gv = $got[$p]
        if (($null -eq $tv -and $null -eq $gv) -or ("$tv" -eq "$gv")) { $right++ } else { $wrongList += ($p + ':' + $gv) }
      } else { $wrongList += ($p + ':missing') }
    }
    $extra = @($got.Keys | Where-Object { -not $truth.ContainsKey($_) })
    $verdict = "$right/8"
    $detail = ''
    if ($wrongList.Count -gt 0) { $detail = ($wrongList -join ',') }
    if ($extra.Count -gt 0) { $detail = ($detail + ' | extra:' + ($extra -join ',')) }
    if ($finish -eq 'length') { $detail = ($detail + ' | TRUNCATED') }
    $results += [pscustomobject]@{ Model=$label; Verdict=$verdict; Ms=$sw.ElapsedMilliseconds; Detail=$detail }
  } catch {
    $sw.Stop()
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    $results += [pscustomobject]@{ Model=$label; Verdict='FAIL'; Ms=$sw.ElapsedMilliseconds; Detail=$e.Message }
  }
  if ($t.P -eq 'pollinations') { Start-Sleep -Seconds 46 }
}

$results | Format-Table -AutoSize | Out-String -Width 240 | Write-Host
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'extract-results.json') -Encoding UTF8
