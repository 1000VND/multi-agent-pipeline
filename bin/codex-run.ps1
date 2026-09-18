<#
  codex-run.ps1 - Chay Codex CLI cho 1 task brief, ghi JSONL day du ra file,
  chi tra ve summary ngan cho Claude doc.

  Moi phien Claude gan voi dung mot Codex thread. Cac lan giao task sau tu
  dong resume thread do; TUI cu duoc dong truoc khi mo lai de khong tich
  nhieu cua so. -FreshSession chi dung khi can tach sang thread Codex moi.
#>
param(
  [Parameter(Mandatory = $true)][string]$TaskFile,
  [string]$Model = "",
  [string]$ReasoningEffort = "",
  [string]$Tag = "",
  [switch]$Resume,
  [string]$Session = "",
  [string]$Key = "",       # ghi de khoa phien Claude (chu yeu de test)
  [string]$TaskId = "",    # ghi de task id khi ten brief khong theo convention
  [switch]$FreshSession,    # bo map hien tai, tao Codex thread moi cho phien Claude nay
  [switch]$NoTui,
  [switch]$Exec,           # duong lui: codex exec headless, khong cua so
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
$cfgCodex = $null
if ($pipelineConfig) { $cfgCodex = $pipelineConfig.model_policy.codex.default }
if (($Model -eq "") -and $cfgCodex.model) { $Model = [string]$cfgCodex.model }
if ($Model -eq "") { $Model = "gpt-5.6-luna" }
if (($ReasoningEffort -eq "") -and $cfgCodex.reasoning_effort) { $ReasoningEffort = [string]$cfgCodex.reasoning_effort }
if ($ReasoningEffort -eq "") { $ReasoningEffort = "xhigh" }
if (($TimeoutSec -le 0) -and $pipelineConfig.timeout_sec) { $TimeoutSec = [int]$pipelineConfig.timeout_sec }
if ($TimeoutSec -le 0) { $TimeoutSec = 1200 }
$testCommand = ""
if ($pipelineConfig) { $testCommand = [string]$pipelineConfig.test_command }

# Model bi cam dung de implement code (co the ghi de trong pipeline.config.json).
$forbiddenModels = @("gpt-5.6-sol", "gpt-6-astra")
if ($pipelineConfig -and $pipelineConfig.model_policy.codex.forbidden) {
  $forbiddenModels = @($pipelineConfig.model_policy.codex.forbidden)
}

if (-not (Test-Path $TaskFile)) { Write-Output "Khong thay task file: $TaskFile"; exit 2 }
$codexCommand = Get-Command codex -ErrorAction SilentlyContinue
if (-not $codexCommand) {
  Write-Output "BLOCKED: khong tim thay Codex CLI trong PATH."
  exit 4
}
$codexExe = $codexCommand.Source

# Chan model bi cam truoc khi lam bat cu viec gi (so sanh khong phan biet hoa thuong).
if ($forbiddenModels -contains $Model) {
  Write-Output "BLOCKED: model '$Model' bi cam dung de implement code (chinh sach model trong .pipeline/pipeline.config.json)"
  exit 2
}

$taskPath = (Resolve-Path $TaskFile).Path
$base = [IO.Path]::GetFileNameWithoutExtension($taskPath)
if ($TaskId -eq "") {
  $TaskId = $base -replace '\.fix-\d+$', '' -replace '\.run$', ''
}
if ($Tag -eq "") { $Tag = (Get-Date -Format "HHmmss") }

$stateDir = Join-Path $repo ".pipeline"
$logDir = Join-Path $stateDir "logs"
$mapFile = Join-Path $stateDir "codex-map.json"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

# ---------- run lock theo repo ----------
# Chi mot codex-run.ps1 duoc phep chay trong moi repo: luot sau phai thoat truoc
# khi kip dong TUI ma luot truoc dang can. Lock nam trong .pipeline/logs (da duoc
# ignore san) nen khong bao gio hien ra nhu mot thay doi Git cua repo dich.
$runLock = Join-Path $logDir "codex-run.lock"
$script:runLockAcquired = $false
$script:preserveRunLock = $false

function Get-RunLockOwner {
  if (-not (Test-Path $runLock)) { return $null }
  try { return (Get-Content -Raw -Encoding UTF8 $runLock | ConvertFrom-Json) } catch { return $null }
}

function Test-RunLockOwnerAlive($owner) {
  if (-not $owner) { return $false }
  $ownerPid = 0
  if (-not [int]::TryParse(([string]$owner.pid), [ref]$ownerPid) -or $ownerPid -le 0) { return $false }
  $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
  if (-not $proc) { return $false }
  # PID Windows co the bi tai su dung: so ca thoi diem khoi dong voi ban ghi.
  if ($owner.started) {
    try { return ($proc.StartTime.ToUniversalTime().ToString("o") -eq [string]$owner.started) } catch { return $true }
  }
  return $true
}

function Acquire-RunLock {
  $myStarted = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")
  $payload = @{ pid = $PID; started = $myStarted } | ConvertTo-Json -Compress
  for ($attempt = 0; $attempt -lt 4; $attempt++) {
    # Ghi ra file tam roi doi ten vao dich: lock luon xuat hien voi noi dung day
    # du, va chi mot tien trinh doi ten duoc (Move khong ghi de).
    $tmp = "{0}.{1}.{2}.tmp" -f $runLock, $PID, [guid]::NewGuid().ToString("N").Substring(0, 8)
    try {
      [IO.File]::WriteAllText($tmp, $payload, [Text.UTF8Encoding]::new($false))
      [IO.File]::Move($tmp, $runLock)
      $script:runLockAcquired = $true
      return
    } catch {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    $owner = Get-RunLockOwner
    if (Test-RunLockOwnerAlive $owner) {
      Write-Output "BLOCKED: mot runner Codex khac dang chay trong repo nay (PID $($owner.pid)). Cho luot do xong roi chay lai; khong dong TUI cua no."
      return
    }
    # Chu lock da chet: doi ten ban ghi cu ra ten rieng de chi mot runner thu hoi
    # duoc, tranh hai runner cung xoa roi cung tao de len nhau.
    $reclaim = "{0}.stale-{1}-{2}" -f $runLock, $PID, [guid]::NewGuid().ToString("N").Substring(0, 8)
    try {
      [IO.File]::Move($runLock, $reclaim)
      Remove-Item -LiteralPath $reclaim -Force -ErrorAction SilentlyContinue
    } catch { }
  }
  # Fail closed: khong bao gio chay ma khong co lock, du lock hong kieu gi.
  Write-Output "BLOCKED: khong gianh duoc run lock ($runLock). Khong chay khi chua co lock de tranh hai runner Codex chong nhau; kiem tra file/thu muc lock roi chay lai."
}

function Release-RunLock {
  # Timeout ma khong giet duoc Codex thi lock da duoc chuyen sang PID Codex.
  # Khong xoa no khi runner nay thoat, neu khong luot sau se chong len tien trinh cu.
  if ($script:preserveRunLock) { return }
  $owner = Get-RunLockOwner
  if (-not $owner) { return }
  $ownerPid = 0
  if (-not [int]::TryParse(([string]$owner.pid), [ref]$ownerPid) -or $ownerPid -ne $PID) { return }
  # Khong bao gio xoa lock khong phai cua chinh tien trinh nay.
  if ($owner.started) {
    try {
      if ([string]$owner.started -ne (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")) { return }
    } catch { return }
  }
  Remove-Item -LiteralPath $runLock -Force -ErrorAction SilentlyContinue
}

# taskkill co the that bai (vd tien trinh o session/permission khac). Khi do chuyen
# lock tu runner sang Codex dang con song. Runner sau se thay PID Codex va dung cho
# den khi tien trinh cu thuc su ket thuc, thay vi mo them mot TUI de chong len no.
function Preserve-RunLockForProcess($proc) {
  if (-not $proc) { return $false }
  $child = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
  if (-not $child) { return $false }
  $childStarted = Get-ProcessStartTime $child
  if (-not $childStarted) { return $false }

  $owner = Get-RunLockOwner
  $ownerPid = 0
  if (-not $owner -or -not [int]::TryParse(([string]$owner.pid), [ref]$ownerPid) -or $ownerPid -ne $PID) {
    return $false
  }

  $payload = @{ pid = $child.Id; started = $childStarted; retained_for = "codex-timeout" } |
    ConvertTo-Json -Compress
  $tmp = "{0}.{1}.{2}.tmp" -f $runLock, $PID, [guid]::NewGuid().ToString("N").Substring(0, 8)
  try {
    [IO.File]::WriteAllText($tmp, $payload, [Text.UTF8Encoding]::new($false))
    try {
      # Replace la atomic tren NTFS; fallback chi dung khi filesystem khong ho tro.
      [IO.File]::Replace($tmp, $runLock, $null)
    } catch {
      [IO.File]::WriteAllText($runLock, $payload, [Text.UTF8Encoding]::new($false))
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    $script:preserveRunLock = $true
    return $true
  } catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return $false
  }
}

# taskkill ghi loi ra stderr; voi ErrorActionPreference=Stop phai ha tam xuong
# Continue de loi kill khong lam vo timeout/cleanup va che mat trang thai that.
function Stop-ManagedProcessTree($targetPid) {
  $previousEAP = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & taskkill.exe /PID $targetPid /T /F 2>&1 | Out-Null
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousEAP
  }
}

Acquire-RunLock
if (-not $script:runLockAcquired) { exit 10 }

try {

# Task moi can worktree sach de git diff chi chua thay doi cua coder vua chay.
# Luot -Resume duoc phep nhin thay thay doi dang sua cua chinh task do.
$dirty = & git status --porcelain
if ($dirty -and -not $Resume) {
  Write-Output "BLOCKED: worktree chua sach. Commit hoac stash truoc khi giao task."
  Write-Output $dirty
  exit 3
}

# -Key la duong ghi de cho nguoi goi ngoai Claude Code. Khong co ca ba nguon thi
# khong the gan Codex thread vao dung phien; dung chung mot khoa se tron lich su
# cua nhieu lan chay khac nhau nen phai tu choi chay.
if ($Key -eq "") { $Key = $env:CLAUDE_CODE_HOST_SESSION_ID }
if (-not $Key) { $Key = $env:CLAUDE_CODE_SESSION_ID }
if (-not $Key) {
  Write-Output "BLOCKED: khong xac dinh duoc phien Claude (CLAUDE_CODE_HOST_SESSION_ID/CLAUDE_CODE_SESSION_ID deu trong). Chay ngoai Claude Code thi truyen -Key <ten-phien> de khong tron lich su Codex."
  exit 11
}
$mapKey = $Key
$tuiMapKey = "__pipeline_tui__" # ban ghi toan repo trong codex-map.json da duoc ignore

function Read-Json($path) {
  if (-not (Test-Path $path)) { return $null }
  try { return (Get-Content -Raw -Encoding UTF8 $path | ConvertFrom-Json) } catch { return $null }
}

function Read-MapTable {
  $map = Read-Json $mapFile
  $table = @{}
  if ($map) { $map.PSObject.Properties | ForEach-Object { $table[$_.Name] = $_.Value } }
  return $table
}

function Save-Session($threadId, $tuiPid = $null) {
  if (-not $threadId) { return }
  $table = Read-MapTable
  $record = @{
    codex_thread = $threadId
    claude_session_id = $env:CLAUDE_CODE_SESSION_ID
    session_key = $Key
    last_task_id = $TaskId
    last_used = (Get-Date).ToString("s")
  }
  if ($tuiPid) { $record.tui_pid = [int]$tuiPid }
  $table[$mapKey] = $record
  $table | ConvertTo-Json -Depth 5 | Set-Content -Path $mapFile -Encoding UTF8
}

# Thoi diem khoi dong tien trinh (UTC, round-trip) de phan biet PID bi tai su
# dung; tra ve $null neu khong doc duoc.
function Get-ProcessStartTime($proc) {
  try { return $proc.StartTime.ToUniversalTime().ToString("o") } catch { return $null }
}

function Close-ManagedTui {
  $table = Read-MapTable
  if (-not $table.ContainsKey($tuiMapKey)) { return }
  $win = $table[$tuiMapKey]
  if (-not $win -or -not $win.pid) { return }
  $oldPid = [int]$win.pid
  $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
  # Chi dong tien trinh Codex ma runner da ghi lai; PID Windows co the bi tai su
  # dung nen phai khop ca ten tien trinh lan thoi diem khoi dong.
  if ($oldProc -and $oldProc.ProcessName -eq 'codex') {
    if (-not $win.proc_started) {
      # Ban ghi cu (truoc O2) khong co thoi diem khoi dong: khong du can cu de
      # giet, co the trung PID voi phien Codex khac cua nguoi dung. Bo qua ban
      # ghi va de nguoi dung tu dong cua so cu.
      Write-Output "CANH BAO: ban ghi TUI cu (PID $oldPid) khong co thoi diem khoi dong - khong dong de tranh giet nham; cua so cu co the con mo"
    } else {
      $actual = Get-ProcessStartTime $oldProc
      if ($actual -and ($actual -eq [string]$win.proc_started)) {
        [void](Stop-ManagedProcessTree $oldPid)
        $waitStop = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-Process -Id $oldPid -ErrorAction SilentlyContinue) -and $waitStop.Elapsed.TotalSeconds -lt 5) {
          Start-Sleep -Milliseconds 200
        }
        if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
          Write-Output "BLOCKED: khong dong duoc TUI Codex cu (PID $oldPid). Khong mo TUI moi de tranh hai phien chong nhau; dong PID nay thu cong roi chay lai."
          exit 10
        }
        Write-Output "DONG CUA SO TUI CU (PID $oldPid) de chi con mot cua so Codex"
      }
      # Thoi diem khoi dong khac => PID da bi tai su dung, khong giet.
    }
  }
  $table.Remove($tuiMapKey)
  $table | ConvertTo-Json -Depth 5 | Set-Content -Path $mapFile -Encoding UTF8
}

function Save-ManagedTui($tuiProcessId) {
  $table = Read-MapTable
  $record = @{ pid = [int]$tuiProcessId; session_key = $Key; started = (Get-Date).ToString("s") }
  $proc = Get-Process -Id $tuiProcessId -ErrorAction SilentlyContinue
  if ($proc) {
    $procStart = Get-ProcessStartTime $proc
    if ($procStart) { $record.proc_started = $procStart }
  }
  $table[$tuiMapKey] = $record
  $table | ConvertTo-Json -Depth 5 | Set-Content -Path $mapFile -Encoding UTF8
}

# Ban do cu dung khoa "<phien Claude>::<task>". Doc no mot lan de cac phien
# dang do khong bi mat lich su, sau do Save-Session se chuyen no sang khoa moi.
function Get-MappedSession {
  $table = Read-MapTable
  if ($table.ContainsKey($mapKey) -and $table[$mapKey].codex_thread) {
    return [string]$table[$mapKey].codex_thread
  }
  $legacy = @(
    $table.GetEnumerator() |
      Where-Object { $_.Value.session_key -eq $Key -and $_.Value.codex_thread } |
      Sort-Object { $_.Value.last_used } -Descending |
      Select-Object -First 1
  )
  if ($legacy.Count -gt 0) { return [string]$legacy[0].Value.codex_thread }
  return $null
}

function Get-EventValues($logPath) {
  if (-not (Test-Path $logPath)) { return @() }
  $events = @()
  Get-Content -Encoding UTF8 $logPath | ForEach-Object {
    try { $events += ($_ | ConvertFrom-Json) } catch { }
  }
  return $events
}

function Get-ThreadId($logPath) {
  $event = Get-EventValues $logPath |
    Where-Object { $_.type -eq "thread.started" -and $_.thread_id } |
    Select-Object -First 1
  if ($event) { return $event.thread_id }
  return $null
}

function Get-FinalMessage($logPath) {
  $event = Get-EventValues $logPath |
    Where-Object { $_.type -eq "item.completed" -and $_.item.type -eq "agent_message" } |
    Select-Object -Last 1
  if ($event) { return $event.item.text }
  return $null
}

function Get-FileChangeCount($logPath) {
  $items = Get-EventValues $logPath |
    Where-Object { $_.type -eq "item.completed" -and $_.item.type -eq "file_change" }
  return @($items).Count
}

function Get-NativeThreadId($logPath) {
  $event = Get-EventValues $logPath |
    Where-Object { $_.type -eq "session_meta" -and $_.payload.session_id } |
    Select-Object -First 1
  if ($event) { return [string]$event.payload.session_id }
  return $null
}

function Get-FirstJsonLine($path) {
  try {
    $line = Get-Content -Path $path -TotalCount 1 -Encoding UTF8
    if ($line) { return ($line | ConvertFrom-Json) }
  } catch { }
  return $null
}

# Tim rollout cua dung phien: moi nhat, sinh sau $since, va session_meta.cwd
# dung bang repo. Khong duoc bo dieu kien cwd: nguoi dung co the dang chay
# mot phien Codex khac cung luc.
function Find-Rollout($rootDir, $since, $expectedCwd) {
  if (-not (Test-Path $rootDir)) { return $null }
  $files = Get-ChildItem -Path $rootDir -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt $since } |
    Sort-Object LastWriteTime -Descending
  foreach ($file in $files) {
    $meta = Get-FirstJsonLine $file.FullName
    if ($meta -and $meta.type -eq "session_meta" -and $meta.payload.cwd) {
      $cwd = ([string]$meta.payload.cwd).Replace('/', '\').TrimEnd('\')
      if ($cwd -ieq $expectedCwd) { return $file }
    }
  }
  return $null
}

# In 20 dong cuoi log (va stderr neu co) toi da mot lan cho moi luot chay.
$script:logTailShown = $false
function Write-LogTail($logPath) {
  if ($script:logTailShown) { return }
  $script:logTailShown = $true
  if (Test-Path $logPath) { Get-Content $logPath -Tail 20 }
  $errPath = "$logPath.err"
  if ((Test-Path $errPath) -and ((Get-Item $errPath).Length -gt 0)) {
    Write-Output "--- stderr ---"
    Get-Content $errPath -Tail 20
  }
}

if ($FreshSession) {
  # Fresh co uu tien hon -Resume/-Session: day la loi thoat co chu dich cho
  # escalation, khong duoc vo tinh quay lai chuoi suy luan cu.
  $Session = ""
  $Resume = $false
}
if ((-not $FreshSession) -and $Session -eq "") {
  $Session = Get-MappedSession
}
if ($Resume -and -not $Session) {
    Write-Output "BLOCKED: khong co Codex thread da luu cho task $TaskId trong phien Claude nay."
    Write-Output "Dung -Session <thread-id> neu can resume mot thread cu cu the."
    exit 4
}
# -Resume giu tuong thich voi lenh cu. Con binh thuong, co map cua phien Claude
# cung phai resume de tat ca task trong phien do dung chung mot Codex thread.
if ($Session -and -not $FreshSession) { $Resume = $true }

function Write-TuiResumeHint($threadId) {
  if ($threadId) { Write-Output "TUI: codex resume $threadId" }
}

$head = & git rev-parse HEAD

# Mac dinh la TUI goc cua Codex. -Exec hoac -NoTui quay ve duong codex exec.
$useTui = ((-not $Exec) -and (-not $NoTui))

if ($useTui) {
  # ------------- che do TUI goc (mac dinh) -------------
  $log = Join-Path $logDir "$base-$Tag-native.jsonl"
  # Prompt chi tro toi file brief, khong nhet ca brief qua dong lenh.
  $prompt = 'Doc file "{0}" roi thuc hien dung theo do. Xong thi dung lai, khong hoi them.' -f $taskPath
  $tuiArgs = @()
  if ($Resume) { $tuiArgs += @("resume", $Session) }
  $tuiArgs += @("--approve-for-me", "-C", $repo)
  if ($Model -ne "") { $tuiArgs += @("--model", $Model) }
  if ($ReasoningEffort -ne "") { $tuiArgs += @("--config", "model_reasoning_effort=$ReasoningEffort") }
  $tuiArgs += $prompt
  # PS 5.1 noi cac phan tu -ArgumentList bang dau cach va khong tu boc nhay;
  # escape ca nhay kep ben trong (prompt co nhay quanh duong dan brief).
  $tuiArgsQuoted = @($tuiArgs | ForEach-Object {
    if ($_ -match '\s') { '"{0}"' -f ($_ -replace '"', '\"') } else { $_ }
  })

  $label = if ($Model -ne "") { "$Model (effort $ReasoningEffort)" } else { "Codex CLI default" }
  $mode = if ($Resume) { "TUI resume $Session" } else { "TUI new thread" }
  $coderLabel = "codex (TUI)"
  Write-Output "=> codex $label | $mode | task=$base | log=$log"
  Write-Output "TUI: cua so Codex goc"

  # Trang thai worktree truoc khi chay, de biet luot nay co sua gi khong.
  $beforeStatus = (& git status --porcelain) -join "`n"

  # Moi repo chi giu mot cua so TUI do runner mo, bat ke no thuoc phien Claude
  # nao. Phai dong no truoc khi resume/tao moi, neu khong Windows se tich cua so.
  Close-ManagedTui

  $t0 = Get-Date
  $t0Utc = $t0.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $tuiProc = Start-Process -FilePath $codexExe -ArgumentList $tuiArgsQuoted -PassThru
  Save-ManagedTui $tuiProc.Id
  # PS 5.1 chi doc duoc $tuiProc.ExitCode neu handle duoc giu truoc khi tien trinh thoat.
  [void]$tuiProc.Handle

  # Doi rollout cua dung phien (cwd phai khop), roi doi task_complete trong do.
  # Codex co the dung profile rieng qua CODEX_HOME; USERPROFILE chi la mac dinh.
  $codexHome = [string]$env:CODEX_HOME
  if (-not $codexHome) {
    $profileHome = [string]$env:USERPROFILE
    if (-not $profileHome) { $profileHome = [Environment]::GetFolderPath("UserProfile") }
    $codexHome = Join-Path $profileHome ".codex"
  }
  $sessionsRoot = Join-Path $codexHome "sessions"
  $repoNorm = $repo.Replace('/', '\').TrimEnd('\')
  $rollout = $null
  $warnedNoRollout = $false
  $taskComplete = $false
  $lastAgentMessage = $null
  $nativeFileChangeCount = 0
  $hardError = $false
  $threadId = $null
  $exitedHandled = $false

  while (-not $taskComplete) {
    if (-not $rollout) {
      $rollout = Find-Rollout $sessionsRoot $t0 $repoNorm
      if ($rollout) {
        $threadId = Get-NativeThreadId $rollout.FullName
        if ($threadId) { Save-Session $threadId $tuiProc.Id }
      } elseif ((-not $warnedNoRollout) -and ($sw.Elapsed.TotalSeconds -ge 90)) {
        Write-Output "CHUA THAY PHIEN CODEX NAO - cua so TUI co the dang hoi xac nhan tin cay thu muc, hay bam Yes trong cua so do"
        $warnedNoRollout = $true
      }
    } else {
      # Rollout cua luot resume chua ca cac luot cu; chi tinh event moi sau $t0
      # de khong nham task_complete cua luot truoc la cua luot nay.
      $events = @(Get-EventValues $rollout.FullName | Where-Object {
        [string]::CompareOrdinal([string]$_.timestamp, $t0Utc) -gt 0
      })
      $fileChanges = @($events | Where-Object {
        $_.type -eq "event_msg" -and $_.payload.type -eq "item_completed" -and
        ([string]$_.payload.item.type -match '^file_?change$')
      }).Count
      if ($fileChanges -gt $nativeFileChangeCount) { $nativeFileChangeCount = $fileChanges }
      if (@($events | Where-Object { $_.type -eq "event_msg" -and ([string]$_.payload.type -match 'error') }).Count -gt 0) {
        $hardError = $true
      }
      $doneEvent = $events | Where-Object { $_.type -eq "event_msg" -and $_.payload.type -eq "task_complete" } | Select-Object -Last 1
      if ($doneEvent) {
        $taskComplete = $true
        $lastAgentMessage = [string]$doneEvent.payload.last_agent_message
      }
    }
    if ($taskComplete) { break }
    if ($tuiProc.HasExited) {
      if (-not $exitedHandled) {
        # TUI vua thoat: cho 3s roi doc lai rollout mot lan truoc khi ket luan.
        Start-Sleep -Seconds 3
        $exitedHandled = $true
        continue
      }
      Write-Output "CODEXERROR: cua so TUI thoat som (exit=$($tuiProc.ExitCode)) - thread co the dang mo o cua so khac, hoac lenh resume bi tu choi"
      if ($rollout) { Write-LogTail $rollout.FullName }
      exit 7
    }
    if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
      # Chi giet khi con song: taskkill vao PID da chet chi in rac ra output.
      $stopped = $tuiProc.HasExited
      if (-not $tuiProc.HasExited) {
        # Stop-Process khong du: TUI de tien trinh con, phai giet ca cay.
        [void](Stop-ManagedProcessTree $tuiProc.Id)
        $waitStop = [Diagnostics.Stopwatch]::StartNew()
        while (-not $tuiProc.HasExited -and $waitStop.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 200 }
        $stopped = $tuiProc.HasExited
      }
      $sw.Stop()
      if ($threadId) { Save-Session $threadId $tuiProc.Id }
      if ($stopped) {
        Write-Output "TIMEOUT sau ${TimeoutSec}s - da giet TUI PID $($tuiProc.Id)"
      } elseif (Preserve-RunLockForProcess $tuiProc) {
        Write-Output "TIMEOUT sau ${TimeoutSec}s - KHONG giet duoc TUI PID $($tuiProc.Id); giu run lock den khi no tu thoat"
      } else {
        Write-Output "TIMEOUT sau ${TimeoutSec}s - KHONG giet duoc TUI PID $($tuiProc.Id), va KHONG the giu run lock; can dong tien trinh nay thu cong truoc khi chay lai"
      }
      exit 124
    }
    Start-Sleep -Seconds 2
  }

  $sw.Stop()
  # Giu ban ghi rieng trong .pipeline thay vi chi tro vao ~/.codex.
  if ($rollout) { Copy-Item -Path $rollout.FullName -Destination $log -Force }
  if (-not $threadId) { $threadId = Get-NativeThreadId $log }
  if ($threadId) { Save-Session $threadId $tuiProc.Id }
  $code = 0
  Write-Output "CUA SO TUI DANG MO (PID $($tuiProc.Id)) - luot sau se tu dong dong va mo lai cung thread"
} else {
  # ------------- duong lui: codex exec headless (nhu truoc) -------------
  $log = Join-Path $logDir "$base-$Tag-codex.jsonl"
  $coderLabel = "codex"

  $codexArgs = @("exec")
  if ($Resume) {
    $codexArgs += @("resume", "--json")
    if ($Model -ne "") { $codexArgs += @("--model", $Model) }
    if ($ReasoningEffort -ne "") { $codexArgs += @("--config", "model_reasoning_effort=$ReasoningEffort") }
    $codexArgs += @($Session, "-")
  } else {
    $codexArgs += @("--json", "--approve-for-me", "--cd", $repo)
    if ($Model -ne "") { $codexArgs += @("--model", $Model) }
    if ($ReasoningEffort -ne "") { $codexArgs += @("--config", "model_reasoning_effort=$ReasoningEffort") }
    $codexArgs += "-"
  }

  $label = if ($Model -ne "") { "$Model (effort $ReasoningEffort)" } else { "Codex CLI default" }
  $mode = if ($Resume) { "resume $Session" } else { "new thread" }
  Write-Output "=> codex $label | $mode | task=$base | log=$log"

  # -Exec va -NoTui deu chay headless, khong mo cua so nao.
  Write-Output "MODE: headless (khong mo cua so) - dung mac dinh de thay TUI Codex goc"
  if ($Session) {
    Write-TuiResumeHint $Session
  } else {
    Write-Output "TUI: se in lenh codex resume sau khi Codex tao thread moi"
  }

  # PS 5.1 noi cac phan tu -ArgumentList bang dau cach va khong tu boc nhay;
  # tham so co khoang trang (vd --cd <duong dan>) phai duoc boc nhay san.
  $codexArgsQuoted = @($codexArgs | ForEach-Object {
    if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
  })

  # Trang thai worktree truoc khi chay, de biet luot nay co sua gi khong.
  $beforeStatus = (& git status --porcelain) -join "`n"

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $errLog = "$log.err"
  # Start-Process cho PID that va redirect thang ra file, khong can StreamWriter.
  # Brief di vao stdin dang byte goc nen khong con rui ro encoding.
  $proc = Start-Process -FilePath $codexExe -ArgumentList $codexArgsQuoted -PassThru -NoNewWindow `
    -WorkingDirectory $repo `
    -RedirectStandardInput $taskPath `
    -RedirectStandardOutput $log `
    -RedirectStandardError $errLog

  # PS 5.1 chi doc duoc $proc.ExitCode neu handle duoc giu truoc khi tien trinh thoat.
  [void]$proc.Handle

  # Cho codex xong; luu thread ngay khi thay thread.started de -Resume dung duoc
  # ke ca khi luot nay bi giet giua chung.
  $saved = $false
  while (-not $proc.HasExited) {
    if (-not $saved) {
      $t = Get-ThreadId $log
      if ($t) { Save-Session $t; $saved = $true }
    }
    if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
      # Stop-Process khong du: codex de tien trinh con, phai giet ca cay.
      [void](Stop-ManagedProcessTree $proc.Id)
      $waitStop = [Diagnostics.Stopwatch]::StartNew()
      while (-not $proc.HasExited -and $waitStop.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 200 }
      $sw.Stop()
      $threadId = Get-ThreadId $log
      if ($threadId) {
        Save-Session $threadId
        if ($threadId -ne $Session) { Write-TuiResumeHint $threadId }
      }
      if ($proc.HasExited) {
        Write-Output "TIMEOUT sau ${TimeoutSec}s - da giet codex PID $($proc.Id) - xem log: $log"
      } elseif (Preserve-RunLockForProcess $proc) {
        Write-Output "TIMEOUT sau ${TimeoutSec}s - KHONG giet duoc codex PID $($proc.Id); giu run lock den khi no tu thoat - xem log: $log"
      } else {
        Write-Output "TIMEOUT sau ${TimeoutSec}s - KHONG giet duoc codex PID $($proc.Id), va KHONG the giu run lock; can dong tien trinh nay thu cong truoc khi chay lai - xem log: $log"
      }
      exit 124
    }
    Start-Sleep -Seconds 1
  }

  $code = $proc.ExitCode
  # Khong doc duoc exit code (vd proc khong tra ve gi) -> coi nhu -1; Codex co the thoat ma am.
  $codeNumber = 0
  if (-not [int]::TryParse(([string]$code), [ref]$codeNumber)) { $codeNumber = -1 }
  $code = $codeNumber
  $sw.Stop()

  $threadId = Get-ThreadId $log
  if ($threadId) {
    Save-Session $threadId
    if ($threadId -ne $Session) { Write-TuiResumeHint $threadId }
  } elseif ($Resume -and $Session -and $code -eq 0) {
    Save-Session $Session
  }
}

$changed = & git status --porcelain
$stat = & git diff --stat

# Tin hieu "luot nay co lam gi": log file_change bat duoc viec sua lai file dang do
# (porcelain khong doi), con so sanh porcelain bat duoc viec sua bang lenh shell
# (log khong co file_change). Phai dung hop ca hai.
$afterStatus = ($changed) -join "`n"
if ($useTui) {
  $didWork = ($nativeFileChangeCount -gt 0) -or ($afterStatus -ne $beforeStatus)
} else {
  $didWork = ((Get-FileChangeCount $log) -gt 0) -or ($afterStatus -ne $beforeStatus)
}

# Codex thoat khac 0 la runner/CLI hong, khong phai model tu choi task.
# TUI khong tra exit code, nen chi bao loi khi rollout co event bao error ma
# luot nay khong sua duoc gi - khong tu bia ma 7.
if ($useTui) {
  if ($hardError -and (-not $didWork)) {
    Write-Output "CODEXERROR: rollout bao loi va luot nay khong sua gi - KHONG phai model tu choi task, xem log"
    Write-LogTail $log
  }
} elseif ($code -ne 0) {
  Write-Output "CODEXERROR: codex thoat voi ma $code - KHONG phai model tu choi task, xem log"
  Write-LogTail $log
}

# Giong runner OpenCode: co thay doi thi chay full suite de Claude co tin hieu som.
# Claude van phai tu chay test muc tieu va full suite trong buoc review.
$testsRan = $false
$testsFailed = $false
$testsTail = @()
if ($changed) {
  if ($testCommand -ne "") {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      # 2>&1 phai nam trong chuoi IEX: redirect ben ngoai khong bat duoc stderr cua lenh native.
      $LASTEXITCODE = 0
      $testsText = (Invoke-Expression ($testCommand + " 2>&1") | Out-String)
      $testExitCode = $LASTEXITCODE
      $testsRan = $true
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
Write-Output "--- KET QUA ($([int]$sw.Elapsed.TotalSeconds)s, exit=$code) ---"
Write-Output "CODER: $coderLabel"
Write-Output "MODEL DA DUNG: $label"
Write-Output "BASE_COMMIT: $head"
if ($threadId) { Write-Output "CODEX_THREAD: $threadId" }
Write-Output "FILES THAY DOI:"
if ($changed) { Write-Output $changed } else { Write-Output "  (KHONG CO FILE NAO THAY DOI - coi nhu task that bai)" }
if ((-not $didWork) -and $changed) { Write-Output "  LUOT NAY KHONG SUA GI (cac thay doi dang co la cua luot truoc)" }
Write-Output ""
Write-Output "DIFFSTAT:"
Write-Output $stat
if ($changed) {
  Write-Output ""
  if ($testsRan) {
    Write-Output "TESTS:"
    Write-Output $testsTail
    if ($testsFailed) { Write-Output "TESTS: FAILED - Claude can review chi tiet" }
  } elseif ($testCommand -eq "") {
    Write-Output "TESTS: khong co test_command trong .pipeline/pipeline.config.json - bo qua"
  } else {
    Write-Output "TESTS: khong chay duoc test_command - bo qua"
  }
}

if ($useTui) { $finalMessage = $lastAgentMessage } else { $finalMessage = Get-FinalMessage $log }
Write-Output ""
Write-Output "--- TOM TAT CUOI CUA CODEX ---"
if ($finalMessage) { Write-Output $finalMessage } else { Write-Output "  (khong doc duoc final agent message; xem full log)"; Write-LogTail $log }
Write-Output "--- (full log: $log) ---"

if ($testsFailed) { exit 8 }
if ($useTui) {
  if ($hardError -and (-not $didWork)) { exit 7 }
} elseif (($code -ne 0) -and (-not $didWork)) { exit 7 }
if (-not $didWork) { exit 5 }
exit 0

} finally {
  # Moi duong thoat (exit thuong, exit loi, timeout) deu phai tra run lock.
  if ($script:runLockAcquired) { Release-RunLock }
}
