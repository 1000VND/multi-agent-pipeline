<#
  oc-run.ps1 - Chay opencode cho 1 task brief, ghi full log ra file,
  chi tra ve summary ngan cho Claude doc.
  Muc dich: Claude khong phai nuot toan bo stdout cua opencode.

  Model mac dinh: deepseek-v4.1-flash (variant max).
  Fallback: chuoi model trong config, tach rieng khi khong sua file va khi het quota.
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
  [string]$Key = "",      # khoa phien Claude khi khong co CLAUDE_CODE_*_SESSION_ID
  [switch]$NewTui,        # co cu: TUI gio bat mac dinh, tham so nay khong con tac dung rieng
  [switch]$FreshTui,      # kem -NewTui: ep tao phien opencode moi thay vi dung lai phien cu
  [switch]$NoTui,         # tat han cua so TUI (mac dinh la bat)
  [int]$TimeoutSec = 0,
  [string]$OpenCodeCmd = "" # test/diagnostic: duong dan day du toi opencode.cmd
)

$ErrorActionPreference = "Stop"
$fallbackOverrideRequested = $PSBoundParameters.ContainsKey("Fallback")
$initialSession = $Session
if ([string]::IsNullOrWhiteSpace($Key)) { $Key = $env:CLAUDE_CODE_HOST_SESSION_ID }
if ([string]::IsNullOrWhiteSpace($Key)) { $Key = $env:CLAUDE_CODE_SESSION_ID }
if ([string]::IsNullOrWhiteSpace($Key)) {
  Write-Output "BLOCKED: khong co CLAUDE_CODE_*_SESSION_ID. Truyen -Key <claude-session-id> de tranh lan lich su."
  exit 11
}
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

# OS-owned exclusive handle covers session selection, all fallback attempts and
# verification. A crash releases the handle; never delete/reclaim the lock file.
$logDir = Join-Path $repo '.pipeline\logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$runLockHandle = $null
$pipelineGuard = $null
try {
  . (Join-Path $PSScriptRoot 'pipeline-runtime.ps1')
  $pipelineGuard = Enter-PipelineRun $repo 'opencode'
  $runLockHandle = [IO.File]::Open((Join-Path $logDir 'opencode-run.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch {
  if ($pipelineGuard) { $pipelineGuard.Dispose() }
  Write-Output "BLOCKED: khong gianh duoc run lock cua repo: $($_.Exception.Message)"
  exit 10
}
try {

# Compare content, not just porcelain: a resumed task may modify a file that
# was already dirty. Git supplies NUL-separated paths, including untracked files.
function Get-WorktreeFingerprint {
  $rawPaths = (& git -C $repo -c core.quotepath=false ls-files -z --modified --deleted --others --exclude-standard) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw 'Cannot snapshot worktree paths.' }
  $stagedPaths = (& git -C $repo -c core.quotepath=false diff --cached --name-only -z) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw 'Cannot snapshot index paths.' }
  $rawPaths += "`0" + $stagedPaths
  $entries = foreach ($relative in @($rawPaths -split "`0" | Where-Object { $_ } | Sort-Object -Unique)) {
    $path = Join-Path $repo $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      '{0}:{1}' -f $relative, (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    } elseif (Test-Path -LiteralPath $path -PathType Container) {
      # A tracked submodule is a directory, not a file.
      '{0}:submodule:{1}:{2}' -f $relative, ((& git -C $path rev-parse HEAD) -join ''), ((& git -C $path status --porcelain) -join "`n")
    } else { '{0}:deleted' -f $relative }
  }
  $indexState = (& git -C $repo diff --cached --raw --no-abbrev) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw 'Cannot snapshot index state.' }
  return (($entries -join "`n") + "`nINDEX:`n" + $indexState)
}

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

# Check at every safe dispatch boundary, including fallback. Never interrupt
# an in-flight model request. Fresh/explicit Session applies only to the first
# dispatch, so fallback follows the newly active session after rollover.
$dispatchCount = 0
function Sync-OpenCodeSession {
  $oldSession = $script:Session
  $firstDispatch = $script:dispatchCount -eq 0
  $tuiArgs = @("-Key", $Key, "-Title", "Task $([IO.Path]::GetFileNameWithoutExtension($TaskFile))")
  if ($Attach -ne "") { $tuiArgs += @("-Url", $Attach) }
  if ($firstDispatch -and $initialSession) { $tuiArgs += @("-Session", $initialSession) }
  if ($firstDispatch -and $FreshTui) { $tuiArgs += "-Fresh" }
  if ($NoTui -or -not $firstDispatch) { $tuiArgs += "-NoWindow" }
  $tui = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "oc-tui.ps1") @tuiArgs
  $tuiCode = $LASTEXITCODE
  $tui | ForEach-Object { Write-Host $_ }
  $line = $tui | Where-Object { $_ -match "^SESSION=" } | Select-Object -Last 1
  $urlLine = $tui | Where-Object { $_ -match "^URL=" } | Select-Object -Last 1
  if ($tuiCode -ne 0) { Write-Host "BLOCKED: oc-tui.ps1 exit=$tuiCode"; exit $tuiCode }
  if (-not $line -or -not $urlLine) { throw 'oc-tui.ps1 khong tra ve session/URL hop le.' }
  $script:Session = $line -replace "^SESSION=", ""
  $script:Attach = $urlLine -replace "^URL=", ""
  $script:tuiHint = "opencode attach $($script:Attach) -s $($script:Session)"
  if ($NoTui -and $firstDispatch) { Write-Host "MODE: headless (khong mo cua so)" }
  # Print here as well for backwards-compatible helpers; host stream makes
  # the reconnect command visible while Invoke-OpenCode's result is captured.
  Write-Host "TUI: $($script:tuiHint)"
  if (-not $NoTui -and -not $firstDispatch -and $oldSession -ne $script:Session) {
    # User chose TUI: move the visible window to the replacement session too.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "oc-tui.ps1") `
      -Key $Key -Url $script:Attach -Session $script:Session | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
  $script:dispatchCount++
}

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
  foreach ($line in @(Get-Content -Path $logPath -TotalCount 5 -ErrorAction SilentlyContinue)) {
    try { $null = $line | ConvertFrom-Json -ErrorAction Stop; continue } catch { }
    if (($line -replace '\x1b\[[0-9;]*m', '') -match '^\s*opencode run \[message') { return $true }
  }
  return $false
}

function Test-OpenCodeApiError($logPath) {
  if (-not (Test-Path -LiteralPath $logPath)) { return $false }
  foreach ($line in @(Get-Content -LiteralPath $logPath -Encoding UTF8)) {
    try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    if ($event.type -eq 'error' -and $null -ne $event.error) { return $true }
  }
  return $false
}

# Chi dung chuoi quota khi CLI/API bao het quota, rate limit hoac model khong
# kha dung. Khong coi loi prompt/CLI la quota de tranh thu model khac vo ich.
function Test-QuotaOrUnavailable($logPath, $exitCode) {
  if (-not (Test-Path $logPath)) { return $false }
  $failurePattern = '(?i)(\bquota[ _-]*(exceeded|exhausted|limit|reached)\b|\b(exceeded|exhausted|insufficient)[ _-]*quota\b|\b(rate|usage)[ _-]*limit(ed|[ _-]*(exceeded|reached))?\b|too many requests|insufficient (credit|balance)|model .{0,100}\b(unavailable|not available)\b|\b429\b)'
  foreach ($line in @(Get-Content -Encoding UTF8 -LiteralPath $logPath)) {
    $line = $line -replace '\x1b\[[0-9;]*m', ''
    $errorText = $null
    try {
      $event = $line | ConvertFrom-Json -ErrorAction Stop
      # Never classify structured assistant text as an API failure.
      if ($event.type -eq 'error') { $errorText = $event.error | ConvertTo-Json -Depth 20 -Compress }
    } catch {
      # Formatted CLI logs: require an actual failed invocation as well as
      # an explicit error prefix. Ordinary prose mentioning quota is not enough.
      if ($null -ne $exitCode -and $exitCode -ne 0 -and $line -match '^\s*(Error\b|APIError\b|ERROR\b|HTTP\s+429\b)') { $errorText = $line }
    }
    if ($errorText -and $errorText -match $failurePattern) { return $true }
  }
  return $false
}

function Invoke-OpenCode($modelId, $variantName, $logPath) {
  Sync-OpenCodeSession
  Assert-SessionRepo $Attach $Session | ForEach-Object { Write-Host $_ }
  $ocArgs = @("run", "--auto", "--format", "json", "--model", $modelId)
  if ($variantName -ne "") { $ocArgs += @("--variant", $variantName) }
  if ($Attach  -ne "")     { $ocArgs += @("--attach", $Attach) }
  if ($Session -ne "")     { $ocArgs += @("--session", $Session) }
  if ($Resume)             { $ocArgs += "--continue" }

  $label = if ($variantName -ne "") { "$modelId (variant $variantName)" } else { $modelId }
  Write-Host "=> opencode $label | task=$base (stdin UTF-8) | log=$logPath"
  if ($Attach -ne "") { Write-Host "   xem live: $tuiHint" }
  $beforeFingerprint = Get-WorktreeFingerprint

  $sw = [Diagnostics.Stopwatch]::StartNew()
  # Job tu ghi PID cua no ra file trong TEMP de cha biet duong giet ca cay khi
  # het gio. Brief truyen qua stdin, khong nam trong argv: tranh gioi han 8191
  # ky tu cua opencode.cmd/cmd.exe va khong can tu escape dau nhay.
  $pidFile = Join-Path $env:TEMP ("oc-run-{0}-{1}.pid" -f $Tag, [guid]::NewGuid().ToString("N").Substring(0, 8))
  # stdout+stderr -> file. Timeout bang job de khong treo session.
  $job = Start-Job -ScriptBlock {
    param($a, $l, $cwd, $pf, $exe, $task)
    @{pid=$PID; started=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')} |
      ConvertTo-Json -Compress | Set-Content -LiteralPath $pf
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
    $pendingPath = Join-Path $logDir 'opencode-pending.json'
    $pending = @{ url=$Attach; session=$Session; repo=$repo; reason='timeout-unconfirmed'; created=(Get-Date).ToString('o'); clients=@() }
    $pending | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pendingPath -Encoding UTF8
    # Stop-Job chi giet job PowerShell, opencode.exe ma job de ra van song tiep.
    # Doc pid file, xac nhan dung job powershell (PID co the da bi cap lai cho
    # tien trinh khac), roi diet cay cac con cua no (opencode + con chau).
    # Khong taskkill thang vao job: job process bi giet cung lam PowerShell cho
    # them ~60s khi don job, trong khi diet con thi job tu ket thuc va script thoat ngay.
    $killedPid = $null
    $clientStopped = $false
    if (Test-Path $pidFile) {
      $jobOwner = $null
      try { $jobOwner = Get-Content -Raw -LiteralPath $pidFile | ConvertFrom-Json -ErrorAction Stop } catch { }
      $jobPid = 0
      if ($jobOwner -and [int]::TryParse([string]$jobOwner.pid, [ref]$jobPid)) {
        $jobProc = Get-Process -Id $jobPid -ErrorAction SilentlyContinue
        if ($jobProc -and $jobProc.ProcessName -eq 'powershell' -and $jobOwner.started -and
            $jobProc.StartTime.ToUniversalTime().ToString('o') -eq [string]$jobOwner.started) {
          $clientStopped = $true
          $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $jobPid" -ErrorAction SilentlyContinue)
          $pending.clients = @($children | ForEach-Object { @{pid=$_.ProcessId; started=$_.CreationDate} })
          $pending | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pendingPath -Encoding UTF8
          foreach ($c in $children) {
            $killEap = $ErrorActionPreference
            try { $ErrorActionPreference = 'Continue'; & taskkill.exe /PID $c.ProcessId /T /F 2>&1 | Out-Null; $killCode = $LASTEXITCODE }
            finally { $ErrorActionPreference = $killEap }
            if ($killCode -ne 0) { $clientStopped = $false }
            $killedPid = $c.ProcessId
          }
          if ($killedPid) {
            $waitStop = [Diagnostics.Stopwatch]::StartNew()
            while ((Get-Process -Id $killedPid -ErrorAction SilentlyContinue) -and $waitStop.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 200 }
            if (Get-Process -Id $killedPid -ErrorAction SilentlyContinue) { $clientStopped = $false }
          }
        }
      }
    }
    # Stop the dispatching job before accepting server idle, otherwise it could
    # submit a delayed prompt after abort. On kill denial keep the marker and
    # still attempt server abort before potentially slow job cleanup.
    if ($clientStopped) { Stop-Job $job -ErrorAction SilentlyContinue }
    $serverStopped = Stop-OpenCodeSession $Attach $Session $repo
    if (-not $clientStopped) { Stop-Job $job -ErrorAction SilentlyContinue }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
    if ($serverStopped -and $clientStopped) {
      Remove-Item -LiteralPath $pendingPath -Force
      Write-Host 'TIMEOUT: server da xac nhan dung session.'
    } else {
      Write-Host "BLOCKED: chua xac nhan dung ca client va session server; giu $pendingPath de chan ca hai lane."
    }
    $sw.Stop()
    # Write-Host vi $r = Invoke-OpenCode gom het Write-Output cua ham vao ket qua,
    # khong hien ra console; dong TIMEOUT phai luon thay duoc.
    if ($killedPid -and $clientStopped) {
      Write-Host "TIMEOUT sau ${TimeoutSec}s - da giet tien trinh $killedPid va cac con - xem log: $logPath"
    } else {
      Write-Host "TIMEOUT sau ${TimeoutSec}s - xem log: $logPath"
    }
    return @{ code = 124; secs = [int]$sw.Elapsed.TotalSeconds; timedout = $true; didWork = ((Get-WorktreeFingerprint) -ne $beforeFingerprint) }
  }
  $code = Receive-Job $job
  Remove-Job $job -Force
  Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
  $sw.Stop()
  return @{ code = $code; secs = [int]$sw.Elapsed.TotalSeconds; timedout = $false; didWork = ((Get-WorktreeFingerprint) -ne $beforeFingerprint) }
}

# ---------- luot chinh ----------
# Sync-OpenCodeSession va Assert-SessionRepo chay truoc moi dispatch.
$log = Join-Path $logDir "$base-$Tag.log"
$r   = Invoke-OpenCode $Model $Variant $log
$usedModels = @("$Model" + $(if ($Variant -ne "") { " ($Variant)" } else { "" }))
$changed   = & git status --porcelain

# ---------- fallback ----------
# Chi fallback khi luot truoc KHONG dong vao file nao. Neu da sua do dang thi
# giu nguyen de review; timeout/loi tham so cung khong dem sang model tiep.
$canFallback = (-not $changed) -and (-not $r.timedout) -and (-not $NoFallback) -and (-not (Test-ArgError $log))
if ($canFallback) {
  $quotaPath = Test-QuotaOrUnavailable $log $r.code
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
if ($changed -and -not $r.timedout) {
  if ($testCommand -ne "") {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      # 2>&1 phai nam trong chuoi IEX: redirect ben ngoai khong bat duoc stderr cua lenh native.
      $LASTEXITCODE = 0
      $testOutput = @(Invoke-Expression ("& { " + $testCommand + "`n} 2>&1"))
      $testsText = $testOutput | Out-String
      $testExitCode = $LASTEXITCODE
      $testsRan  = $true
      if ($testExitCode -ne 0) { $testsFailed = $true }
      # Native stderr may be a harmless warning with exit 0. PowerShell errors
      # are different: LASTEXITCODE remains 0 for Write-Error/missing commands.
      foreach ($item in $testOutput) {
        if ($item -is [Management.Automation.ErrorRecord] -and
            $item.FullyQualifiedErrorId -notmatch '^NativeCommandError') { $testsFailed = $true }
      }
    } catch {
      $testsRan = $true
      $testsFailed = $true
      $testsText = $_ | Out-String
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
if ($r.timedout) {
  Write-Output 'TESTS: khong chay verify sau timeout; phai xac nhan coder da dung truoc.'
} elseif ($changed) {
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
if ($null -eq $r.code -or $r.code -ne 0 -or (Test-OpenCodeApiError $log)) {
  Write-Output "CODERERROR: OpenCode CLI/API that bai (CLI exit=$($r.code)); giu thay doi de review."
  exit 7
}
if (-not $r.didWork) { exit 5 }
exit 0
} finally {
  if ($runLockHandle) { $runLockHandle.Dispose() }
  if ($pipelineGuard) { $pipelineGuard.Dispose() }
}
