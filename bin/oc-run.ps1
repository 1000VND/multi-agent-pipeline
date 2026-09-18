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
  [int]$TimeoutSec = 0,
  [string]$OpenCodeCmd = "" # test/diagnostic: duong dan day du toi opencode.cmd
)

$ErrorActionPreference = "Stop"
$fallbackOverrideRequested = $PSBoundParameters.ContainsKey("Fallback")
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

# Chuoi fallback co variant rieng: khong duoc ep --variant max vao model khong
# ho tro (MiMo), va LongCat/Qwen co muc cao nhat khac nhau. Config cu chi co
# "fallback" duoc thay the bang hai danh sach co thu tu ro rang ben duoi.
$builtInNoChangeFallbacks = @(
  [pscustomobject]@{ model = "opencode-go/deepseek-v4-flash";            variant = "max" },
  [pscustomobject]@{ model = "opencode-go/deepseek-v4-flash-vision-exp"; variant = "max" },
  [pscustomobject]@{ model = "opencode-go/mimo-v2.5-pro";                variant = "" },
  [pscustomobject]@{ model = "opencode-go/longcat-2.0";                  variant = "high" },
  [pscustomobject]@{ model = "opencode-go/qwen3.8-flash";               variant = "xhigh" }
)
$builtInQuotaFallbacks = @(
  $builtInNoChangeFallbacks[4],
  $builtInNoChangeFallbacks[3],
  $builtInNoChangeFallbacks[2],
  $builtInNoChangeFallbacks[1],
  $builtInNoChangeFallbacks[0]
)

function Get-ModelSequence($configured, $defaultSequence) {
  $items = @()
  foreach ($entry in @($configured)) {
    if ($null -eq $entry) { continue }
    $modelName = ""
    $variantName = ""
    if ($entry -is [string]) {
      $modelName = [string]$entry
    } else {
      $modelName = [string]$entry.model
      $variantName = [string]$entry.variant
    }
    if ($modelName -ne "") {
      $items += [pscustomobject]@{ model = $modelName; variant = $variantName }
    }
  }
  if ($items.Count -eq 0) { return @($defaultSequence) }
  return @($items)
}

$noChangeFallbacks = Get-ModelSequence $cfgOpenCode.fallback_on_no_change $builtInNoChangeFallbacks
$quotaFallbacks    = Get-ModelSequence $cfgOpenCode.fallback_on_quota     $builtInQuotaFallbacks
# -Fallback/-FallbackVariant la override tuong thich nguoc: mot model thay ca
# hai chuoi fallback cua lanh hien tai, uu tien cao hon config.
if ($fallbackOverrideRequested) {
  $override = [pscustomobject]@{ model = $Fallback; variant = $FallbackVariant }
  $noChangeFallbacks = @($override)
  $quotaFallbacks = @($override)
}
if (($TimeoutSec -le 0) -and $pipelineConfig.timeout_sec) { $TimeoutSec = [int]$pipelineConfig.timeout_sec }
if ($TimeoutSec -le 0) { $TimeoutSec = 1200 }
$testCommand = ""
if ($pipelineConfig) { $testCommand = [string]$pipelineConfig.test_command }

if (-not (Test-Path $TaskFile)) { Write-Output "Khong thay task file: $TaskFile"; exit 2 }
$taskFilePath = (Resolve-Path -LiteralPath $TaskFile).Path

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

# Luon lay/tao session truoc khi giao task. Headless chi bo qua viec mo CMD,
# van in lenh attach de nguoi dung co the mo lai TUI sau khi da dong nham.
$tuiArgs = @()
if ($Attach -ne "") { $tuiArgs += @("-Url", $Attach) }
$tuiArgs += @("-Title", "Task $([IO.Path]::GetFileNameWithoutExtension($TaskFile))")
if ($FreshTui) { $tuiArgs += "-Fresh" }
if ($NoTui) { $tuiArgs += "-NoWindow" }
$tui = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "oc-tui.ps1") @tuiArgs
$tui | ForEach-Object { Write-Output $_ }
$line = $tui | Where-Object { $_ -match "^SESSION=" } | Select-Object -Last 1
if (-not $line) { Write-Error "oc-tui.ps1 khong tra ve session id."; exit 6 }
$Session = $line -replace "^SESSION=", ""
$urlLine = $tui | Where-Object { $_ -match "^URL=" } | Select-Object -Last 1
if ($urlLine) { $Attach = $urlLine -replace "^URL=", "" }
elseif ($Attach -eq "") { $Attach = "http://127.0.0.1:4096" }

$tuiHint = "opencode attach $Attach -s $Session"
if ($NoTui) {
  Write-Output "MODE: headless (khong mo cua so)"
}
Write-Output "TUI: $tuiHint"

$base = [IO.Path]::GetFileNameWithoutExtension($TaskFile)
if ($Tag -eq "") { $Tag = (Get-Date -Format "HHmmss") }
$logDir = Join-Path $repo ".pipeline\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$head   = & git rev-parse HEAD

# npm cai ca opencode.ps1 va opencode.cmd. Tren mot so ban Windows/Bun,
# shim .ps1 co the loi EEXIST luc khoi dong trong khi shim .cmd van chay
# binh thuong. Ep dung .cmd de runner khop voi lenh opencode trong CMD.
$openCodePath = ""
if ($OpenCodeCmd -ne "") {
  try {
    $openCodePath = (Resolve-Path -LiteralPath $OpenCodeCmd -ErrorAction Stop).Path
  } catch {
    Write-Output "LOI: khong tim thay opencode.cmd da chi dinh: $OpenCodeCmd"
    exit 7
  }
  if ([IO.Path]::GetFileName($openCodePath) -ine "opencode.cmd") {
    Write-Output "LOI: -OpenCodeCmd phai tro toi file opencode.cmd, khong phai '$openCodePath'."
    exit 7
  }
} else {
  $openCodeCmdInfo = Get-Command "opencode.cmd" -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if (-not $openCodeCmdInfo) {
    Write-Output "LOI: khong tim thay opencode.cmd trong PATH. Mo CMD, chay 'opencode --version', roi cai/sua PATH cua OpenCode."
    exit 7
  }
  $openCodePath = $openCodeCmdInfo.Source
}
Write-Output "CLI: $openCodePath"

# opencode in usage/help khi prompt khong toi noi nguyen ven -> nhan dien de khong dot fallback.
function Test-ArgError($logPath) {
  if (-not (Test-Path $logPath)) { return $false }
  $head = Get-Content -Path $logPath -TotalCount 5 -ErrorAction SilentlyContinue
  return [bool]($head -match 'opencode run \[message')
}

# Chi dung chuoi quota khi CLI/API bao het quota, rate limit hoac model khong
# kha dung. Khong coi loi prompt/CLI la quota de tranh thu model khac vo ich.
function Test-QuotaOrUnavailable($logPath) {
  if (-not (Test-Path $logPath)) { return $false }
  $text = Get-Content -Raw -Encoding UTF8 -Path $logPath -ErrorAction SilentlyContinue
  return [bool]($text -match '(?im)(\bquota\b|rate[ -]?limit|usage[ -]?limit|too many requests|insufficient (credit|balance)|model .*\b(unavailable|not available)\b)')
}

function Invoke-OpenCode($modelId, $variantName, $logPath) {
  $ocArgs = @("run", "--auto", "--model", $modelId)
  if ($variantName -ne "") { $ocArgs += @("--variant", $variantName) }
  if ($Attach  -ne "")     { $ocArgs += @("--attach", $Attach) }
  if ($Session -ne "")     { $ocArgs += @("--session", $Session) }
  if ($Resume)             { $ocArgs += "--continue" }

  $label = if ($variantName -ne "") { "$modelId (variant $variantName)" } else { $modelId }
  Write-Output "=> opencode $label | task=$base (stdin UTF-8) | log=$logPath"
  if ($Attach -ne "") { Write-Output "   xem live: $tuiHint" }

  $sw = [Diagnostics.Stopwatch]::StartNew()
  # Job tu ghi PID cua no ra file trong TEMP de cha biet duong giet ca cay khi
  # het gio. Brief truyen qua stdin, khong nam trong argv: tranh gioi han 8191
  # ky tu cua opencode.cmd/cmd.exe va khong can tu escape dau nhay.
  $pidFile = Join-Path $env:TEMP ("oc-run-{0}-{1}.pid" -f $Tag, [guid]::NewGuid().ToString("N").Substring(0, 8))
  # stdout+stderr -> file. Timeout bang job de khong treo session.
  $job = Start-Job -ScriptBlock {
    param($a, $l, $cwd, $pf, $exe, $task)
    Set-Content -Path $pf -Value $PID
    Set-Location $cwd
    # Windows PowerShell 5.1 mac dinh ghi ASCII vao native stdin; ep UTF-8
    # de brief tieng Viet va ky tu dac biet den OpenCode nguyen ven.
    $previousOutputEncoding = $OutputEncoding
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    try {
      Get-Content -Raw -Encoding UTF8 -LiteralPath $task |
        & $exe @a *>&1 |
        Out-File -FilePath $l -Encoding utf8
      $exitCode = $LASTEXITCODE
    } finally {
      $OutputEncoding = $previousOutputEncoding
    }
    $exitCode
  } -ArgumentList $ocArgs, $logPath, $repo, $pidFile, $openCodePath, $taskFilePath

  if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
    # Stop-Job chi giet job PowerShell, opencode.exe ma job de ra van song tiep.
    # Doc pid file, xac nhan dung job powershell (PID co the da bi cap lai cho
    # tien trinh khac), roi diet cay cac con cua no (opencode + con chau).
    # Khong taskkill thang vao job: job process bi giet cung lam PowerShell cho
    # them ~60s khi don job, trong khi diet con thi job tu ket thuc va script thoat ngay.
    $killedPid = $null
    if (Test-Path $pidFile) {
      $rawPid = Get-Content -Path $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
      $jobPid = 0
      if ($rawPid -and [int]::TryParse(([string]$rawPid).Trim(), [ref]$jobPid)) {
        $jobProc = Get-Process -Id $jobPid -ErrorAction SilentlyContinue
        if ($jobProc -and $jobProc.ProcessName -eq "powershell") {
          $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $jobPid" -ErrorAction SilentlyContinue)
          foreach ($c in $children) {
            & taskkill.exe /PID $c.ProcessId /T /F | Out-Null
            $killedPid = $c.ProcessId
          }
          if ($killedPid) {
            $waitStop = [Diagnostics.Stopwatch]::StartNew()
            while ((Get-Process -Id $killedPid -ErrorAction SilentlyContinue) -and $waitStop.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 200 }
          }
        }
      }
    }
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
    $sw.Stop()
    # Write-Host vi $r = Invoke-OpenCode gom het Write-Output cua ham vao ket qua,
    # khong hien ra console; dong TIMEOUT phai luon thay duoc.
    if ($killedPid) {
      Write-Host "TIMEOUT sau ${TimeoutSec}s - da giet tien trinh $killedPid va cac con - xem log: $logPath"
    } else {
      Write-Host "TIMEOUT sau ${TimeoutSec}s - xem log: $logPath"
    }
    return @{ code = 124; secs = [int]$sw.Elapsed.TotalSeconds; timedout = $true }
  }
  $code = Receive-Job $job
  Remove-Job $job -Force
  Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
  $sw.Stop()
  return @{ code = $code; secs = [int]$sw.Elapsed.TotalSeconds; timedout = $false }
}

# ---------- luot chinh ----------
# Chot chan cuoi: xac nhan lan nua phien/URL sap dung thuoc dung repo.
if ($Attach -ne "") { Assert-SessionRepo $Attach $Session }
$log = Join-Path $logDir "$base-$Tag.log"
$r   = Invoke-OpenCode $Model $Variant $log
$usedModels = @("$Model" + $(if ($Variant -ne "") { " ($Variant)" } else { "" }))
$changed   = & git status --porcelain

# ---------- fallback ----------
# Chi fallback khi luot truoc KHONG dong vao file nao. Neu da sua do dang thi
# giu nguyen de review; timeout/loi tham so cung khong dem sang model tiep.
$canFallback = (-not $changed) -and (-not $r.timedout) -and (-not $NoFallback) -and (-not (Test-ArgError $log))
if ($canFallback) {
  $quotaPath = Test-QuotaOrUnavailable $log
  $fallbackSequence = if ($quotaPath) { $quotaFallbacks } else { $noChangeFallbacks }
  $reason = if ($quotaPath) { "DeepSeek het quota/khong kha dung" } else { "luot truoc khong sinh thay doi" }
  $attempt = 0
  foreach ($candidate in $fallbackSequence) {
    if ($candidate.model -eq "") { continue }
    $attempt++
    Write-Output ""
    Write-Output "--- $reason -> fallback $attempt/$($fallbackSequence.Count): $($candidate.model) ---"
    $log = Join-Path $logDir "$base-$Tag-fallback-$attempt.log"
    $r = Invoke-OpenCode $candidate.model $candidate.variant $log
    $usedModels += "$($candidate.model)" + $(if ($candidate.variant -ne "") { " ($($candidate.variant))" } else { "" })
    $changed = & git status --porcelain
    if ($changed -or $r.timedout -or (Test-ArgError $log)) { break }
  }
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
      $LASTEXITCODE = 0
      $testsText = (Invoke-Expression ($testCommand + " 2>&1") | Out-String)
      $testExitCode = $LASTEXITCODE
      $testsRan  = $true
      if ($testExitCode -ne 0) { $testsFailed = $true }
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
Write-Output "MODELS DA THU: $($usedModels -join ' -> ')"
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

# Timeout la chung cuoc: luot bi cat ngang khong duoc coi la thanh cong chi vi
# model kip sua vai file.
if ($r.timedout) { exit 124 }
if ($testsFailed) { exit 8 }
if (Test-ArgError $log) {
  Write-Output "ARGERROR: opencode in usage/help - prompt khong toi noi nguyen ven, KHONG phai model tu choi task"
  exit 7
}
if (-not $changed) { exit 5 }
exit 0
