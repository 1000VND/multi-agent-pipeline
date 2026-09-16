<#
  codex-run.ps1 - Chay Codex CLI cho 1 task brief, ghi JSONL day du ra file,
  chi tra ve summary ngan cho Claude doc.

  Task moi tao Codex thread moi. -Resume tiep tuc dung thread cua dung cap
  phien Claude + task, tranh resume nham mot phien Codex khac.
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
if ($testCommand -eq "") { $testCommand = 'python -m unittest discover -s downloader -p "test_*.py"' }

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

# Task moi can worktree sach de git diff chi chua thay doi cua coder vua chay.
# Luot -Resume duoc phep nhin thay thay doi dang sua cua chinh task do.
$dirty = & git status --porcelain
if ($dirty -and -not $Resume) {
  Write-Output "BLOCKED: worktree chua sach. Commit hoac stash truoc khi giao task."
  Write-Output $dirty
  exit 3
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

if ($Key -eq "") { $Key = $env:CLAUDE_CODE_HOST_SESSION_ID }
if (-not $Key) { $Key = $env:CLAUDE_CODE_SESSION_ID }
if (-not $Key) { $Key = "no-claude-session" }
$mapKey = "${Key}::${TaskId}"

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
    task_id = $TaskId
    last_used = (Get-Date).ToString("s")
  }
  if ($tuiPid) { $record.tui_pid = [int]$tuiPid }
  $table[$mapKey] = $record
  $table | ConvertTo-Json -Depth 5 | Set-Content -Path $mapFile -Encoding UTF8
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

if ($Resume -and $Session -eq "") {
  $table = Read-MapTable
  if ($table.ContainsKey($mapKey)) { $Session = $table[$mapKey].codex_thread }
  if (-not $Session) {
    Write-Output "BLOCKED: khong co Codex thread da luu cho task $TaskId trong phien Claude nay."
    Write-Output "Dung -Session <thread-id> neu can resume mot thread cu cu the."
    exit 4
  }
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

  # Cua so TUI cu giu khoa thread; phai dong truoc khi resume cung thread do.
  # Kiem ten tien trinh truoc khi giet: PID co the da bi cap lai cho viec khac.
  if ($Resume) {
    $table = Read-MapTable
    if ($table.ContainsKey($mapKey) -and $table[$mapKey].tui_pid) {
      $oldPid = [int]$table[$mapKey].tui_pid
      $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
      if ($oldProc -and $oldProc.ProcessName -eq 'codex') {
        & taskkill.exe /PID $oldPid /T /F | Out-Null
        Write-Output "DONG CUA SO TUI CU (PID $oldPid) de resume duoc thread nay"
      }
    }
  }

  $t0 = Get-Date
  $t0Utc = $t0.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $tuiProc = Start-Process -FilePath $codexExe -ArgumentList $tuiArgsQuoted -PassThru
  # PS 5.1 chi doc duoc $tuiProc.ExitCode neu handle duoc giu truoc khi tien trinh thoat.
  [void]$tuiProc.Handle

  # Doi rollout cua dung phien (cwd phai khop), roi doi task_complete trong do.
  $sessionsRoot = Join-Path $env:USERPROFILE ".codex\sessions"
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
      if (-not $tuiProc.HasExited) {
        # Stop-Process khong du: TUI de tien trinh con, phai giet ca cay.
        & taskkill.exe /PID $tuiProc.Id /T /F | Out-Null
        $waitStop = [Diagnostics.Stopwatch]::StartNew()
        while (-not $tuiProc.HasExited -and $waitStop.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 200 }
      }
      $sw.Stop()
      if ($threadId) { Save-Session $threadId $tuiProc.Id }
      Write-Output "TIMEOUT sau ${TimeoutSec}s - da giet TUI PID $($tuiProc.Id)"
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
  Write-Output "CUA SO TUI VAN MO (PID $($tuiProc.Id)) - dong khi nao ban muon"
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
      & taskkill.exe /PID $proc.Id /T /F | Out-Null
      $waitStop = [Diagnostics.Stopwatch]::StartNew()
      while (-not $proc.HasExited -and $waitStop.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 200 }
      $sw.Stop()
      $threadId = Get-ThreadId $log
      if ($threadId) { Save-Session $threadId }
      Write-Output "TIMEOUT sau ${TimeoutSec}s - da giet codex PID $($proc.Id) - xem log: $log"
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
      $testsText = (Invoke-Expression ($testCommand + " 2>&1") | Out-String)
      $testsRan = $true
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
