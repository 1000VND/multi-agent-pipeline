<#
  oc-run.ps1 - Chay opencode cho 1 task brief, ghi full log ra file,
  chi tra ve summary ngan cho Claude doc.
  Muc dich: Claude khong phai nuot toan bo stdout cua opencode.

  Model mac dinh: deepseek-v4.1-flash (variant max).
  Fallback: mimo-v2.5-pro - chi chay khi luot dau KHONG sinh ra thay doi nao.
#>
param(
  [Parameter(Mandatory = $true)][string]$TaskFile,
  [string]$Model    = "",
  [string]$Variant  = "",
  [string]$Fallback = "",
  [string]$FallbackVariant = "",
  [switch]$NoFallback,
  [string]$Tag = "",
  [switch]$Resume,
  [string]$Attach  = "",  # vd http://127.0.0.1:4096 de ban xem live qua TUI/web
  [string]$Session = "",  # ghim session ID de moi lenh roi vao DUNG phien ban dang attach
  [switch]$NewTui,        # co cu: TUI gio bat mac dinh, tham so nay khong con tac dung rieng
  [switch]$FreshTui,      # kem -NewTui: ep tao phien opencode moi thay vi dung lai phien cu
  [switch]$NoTui,         # tat han cua so TUI (mac dinh la bat)
  [int]$TimeoutSec = 0
)

$ErrorActionPreference = "Stop"
$repo = (& git rev-parse --show-toplevel 2>$null)
if (-not $repo) { Write-Output "Khong phai git repo. Pipeline nay bat buoc dung git."; exit 2 }

# Doc cau hinh pipeline cua repo. Uu tien: tham so dong lenh > config > mac dinh built-in.
$pipelineConfig = $null
$configPath = Join-Path $repo ".pipeline\pipeline.config.json"
try {
  if (Test-Path $configPath) {
    $pipelineConfig = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json
  }
} catch {
  $pipelineConfig = $null
}
if (-not $pipelineConfig) {
  Write-Output "CONFIG: khong doc duoc .pipeline/pipeline.config.json - dung mac dinh built-in"
}
$cfgOpenCode = $null
if ($pipelineConfig) { $cfgOpenCode = $pipelineConfig.model_policy.opencode }
if (($Model -eq "") -and $cfgOpenCode.primary) { $Model = [string]$cfgOpenCode.primary }
if ($Model -eq "") { $Model = "opencode-go/deepseek-v4.1-flash" }
if (($Variant -eq "") -and $cfgOpenCode.variant) { $Variant = [string]$cfgOpenCode.variant }
if ($Variant -eq "") { $Variant = "max" }
if (($Fallback -eq "") -and $cfgOpenCode.fallback) { $Fallback = [string]$cfgOpenCode.fallback }
if ($Fallback -eq "") { $Fallback = "opencode-go/mimo-v2.5-pro" }
if (($TimeoutSec -le 0) -and $pipelineConfig.timeout_sec) { $TimeoutSec = [int]$pipelineConfig.timeout_sec }
if ($TimeoutSec -le 0) { $TimeoutSec = 1200 }
$testCommand = ""
if ($pipelineConfig) { $testCommand = [string]$pipelineConfig.test_command }

if (-not (Test-Path $TaskFile)) { Write-Output "Khong thay task file: $TaskFile"; exit 2 }

# Bat buoc worktree sach truoc khi giao viec -> git diff sau do = dung
# phan opencode vua lam, khong lan voi thay doi cu.
$dirty = & git status --porcelain
if ($dirty -and -not $Resume) {
  Write-Output "BLOCKED: worktree chua sach. Commit hoac stash truoc khi giao task."
  Write-Output $dirty
  exit 3
}

# ---------- chot chan repo: phien opencode phai thuoc dung repo ----------
# Chuan hoa duong dan truoc khi so sanh: git tra F:/x, server tra F:\x.
function Normalize-RepoPath($p) {
  if (-not $p) { return "" }
  return ([string]$p -replace '/', '\').TrimEnd('\')
}
# Hoi server xem phien dang nam o thu muc nao; khac repo thi chan han (exit 9).
# Khong hoi duoc server (mang/timeout) thi chi canh bao, khong chan - chot chan
# khong duoc bien thanh diem chet moi.
function Assert-SessionRepo($attachUrl, $sid) {
  if ($sid -eq "") {
    Write-Output "CANH BAO: khong co session id de doi chieu repo tren $attachUrl - bo qua chot chan."
    return
  }
  $dir      = $null
  $answered = $false
  try {
    $list     = Invoke-RestMethod -Uri "$attachUrl/session" -TimeoutSec 4 -ErrorAction Stop
    $answered = $true
    $hit = @($list) | Where-Object { $_.id -eq $sid } | Select-Object -First 1
    if ($hit -and $hit.directory) { $dir = [string]$hit.directory }
  } catch { }
  if (-not $dir) {
    try {
      $one      = Invoke-RestMethod -Uri "$attachUrl/session/$sid" -TimeoutSec 4 -ErrorAction Stop
      $answered = $true
      if ($one -and $one.directory) { $dir = [string]$one.directory }
    } catch { }
  }
  if (-not $dir) {
    if ($answered) {
      Write-Output "CANH BAO: khong tim thay phien $sid tren $attachUrl - bo qua chot chan."
    } else {
      Write-Output "CANH BAO: khong hoi duoc server $attachUrl - bo qua chot chan."
    }
    return
  }
  if ((Normalize-RepoPath $dir) -ine (Normalize-RepoPath $repo)) {
    Write-Output "BLOCKED: phien opencode dang o '$dir' nhung repo hien tai la '$repo'."
    Write-Output "Coder se sua nham du an. Dung -NoTui, hoac dong server dang chiem cong roi chay lai."
    exit 9
  }
}

# Nguoi goi ghim san -Attach/-Session: kiem ngay truoc khi mo TUI.
if (($Attach -ne "") -and ($Session -ne "")) { Assert-SessionRepo $Attach $Session }

# TUI bat mac dinh: dong cua so TUI cu, lay/tao phien opencode cua phien Claude nay,
# mo cua so CMD moi ghim vao no. Tat bang -NoTui; -NewTui chi con la co cu.
# -Attach chi duoc truyen tiep khi nguoi goi chi dinh ro; khong thi de oc-tui
# tu tim server dung cua repo (moi repo mot server, cong 4096-4105).
if (-not $NoTui) {
  $tuiArgs = @()
  if ($Attach -ne "") { $tuiArgs += @("-Url", $Attach) }
  $tuiArgs += @("-Title", "Task $([IO.Path]::GetFileNameWithoutExtension($TaskFile))")
  if ($FreshTui) { $tuiArgs += "-Fresh" }
  $tui = & powershell -NoProfile -File (Join-Path $PSScriptRoot "oc-tui.ps1") @tuiArgs
  $tui | ForEach-Object { Write-Output $_ }
  $line = $tui | Where-Object { $_ -match "^SESSION=" } | Select-Object -Last 1
  if (-not $line) { Write-Error "oc-tui.ps1 khong tra ve session id."; exit 6 }
  $Session = $line -replace "^SESSION=", ""
  $urlLine = $tui | Where-Object { $_ -match "^URL=" } | Select-Object -Last 1
  if ($urlLine) { $Attach = $urlLine -replace "^URL=", "" }
  elseif ($Attach -eq "") { $Attach = "http://127.0.0.1:4096" }
} else {
  Write-Output "TUI: tat theo yeu cau (-NoTui)"
}

$base = [IO.Path]::GetFileNameWithoutExtension($TaskFile)
if ($Tag -eq "") { $Tag = (Get-Date -Format "HHmmss") }
$logDir = Join-Path $repo ".pipeline\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$head   = & git rev-parse HEAD
$prompt    = Get-Content -Raw -Encoding UTF8 -Path $TaskFile
# PowerShell 5.1 khong tu escape dau nhay kep khi goi native exe: prompt co dau "
# se bi tach thanh nhieu argv va opencode in help roi thoat. Nhan doi backslash
# dung truoc roi escape dau nhay theo quy uoc dong lenh Windows.
$promptArg = $prompt -replace '(\\*)"', '$1$1\"'

# opencode in usage/help khi prompt khong toi noi nguyen ven -> nhan dien de khong dot fallback.
function Test-ArgError($logPath) {
  if (-not (Test-Path $logPath)) { return $false }
  $head = Get-Content -Path $logPath -TotalCount 5 -ErrorAction SilentlyContinue
  return [bool]($head -match 'opencode run \[message')
}

function Invoke-OpenCode($modelId, $variantName, $logPath) {
  $ocArgs = @("run", "--auto", "--model", $modelId)
  if ($variantName -ne "") { $ocArgs += @("--variant", $variantName) }
  if ($Attach  -ne "")     { $ocArgs += @("--attach", $Attach) }
  if ($Session -ne "")     { $ocArgs += @("--session", $Session) }
  if ($Resume)             { $ocArgs += "--continue" }
  $ocArgs += $promptArg

  $label = if ($variantName -ne "") { "$modelId (variant $variantName)" } else { $modelId }
  Write-Output "=> opencode $label | task=$base | log=$logPath"
  if ($Attach -ne "") {
    $watch = if ($Session -ne "") { "opencode attach $Attach -s $Session" } else { "opencode attach $Attach -c" }
    Write-Output "   xem live: $watch"
  }

  $sw = [Diagnostics.Stopwatch]::StartNew()
  # stdout+stderr -> file. Timeout bang job de khong treo session.
  $job = Start-Job -ScriptBlock {
    param($a, $l, $cwd)
    Set-Location $cwd
    & opencode @a *>&1 | Out-File -FilePath $l -Encoding utf8
    $LASTEXITCODE
  } -ArgumentList $ocArgs, $logPath, $repo

  if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
    Stop-Job $job; Remove-Job $job -Force
    $sw.Stop()
    Write-Output "TIMEOUT sau ${TimeoutSec}s - xem log: $logPath"
    return @{ code = 124; secs = [int]$sw.Elapsed.TotalSeconds }
  }
  $code = Receive-Job $job
  Remove-Job $job -Force
  $sw.Stop()
  return @{ code = $code; secs = [int]$sw.Elapsed.TotalSeconds }
}

# ---------- luot chinh ----------
# Chot chan cuoi: xac nhan lan nua phien/URL sap dung thuoc dung repo.
if ($Attach -ne "") { Assert-SessionRepo $Attach $Session }
$log = Join-Path $logDir "$base-$Tag.log"
$r   = Invoke-OpenCode $Model $Variant $log
$usedModel = $Model
$changed   = & git status --porcelain

# ---------- fallback ----------
# Chi fallback khi luot dau KHONG dong vao file nao. Neu no da sua do dang
# roi hong, de nguyen cho Claude xem xet - khong tha model thu hai vao
# dam len thay doi cua model thu nhat.
if ((-not $changed) -and (-not $NoFallback) -and ($Fallback -ne "") -and (-not (Test-ArgError $log))) {
  Write-Output ""
  Write-Output "--- luot dau khong sinh thay doi (exit=$($r.code)) -> thu fallback ---"
  $log = Join-Path $logDir "$base-$Tag-fallback.log"
  $r   = Invoke-OpenCode $Fallback $FallbackVariant $log
  $usedModel = $Fallback
  $changed   = & git status --porcelain
}

$stat = & git diff --stat

# ---------- tu chay test suite khi co file thay doi ----------
$testsRan    = $false
$testsFailed = $false
$testsTail   = @()
if ($changed) {
  if ($testCommand -ne "") {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      # 2>&1 phai nam trong chuoi IEX: redirect ben ngoai khong bat duoc stderr cua lenh native.
      $testsText = (Invoke-Expression ($testCommand + " 2>&1") | Out-String)
      $testsRan  = $true
    } catch {
      $testsRan = $false
    }
    $ErrorActionPreference = $prevEAP
  }
  if ($testsRan) {
    if ($testsText -cmatch '(?m)^(FAILED|ERROR:)') { $testsFailed = $true }
    $lines = @($testsText -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    if ($lines.Count -ge 2) { $testsTail = @($lines[-2], $lines[-1]) } else { $testsTail = $lines }
  }
}

Write-Output ""
Write-Output "--- KET QUA ($($r.secs)s, exit=$($r.code)) ---"
Write-Output "MODEL DA DUNG: $usedModel"
Write-Output "BASE_COMMIT: $head"
Write-Output "FILES THAY DOI:"
if ($changed) { Write-Output $changed } else { Write-Output "  (KHONG CO FILE NAO THAY DOI - coi nhu task that bai)" }
Write-Output ""
Write-Output "DIFFSTAT:"
Write-Output $stat
if ($changed) {
  Write-Output ""
  if ($testsRan) {
    Write-Output "TESTS:"
    Write-Output $testsTail
    if ($testsFailed) { Write-Output "TESTS: FAILED - xem chi tiet o tren" }
  } elseif ($testCommand -eq "") {
    Write-Output "TESTS: khong co test_command trong .pipeline/pipeline.config.json - bo qua"
  } else {
    Write-Output "TESTS: khong chay duoc test_command - bo qua"
  }
}
Write-Output ""
Write-Output "--- 40 DONG CUOI CUA LOG ---"
Get-Content $log -Tail 40
Write-Output "--- (full log: $log) ---"

if ($testsFailed) { exit 8 }
if (Test-ArgError $log) {
  Write-Output "ARGERROR: opencode in usage/help - prompt khong toi noi nguyen ven, KHONG phai model tu choi task"
  exit 7
}
if (-not $changed) { exit 5 }
exit 0
