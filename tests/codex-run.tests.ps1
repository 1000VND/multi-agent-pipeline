# Pester 3.4 tests cho bin/codex-run.ps1 (session identity + TUI PID safety).
#
# Moi test chay runner that trong mot git repo tam, voi mot fake codex.exe
# (winexe, khong cua so) dat len dau PATH. Khong goi Codex cloud, khong mo TUI
# that, khong cham vao repo cua package.

$script:packageRoot = Split-Path -Parent $PSScriptRoot
$script:runnerPath = Join-Path $script:packageRoot "bin\codex-run.ps1"
$script:fakeSourceDir = $null
$script:fakeSource = $null

$script:FakeCodeSource = @'
using System;
using System.IO;
using System.Threading;

class FakeCodex {
    static int Main(string[] args) {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        if (string.Equals(Path.GetFileName(Environment.GetCommandLineArgs()[0]), "taskkill.exe", StringComparison.OrdinalIgnoreCase)) {
            // Deterministic kill-denied fixture. Never sends a signal to a real process.
            File.AppendAllText(Path.Combine(baseDir, "taskkill-calls.txt"), string.Join("|", args) + Environment.NewLine);
            return 1;
        }
        string thread = Environment.GetEnvironmentVariable("FAKE_CODEX_THREAD");
        if (string.IsNullOrEmpty(thread)) { thread = "fake-default"; }
        for (int i = 0; i < args.Length; i++) {
            if (args[i] != "resume") { continue; }
            // TUI: "resume <thread> ..." ngay sau resume. Headless:
            // "exec resume --json ... <thread> -" nen thread la positional cuoi.
            if (i + 1 < args.Length && !args[i + 1].StartsWith("-")) {
                thread = args[i + 1];
            } else {
                for (int j = args.Length - 1; j >= 0; j--) {
                    if (args[j] != "-" && !args[j].StartsWith("-")) { thread = args[j]; break; }
                }
            }
            break;
        }
        string line = DateTime.UtcNow.ToString("o") + " ARGS=" + string.Join("|", args) + " THREAD=" + thread;
        File.AppendAllText(Path.Combine(baseDir, "calls.txt"), line + Environment.NewLine);
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"" + thread + "\"}");
        Console.Out.Flush();
        if (Environment.GetEnvironmentVariable("FAKE_CODEX_TOUCH") == "1") {
            File.WriteAllText(Path.Combine(Environment.CurrentDirectory, "fake-change.txt"), "changed");
        }
        string sessionsRoot = Environment.GetEnvironmentVariable("FAKE_CODEX_SESSIONS_ROOT");
        if (!string.IsNullOrEmpty(sessionsRoot)) {
            Directory.CreateDirectory(sessionsRoot);
            string cwd = Environment.CurrentDirectory.Replace("\\", "\\\\");
            string timestamp = DateTime.UtcNow.AddSeconds(1).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");
            string rollout = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"" + cwd + "\",\"session_id\":\"" + thread + "\"}}" + Environment.NewLine +
              "{\"timestamp\":\"" + timestamp + "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"done\"}}" + Environment.NewLine;
            File.WriteAllText(Path.Combine(sessionsRoot, "session-fake.jsonl"), rollout);
        }
        if (Environment.GetEnvironmentVariable("FAKE_CODEX_SLEEP") == "1") { Thread.Sleep(60000); }
        return 0;
    }
}
'@

function Get-CscPath {
  $candidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return $c }
  }
  $cmd = Get-Command csc.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# Build fake codex.exe bang csc.exe cua .NET Framework (winexe, khong cua so).
# Khong dung Add-Type -OutputType ...App vi PowerShell 7 khong ho tro.
function Get-FakeExeSource {
  if ($script:fakeSource -and (Test-Path $script:fakeSource)) { return $script:fakeSource }
  $csc = Get-CscPath
  if (-not $csc) { throw "Khong tim thay csc.exe (.NET Framework) de build fake codex." }
  $dir = Join-Path $env:TEMP ("codex-run-fake-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $csFile = Join-Path $dir "fake-codex.cs"
  $exe = Join-Path $dir "codex.exe"
  Set-Content -Path $csFile -Value $script:FakeCodeSource -Encoding UTF8
  & $csc /nologo /target:winexe "/out:$exe" $csFile 2>&1 | Out-Null
  if (-not (Test-Path $exe)) { throw "Build fake codex that bai bang $csc" }
  $script:fakeSourceDir = $dir
  $script:fakeSource = $exe
  return $exe
}

function New-Sandbox {
  $root = Join-Path $env:TEMP ("codex-run-test-" + [guid]::NewGuid().ToString("N"))
  $repo = Join-Path $root "repo"
  $fake = Join-Path $root "fake"
  $out = Join-Path $root "out"
  $codexHome = Join-Path $root "codex-home"
  New-Item -ItemType Directory -Force -Path $repo, $fake, $out, (Join-Path $codexHome "sessions") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $repo ".pipeline\bin"), (Join-Path $repo ".pipeline\tasks"), (Join-Path $repo ".pipeline\logs") | Out-Null
  Copy-Item -LiteralPath (Get-FakeExeSource) -Destination (Join-Path $fake "codex.exe") -Force
  Copy-Item -LiteralPath (Get-FakeExeSource) -Destination (Join-Path $fake "taskkill.exe") -Force
  Set-Content -Path (Join-Path $repo ".pipeline\tasks\t1.md") -Value "Brief test" -Encoding UTF8
  Copy-Item -LiteralPath (Join-Path $script:packageRoot "templates\pipeline.gitignore") -Destination (Join-Path $repo ".pipeline\.gitignore") -Force
  & git -C $repo init -q 2>$null | Out-Null
  & git -C $repo config user.email "t@example.com"
  & git -C $repo config user.name "tester"
  & git -C $repo add -A 2>$null | Out-Null
  & git -C $repo commit -qm "init" 2>$null | Out-Null
  return @{ root = $root; repo = $repo; fake = $fake; out = $out; codexHome = $codexHome }
}

function Assert-TestDirectory($path, $prefix) {
  $fullPath = [IO.Path]::GetFullPath([string]$path).TrimEnd('\')
  $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
  $parent = [IO.Path]::GetDirectoryName($fullPath)
  $leaf = [IO.Path]::GetFileName($fullPath)
  if (-not [IO.Path]::IsPathRooted($path) -or
      -not [string]::Equals($parent, $tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
      $leaf -notmatch ('^' + [regex]::Escape($prefix) + '[0-9a-f]{32}$')) {
    throw "Refuse cleanup outside an explicitly named test directory: $path"
  }
  return $fullPath
}

function Remove-Sandbox($sandbox) {
  if (-not $sandbox -or -not $sandbox.fake) { return }
  $testRoot = Assert-TestDirectory $sandbox.root "codex-run-test-"
  $fakeExe = Join-Path $testRoot "fake\codex.exe"
  Get-Process -Name codex -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and [string]::Equals($_.Path, $fakeExe, [StringComparison]::OrdinalIgnoreCase) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Reset-State($sandbox) {
  $testRoot = Assert-TestDirectory $sandbox.root "codex-run-test-"
  $fakeExe = Join-Path $testRoot "fake\codex.exe"
  Get-Process -Name codex -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and [string]::Equals($_.Path, $fakeExe, [StringComparison]::OrdinalIgnoreCase) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  $map = Join-Path $sandbox.repo ".pipeline\codex-map.json"
  if (Test-Path $map) { Remove-Item -LiteralPath $map -Force }
  $lock = Join-Path $sandbox.repo ".pipeline\logs\codex-run.lock"
  if (Test-Path $lock) { Remove-Item -LiteralPath $lock -Force }
  $calls = Join-Path $sandbox.fake "calls.txt"
  if (Test-Path $calls) { Remove-Item -LiteralPath $calls -Force }
  $killCalls = Join-Path $sandbox.fake "taskkill-calls.txt"
  if (Test-Path $killCalls) { Remove-Item -LiteralPath $killCalls -Force }
  # Moi case context chi duoc doc rollout fixture cua chinh no.
  Get-ChildItem -LiteralPath (Join-Path $sandbox.codexHome "sessions") -Filter *.jsonl |
    Remove-Item -Force
}

function Invoke-Runner {
  param(
    [hashtable]$Sandbox,
    [string]$Key = "",
    [switch]$FreshSession,
    [switch]$Resume,
    [switch]$NoTui,
    [int]$TimeoutSec = 0,
    [string]$Thread = "",
    [string]$ClaudeHost = "",
    [string]$ClaudeSession = "",
    [string]$Session = "",
    [switch]$Sleep,
    [switch]$BoundedWait,
    [string]$WorkingDirectory = '',
    [switch]$Touch,
    [string]$CodexHome = "",
    [switch]$WriteRollout
  )
  $saved = @{
    PATH = $env:PATH
    HOST = $env:CLAUDE_CODE_HOST_SESSION_ID
    SESS = $env:CLAUDE_CODE_SESSION_ID
    THREAD = $env:FAKE_CODEX_THREAD
    SLEEP = $env:FAKE_CODEX_SLEEP
    TOUCH = $env:FAKE_CODEX_TOUCH
    CODEX_HOME = $env:CODEX_HOME
    SESSIONS_ROOT = $env:FAKE_CODEX_SESSIONS_ROOT
  }
  $env:PATH = "$($Sandbox.fake);$($saved.PATH)"
  $env:CLAUDE_CODE_HOST_SESSION_ID = $null
  $env:CLAUDE_CODE_SESSION_ID = $null
  $env:FAKE_CODEX_THREAD = $null
  $env:FAKE_CODEX_SLEEP = $null
  $env:FAKE_CODEX_TOUCH = $null
  # Tuyet doi khong fallback sang rollout that trong USERPROFILE khi test.
  $env:CODEX_HOME = $Sandbox.codexHome
  $env:FAKE_CODEX_SESSIONS_ROOT = $null
  if ($ClaudeHost) { $env:CLAUDE_CODE_HOST_SESSION_ID = $ClaudeHost }
  if ($ClaudeSession) { $env:CLAUDE_CODE_SESSION_ID = $ClaudeSession }
  if ($Thread) { $env:FAKE_CODEX_THREAD = $Thread }
  if ($Sleep) { $env:FAKE_CODEX_SLEEP = "1" }
  if ($Touch) { $env:FAKE_CODEX_TOUCH = "1" }
  if ($CodexHome) { $env:CODEX_HOME = $CodexHome }
  if ($WriteRollout) { $env:FAKE_CODEX_SESSIONS_ROOT = (Join-Path $Sandbox.codexHome "sessions") }
  $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:runnerPath, "-TaskFile", (Join-Path $Sandbox.repo ".pipeline\tasks\t1.md"))
  if ($Key) { $argList += @("-Key", $Key) }
  if ($Session) { $argList += @("-Session", $Session) }
  if ($FreshSession) { $argList += "-FreshSession" }
  if ($Resume) { $argList += "-Resume" }
  if ($NoTui) { $argList += "-NoTui" }
  if ($TimeoutSec -gt 0) { $argList += @("-TimeoutSec", [string]$TimeoutSec) }
  $outPath = Join-Path $Sandbox.out ("run-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".txt")
  $errPath = "$outPath.err"
  try {
  Push-Location $(if ($WorkingDirectory) { $WorkingDirectory } else { $Sandbox.repo })
  try {
    if ($BoundedWait) {
      # Native PowerShell invocation can wait for the whole descendant job;
      # measure the runner itself, independently of its retained child.
      $quotedArgs = @($argList | ForEach-Object { '"' + $_ + '"' })
      $parent = Start-Process powershell.exe -ArgumentList $quotedArgs -WorkingDirectory $Sandbox.repo -WindowStyle Hidden -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
      try {
        $parentHandle = $parent.Handle
        if (-not $parent.WaitForExit(15000)) {
          $parent.Kill()
          throw 'Runner exceeded the bounded 15 second test deadline'
        }
        $runnerCode = $parent.ExitCode
      } finally { $parent.Dispose() }
    } else {
      & powershell.exe @argList 1>$outPath 2>$errPath
      $runnerCode = $LASTEXITCODE
    }
  } finally {
    Pop-Location
  }
    if ($runnerCode -in @(1, 7)) {
      Write-Warning ("runner exit {0}:`n{1}`n{2}" -f $runnerCode,
        [string](Get-Content -Raw -ErrorAction SilentlyContinue $outPath),
        [string](Get-Content -Raw -ErrorAction SilentlyContinue $errPath))
    }
    return @{
      code = $runnerCode
      text = [string](Get-Content -Raw -ErrorAction SilentlyContinue $outPath)
      err = [string](Get-Content -Raw -ErrorAction SilentlyContinue $errPath)
    }
  } finally {
    $env:PATH = $saved.PATH
    $env:CLAUDE_CODE_HOST_SESSION_ID = $saved.HOST
    $env:CLAUDE_CODE_SESSION_ID = $saved.SESS
    $env:FAKE_CODEX_THREAD = $saved.THREAD
    $env:FAKE_CODEX_SLEEP = $saved.SLEEP
    $env:FAKE_CODEX_TOUCH = $saved.TOUCH
    $env:CODEX_HOME = $saved.CODEX_HOME
    $env:FAKE_CODEX_SESSIONS_ROOT = $saved.SESSIONS_ROOT
  }
}

function Set-TestCommand($sandbox, $command) {
  @{ test_command = $command } | ConvertTo-Json | Set-Content -Path (Join-Path $sandbox.repo ".pipeline\pipeline.config.json") -Encoding UTF8
  & git -C $sandbox.repo add .pipeline/pipeline.config.json 2>$null | Out-Null
  & git -C $sandbox.repo commit -qm "test config" 2>$null | Out-Null
}

function Get-FakeCalls($sandbox) {
  $p = Join-Path $sandbox.fake "calls.txt"
  if (-not (Test-Path $p)) { return @() }
  return @(Get-Content -LiteralPath $p)
}

function Get-CallArgs($line) {
  if ($line -notmatch "ARGS=(.*) THREAD=") { return [string]$line }
  return [string]$Matches[1]
}

function Get-Map($sandbox) {
  $p = Join-Path $sandbox.repo ".pipeline\codex-map.json"
  if (-not (Test-Path $p)) { return $null }
  try { return (Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json) } catch { return $null }
}

function Set-SessionMap($sandbox, $map) {
  $map | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $sandbox.repo ".pipeline\codex-map.json") -Encoding UTF8
}

function Write-CodexRollout {
  param(
    [hashtable]$Sandbox,
    [string]$Thread,
    [object[]]$Events,
    [switch]$NativeId,
    [string]$ParentSession = ""
  )
  $payload = @{ cwd = $Sandbox.repo }
  if ($NativeId) { $payload.id = $Thread } else { $payload.session_id = $Thread }
  if ($ParentSession) { $payload.session_id = $ParentSession }
  $rows = @(@{ type = "session_meta"; payload = $payload }) + $Events
  $path = Join-Path $Sandbox.codexHome ("sessions\rollout-" + [guid]::NewGuid().ToString("N") + ".jsonl")
  @($rows | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 20 -Compress }) |
    Set-Content -LiteralPath $path -Encoding UTF8
}

function New-OldTokenUsage($inputTokens, $windowTokens = 100000, $lifetimeTokens = 900000, $outputTokens = 0) {
  return @{
    type = "event_msg"
    payload = @{
      type = "token_count"
      info = @{
        model_context_window = $windowTokens
        last_token_usage = @{ input_tokens = $inputTokens; output_tokens = $outputTokens; total_tokens = $inputTokens + $outputTokens }
        total_token_usage = @{ input_tokens = $lifetimeTokens; output_tokens = 10000; total_tokens = $lifetimeTokens + 10000 }
      }
    }
  }
}

function Set-TuiRecord($sandbox, $pidValue, $procStarted) {
  $record = @{ pid = [int]$pidValue; session_key = "seed"; started = (Get-Date).ToString("s") }
  if ($procStarted) { $record.proc_started = [string]$procStarted }
  $map = @{ "__pipeline_tui__" = $record }
  $map | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $sandbox.repo ".pipeline\codex-map.json") -Encoding UTF8
}

function Start-FakeVictim($sandbox) {
  $savedSleep = $env:FAKE_CODEX_SLEEP
  $savedThread = $env:FAKE_CODEX_THREAD
  $env:FAKE_CODEX_SLEEP = "1"
  $env:FAKE_CODEX_THREAD = "victim"
  try {
    $p = Start-Process -FilePath (Join-Path $sandbox.fake "codex.exe") -PassThru -WorkingDirectory $sandbox.fake
  } finally {
    $env:FAKE_CODEX_SLEEP = $savedSleep
    $env:FAKE_CODEX_THREAD = $savedThread
  }
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline) {
    try {
      $start = $p.StartTime.ToUniversalTime().ToString("o")
      if ($start) { return @{ proc = $p; started = $start } }
    } catch { }
    if ($p.HasExited) { break }
    Start-Sleep -Milliseconds 100
  }
  return @{ proc = $p; started = $null }
}

function Stop-FakeProcess($proc) {
  if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

function Test-ProcessAlive($pidValue) {
  return [bool](Get-Process -Id $pidValue -ErrorAction SilentlyContinue)
}

Describe "codex-run session identity" {
  BeforeAll {
    $sandbox = New-Sandbox
  }
  AfterAll {
    Remove-Sandbox $sandbox
  }
  BeforeEach {
    Reset-State $sandbox
  }

  It "cung -Key tao roi resume dung mot Codex thread, key khac khong dung chung" {
    $r1 = Invoke-Runner -Sandbox $sandbox -Key "key-a" -Thread "thread-a" -NoTui
    $r1.code | Should Be 5
    $calls = @(Get-FakeCalls $sandbox)
    $calls.Count | Should Be 1
    (Get-CallArgs $calls[0]) | Should Not Match "\|resume\|"
    (Get-Map $sandbox).'key-a'.codex_thread | Should Be "thread-a"

    $r2 = Invoke-Runner -Sandbox $sandbox -Key "key-a" -Thread "thread-b" -NoTui
    $r2.code | Should Be 5
    $calls = @(Get-FakeCalls $sandbox)
    $calls.Count | Should Be 2
    (Get-CallArgs $calls[1]) | Should Match "\|resume\|"
    (Get-CallArgs $calls[1]) | Should Match "\|thread-a\|-$"
    (Get-Map $sandbox).'key-a'.codex_thread | Should Be "thread-a"

    $r3 = Invoke-Runner -Sandbox $sandbox -Key "key-b" -Thread "thread-b" -NoTui
    $r3.code | Should Be 5
    $calls = @(Get-FakeCalls $sandbox)
    (Get-CallArgs $calls[2]) | Should Not Match "\|resume\|"
    (Get-Map $sandbox).'key-b'.codex_thread | Should Be "thread-b"
    (Get-Map $sandbox).'key-a'.codex_thread | Should Be "thread-a"
  }

  It "dung CLAUDE_CODE_HOST_SESSION_ID truoc CLAUDE_CODE_SESSION_ID khi khong co -Key" {
    $r = Invoke-Runner -Sandbox $sandbox -ClaudeHost "env-host-key" -ClaudeSession "env-sess-key" -Thread "thread-env" -NoTui
    $r.code | Should Be 5
    (Get-Map $sandbox).'env-host-key'.codex_thread | Should Be "thread-env"
  }

  It "dung CLAUDE_CODE_SESSION_ID khi chi co env do" {
    $r = Invoke-Runner -Sandbox $sandbox -ClaudeSession "env-only-key" -Thread "thread-env2" -NoTui
    $r.code | Should Be 5
    (Get-Map $sandbox).'env-only-key'.codex_thread | Should Be "thread-env2"
  }

  It "ban do cu <claude-key>::<task-id> duoc chuyen sang khoa moi va resume thread cu" {
    # Dung dung task id runner tinh tu ten brief (xem bin/codex-run.ps1):
    # bo duoi .fix-<n>/.run, nen t1.md -> t1.
    $taskId = [IO.Path]::GetFileNameWithoutExtension((Join-Path $sandbox.repo ".pipeline\tasks\t1.md")) -replace '\.fix-\d+$', '' -replace '\.run$', ''
    $legacy = @{}
    $legacy["legacy-key::$taskId"] = @{
      codex_thread = "thread-legacy"
      claude_session_id = "legacy-claude"
      session_key = "legacy-key"
      last_task_id = $taskId
      last_used = "2020-01-01T00:00:00"
    }
    $legacy | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $sandbox.repo ".pipeline\codex-map.json") -Encoding UTF8

    $r = Invoke-Runner -Sandbox $sandbox -Key "legacy-key" -Thread "ignored" -NoTui
    $r.code | Should Be 5
    $calls = @(Get-FakeCalls $sandbox)
    $calls.Count | Should Not Be 0
    $last = Get-CallArgs $calls[-1]
    $last | Should Match "\|resume\|"
    $last | Should Match "\|thread-legacy\|-$"
    (Get-Map $sandbox).'legacy-key'.codex_thread | Should Be "thread-legacy"
  }

  It "-FreshSession khong truyen resume va thay thread trong ban do" {
    [void](Invoke-Runner -Sandbox $sandbox -Key "fresh-key" -Thread "thread-old" -NoTui)
    (Get-Map $sandbox).'fresh-key'.codex_thread | Should Be "thread-old"

    $r = Invoke-Runner -Sandbox $sandbox -Key "fresh-key" -Thread "thread-new" -FreshSession -NoTui
    $r.code | Should Be 5
    $calls = @(Get-FakeCalls $sandbox)
    $calls.Count | Should Be 2
    (Get-CallArgs $calls[1]) | Should Not Match "\|resume\|"
    (Get-Map $sandbox).'fresh-key'.codex_thread | Should Be "thread-new"
  }

  It "thieu ca -Key lan env Claude thi BLOCKED truoc khi fake Codex kip chay" {
    $r = Invoke-Runner -Sandbox $sandbox -NoTui
    $r.code | Should Be 11
    $r.text | Should Match "BLOCKED:"
    $r.text | Should Match "-Key"
    (Get-FakeCalls $sandbox).Count | Should Be 0
    (Test-Path (Join-Path $sandbox.repo ".pipeline\logs\codex-run.lock")) | Should Be $false
  }
}

Describe "codex-run context rollover and session history" {
  BeforeAll {
    $sandbox = New-Sandbox
  }
  AfterAll {
    Remove-Sandbox $sandbox
  }
  BeforeEach {
    Reset-State $sandbox
    Set-SessionMap $sandbox @{ "context-claude" = @{ codex_thread = "thread-old"; session_key = "context-claude"; last_used = "2024-01-01T00:00:00" } }
  }

  It "old token_count dung request cuoi, khong cong usage lifetime hay cached input" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-old" -Events @(
      (New-OldTokenUsage 95000),
      (New-OldTokenUsage 50000 100000 3000000)
    )
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-unused" -NoTui
    $r.code | Should Be 5
    (Get-CallArgs @(Get-FakeCalls $sandbox)[0]) | Should Match "\|resume\|"
    (Get-Map $sandbox).'context-claude'.codex_thread | Should Be "thread-old"
    @((Get-Map $sandbox).'context-claude'.codex_sessions).Count | Should Be 1
  }

  It "dung 80 phan tram thi van resume, chua tao session moi" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-old" -Events @((New-OldTokenUsage 80000))
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-unused" -NoTui
    $r.code | Should Be 5
    (Get-CallArgs @(Get-FakeCalls $sandbox)[0]) | Should Match "\|thread-old\|-$"
    (Get-Map $sandbox).'context-claude'.codex_thread | Should Be "thread-old"
  }

  It "80.001 phan tram tao session moi va luu ca thread cu du hien thi lam tron thanh 80" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-old" -Events @((New-OldTokenUsage 80001))
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-new" -NoTui
    $r.code | Should Be 5
    (Get-CallArgs @(Get-FakeCalls $sandbox)[0]) | Should Not Match "\|resume\|"
    $record = (Get-Map $sandbox).'context-claude'
    $record.codex_thread | Should Be "thread-new"
    @($record.codex_sessions).Count | Should Be 2
    ($record.codex_sessions.thread_id -contains "thread-old") | Should Be $true
    ($record.codex_sessions.thread_id -contains "thread-new") | Should Be $true
    $old = $record.codex_sessions | Where-Object { $_.thread_id -eq "thread-old" }
    $old.retired_reason | Should Match "context"
    $old.last_context_tokens | Should Be 80001
    $old.context_window_tokens | Should Be 100000
    # Legacy chi biet last_used, khong duoc bien no thanh thoi diem tao thread.
    $old.created_at | Should BeNullOrEmpty
    $r.text | Should Match "TUI: codex resume thread-new"
  }

  It "latest request gom output tokens khi xet vuot nguong" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-old" -Events @((New-OldTokenUsage 79995 100000 3000000 10))
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-new" -NoTui
    $r.code | Should Be 5
    (Get-Map $sandbox).'context-claude'.codex_thread | Should Be "thread-new"
  }

  It "schema moi dung task_started va token_usage_record voi session_meta.id" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-old" -NativeId -Events @(
      @{ type = "event_msg"; payload = @{ type = "task_started"; model_context_window = 100000 } },
      @{ type = "token_usage_record"; payload = @{ usage = @{ input_tokens = 85000; cached_input_tokens = 60000; output_tokens = 100; total_tokens = 85100 } } }
    )
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-new" -NoTui
    $r.code | Should Be 5
    (Get-Map $sandbox).'context-claude'.codex_thread | Should Be "thread-new"
    $old = (Get-Map $sandbox).'context-claude'.codex_sessions | Where-Object { $_.thread_id -eq "thread-old" }
    $old.last_context_tokens | Should Be 85100
  }

  It "schema moi khong dem cache them mot lan nua va dung usage cuoi" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-old" -NativeId -Events @(
      @{ type = "event_msg"; payload = @{ type = "task_started"; model_context_window = 100000 } },
      @{ type = "token_usage_record"; payload = @{ usage = @{ input_tokens = 91000; output_tokens = 100 } } },
      @{ type = "token_usage_record"; payload = @{ usage = @{ input_tokens = 60000; cached_input_tokens = 50000; output_tokens = 1000; total_tokens = 61000 } } }
    )
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-unused" -NoTui
    $r.code | Should Be 5
    (Get-Map $sandbox).'context-claude'.codex_thread | Should Be "thread-old"
  }

  It "sau compact khong dung lai usage cu de rollover khi chua co usage moi" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-old" -Events @(
      (New-OldTokenUsage 99000),
      @{ type = "compacted"; payload = @{ message = "Summary replaces previous context." } },
      @{ type = "event_msg"; payload = @{ type = "task_started"; model_context_window = 100000 } }
    )
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-unused" -NoTui
    $r.code | Should Be 5
    (Get-Map $sandbox).'context-claude'.codex_thread | Should Be "thread-old"
    $r.text | Should Match "CONTEXT:.*khong.*giu phien"
  }

  It "usage moi sau compact lai duoc dung de rollover" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-old" -Events @(
      (New-OldTokenUsage 99000),
      @{ type = "compacted"; payload = @{ message = "Summary." } },
      (New-OldTokenUsage 81000)
    )
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-new" -NoTui
    $r.code | Should Be 5
    (Get-Map $sandbox).'context-claude'.codex_thread | Should Be "thread-new"
  }

  It "session_meta.id cua subagent khac parent session_id khong bi tinh vao context parent" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-old" -NativeId -Events @((New-OldTokenUsage 40000))
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-child" -NativeId -ParentSession "thread-old" -Events @((New-OldTokenUsage 99000))
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-unused" -NoTui
    $r.code | Should Be 5
    (Get-Map $sandbox).'context-claude'.codex_thread | Should Be "thread-old"
  }

  It "thieu usage thi canh bao va giu session, khong tu gia dinh day context" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-old" -Events @(
      @{ type = "event_msg"; payload = @{ type = "task_started"; model_context_window = 100000 } }
    )
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-unused" -NoTui
    $r.code | Should Be 5
    (Get-Map $sandbox).'context-claude'.codex_thread | Should Be "thread-old"
    $r.text | Should Match "CONTEXT:.*khong.*giu phien"
    @((Get-Map $sandbox).'context-claude'.codex_sessions).Count | Should Be 1
  }

  It "FreshSession nhieu lan giu tat ca thread va lan resume khong them trung lich su" {
    [void](Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-two" -FreshSession -NoTui)
    [void](Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-three" -FreshSession -NoTui)
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "thread-unused" -NoTui
    $r.code | Should Be 5
    $record = (Get-Map $sandbox).'context-claude'
    $record.codex_thread | Should Be "thread-three"
    @($record.codex_sessions).Count | Should Be 3
    (@($record.codex_sessions.thread_id | Sort-Object) -join ",") | Should Be "thread-old,thread-three,thread-two"
    @($record.codex_sessions | Where-Object { $_.thread_id -ne "thread-old" -and (-not $_.created_at -or -not $_.last_used) }).Count | Should Be 0
  }

  It "migrate nhieu legacy task key thanh lich su chung va giu rieng phien Claude khac" {
    Set-SessionMap $sandbox @{
      "legacy-claude::first" = @{ codex_thread = "thread-one"; session_key = "legacy-claude"; last_used = "2024-01-01T00:00:00" }
      "legacy-claude::second" = @{ codex_thread = "thread-two"; session_key = "legacy-claude"; last_used = "2024-01-02T00:00:00" }
      "other-claude::third" = @{ codex_thread = "thread-unrelated"; session_key = "other-claude"; last_used = "2024-01-03T00:00:00" }
    }
    $r = Invoke-Runner -Sandbox $sandbox -Key "legacy-claude" -Thread "thread-unused" -NoTui
    $r.code | Should Be 5
    $map = Get-Map $sandbox
    $map.'legacy-claude'.codex_thread | Should Be "thread-two"
    (@($map.'legacy-claude'.codex_sessions.thread_id | Sort-Object) -join ",") | Should Be "thread-one,thread-two"
    $map.'other-claude::third'.codex_thread | Should Be "thread-unrelated"
    (Get-CallArgs @(Get-FakeCalls $sandbox)[0]) | Should Match "\|thread-two\|-$"
  }

  It "Session chi dinh thu cong duoc them lich su va giu ca active thread truoc do" {
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Session "thread-selected" -NoTui
    $r.code | Should Be 5
    $record = (Get-Map $sandbox).'context-claude'
    $record.codex_thread | Should Be "thread-selected"
    (@($record.codex_sessions.thread_id | Sort-Object) -join ",") | Should Be "thread-old,thread-selected"
    (Get-CallArgs @(Get-FakeCalls $sandbox)[0]) | Should Match "\|thread-selected\|-$"
  }

  It "Session chi dinh da vuot nguong van duoc luu truoc khi tao thread thay the" {
    Write-CodexRollout -Sandbox $sandbox -Thread "thread-selected" -Events @((New-OldTokenUsage 90000))
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Session "thread-selected" -Thread "thread-replacement" -NoTui
    $r.code | Should Be 5
    $record = (Get-Map $sandbox).'context-claude'
    $record.codex_thread | Should Be "thread-replacement"
    (@($record.codex_sessions.thread_id | Sort-Object) -join ",") | Should Be "thread-old,thread-replacement,thread-selected"
  }

  It "Session cu the van phai co khoa Claude, neu thieu thi chan truoc khi goi Codex" {
    $r = Invoke-Runner -Sandbox $sandbox -Session "thread-selected" -NoTui
    $r.code | Should Be 11
    $r.text | Should Match "BLOCKED:.*-Key"
    (Get-FakeCalls $sandbox).Count | Should Be 0
  }

  It "map JSON hong voi FreshSession bi chan truoc khi dispatch va giu nguyen lich su" {
    $mapPath = Join-Path $sandbox.repo ".pipeline\codex-map.json"
    Set-Content -LiteralPath $mapPath -Value '{"context-claude":BROKEN' -Encoding UTF8
    $original = [IO.File]::ReadAllText($mapPath)
    $r = Invoke-Runner -Sandbox $sandbox -Key "context-claude" -Thread "must-not-start" -FreshSession -NoTui
    $r.code | Should Be 1
    ($r.text + $r.err) | Should Match "BLOCKED: khong doc duoc"
    (Get-FakeCalls $sandbox).Count | Should Be 0
    [IO.File]::ReadAllText($mapPath) | Should Be $original
    (Test-Path (Join-Path $sandbox.repo ".pipeline\logs\codex-run.lock")) | Should Be $false
  }
}

Describe "codex-run TUI PID safety" {
  BeforeAll {
    $sandbox = New-Sandbox
  }
  AfterAll {
    Remove-Sandbox $sandbox
  }
  BeforeEach {
    Reset-State $sandbox
  }

  It "chan luot moi neu khong dong duoc TUI cu da quan ly" {
    $victim = Start-FakeVictim $sandbox
    $victim.started | Should Not BeNullOrEmpty
    Set-TuiRecord $sandbox $victim.proc.Id $victim.started

    $r = Invoke-Runner -Sandbox $sandbox -Key "tui-key" -TimeoutSec 2
    $r.code | Should Be 10
    $r.text | Should Match "BLOCKED: khong dong duoc TUI Codex cu"
    (Get-Content -LiteralPath (Join-Path $sandbox.fake "taskkill-calls.txt")) | Should Be "/PID|$($victim.proc.Id)|/T|/F"
    (Test-ProcessAlive $victim.proc.Id) | Should Be $true
    Stop-FakeProcess $victim.proc
  }

  It "khong giet PID da chet" {
    $deadPid = 999997
    while (Get-Process -Id $deadPid -ErrorAction SilentlyContinue) { $deadPid-- }
    Set-TuiRecord $sandbox $deadPid "2020-01-01T00:00:00.0000000Z"

    $r = Invoke-Runner -Sandbox $sandbox -Key "tui-key" -TimeoutSec 2 -Sleep
    $r.text | Should Not Match "DONG CUA SO TUI CU"
    $r.code | Should Be 124
    $r.text | Should Match "giu run lock"
    (Test-Path (Join-Path $sandbox.repo ".pipeline\logs\codex-run.lock")) | Should Be $true
  }

  It "khong giet PID da bi tai su dung (thoi diem khoi dong khac)" {
    $victim = Start-FakeVictim $sandbox
    $victim.started | Should Not BeNullOrEmpty
    Set-TuiRecord $sandbox $victim.proc.Id "2001-01-01T00:00:00.0000000Z"

    $r = Invoke-Runner -Sandbox $sandbox -Key "tui-key" -TimeoutSec 2
    $r.text | Should Not Match "DONG CUA SO TUI CU \(PID $($victim.proc.Id)\)"
    (Test-ProcessAlive $victim.proc.Id) | Should Be $true
    Stop-FakeProcess $victim.proc
  }

  It "bo qua ban ghi cu khong co proc_started thay vi giet nham" {
    $victim = Start-FakeVictim $sandbox
    Set-TuiRecord $sandbox $victim.proc.Id $null

    $r = Invoke-Runner -Sandbox $sandbox -Key "tui-key" -TimeoutSec 2
    $r.text | Should Match "CANH BAO: ban ghi TUI cu"
    $r.text | Should Not Match "DONG CUA SO TUI CU"
    (Test-ProcessAlive $victim.proc.Id) | Should Be $true
    Stop-FakeProcess $victim.proc
  }

  It "khong giet PID song nhung khong phai tien trinh codex" {
    $victim = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 60") -PassThru -WindowStyle Hidden
    $started = $null
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $started -and (Get-Date) -lt $deadline) {
      try { $started = $victim.StartTime.ToUniversalTime().ToString("o") } catch { Start-Sleep -Milliseconds 100 }
    }
    $started | Should Not BeNullOrEmpty
    Set-TuiRecord $sandbox $victim.Id $started

    $r = Invoke-Runner -Sandbox $sandbox -Key "tui-key" -TimeoutSec 2
    $r.text | Should Not Match "DONG CUA SO TUI CU \(PID $($victim.Id)\)"
    (Test-ProcessAlive $victim.Id) | Should Be $true
    Stop-Process -Id $victim.Id -Force -ErrorAction SilentlyContinue
  }
}

Describe "codex-run TUI session location" {
  BeforeAll {
    $sandbox = New-Sandbox
  }
  AfterAll {
    Remove-Sandbox $sandbox
  }

  It "doc rollout tu CODEX_HOME thay vi chi USERPROFILE" {
    $r = Invoke-Runner -Sandbox $sandbox -Key "codex-home-key" -Thread "thread-codex-home" -TimeoutSec 10 -CodexHome $sandbox.codexHome -WriteRollout
    $r.code | Should Be 5
    $r.text | Should Match "CUA SO TUI DANG MO"
    (Get-Map $sandbox).'codex-home-key'.codex_thread | Should Be "thread-codex-home"
  }
}

Describe "codex-run headless command path" {
  BeforeAll {
    $sandbox = New-Sandbox
  }
  AfterAll {
    Remove-Sandbox $sandbox
  }
  BeforeEach {
    Reset-State $sandbox
  }

  It "lenh resume dung dang codex exec resume ... <thread>" {
    [void](Invoke-Runner -Sandbox $sandbox -Key "args-key" -Thread "thread-args" -NoTui)
    $r = Invoke-Runner -Sandbox $sandbox -Key "args-key" -NoTui
    $r.code | Should Be 5

    $calls = @(Get-FakeCalls $sandbox)
    $calls.Count | Should Be 2
    (Get-CallArgs $calls[0]) | Should Match "^exec\|--json\|--approve-for-me\|--cd\|"
    (Get-CallArgs $calls[1]) | Should Match "^exec\|resume\|--json\|"
    (Get-CallArgs $calls[1]) | Should Match "\|thread-args\|-$"
  }
}

Describe "codex-run test command exit status" {
  BeforeEach {
    $sandbox = New-Sandbox
  }
  AfterEach {
    Remove-Sandbox $sandbox
  }

  It "tra exit 8 khi test command that bai chi bang exit code" {
    Set-TestCommand $sandbox "cmd.exe /d /c exit 1"

    $r = Invoke-Runner -Sandbox $sandbox -Key "test-exit-key" -Thread "thread-test-exit" -NoTui -Touch
    $r.code | Should Be 8
    $r.text | Should Match "TESTS: FAILED"
  }

  It "fails verification on a terminating PowerShell exception" {
    Set-TestCommand $sandbox 'throw "verify failed"'
    $r = Invoke-Runner -Sandbox $sandbox -Key 'verify' -NoTui -Touch
    $r.code | Should Be 8
    $r.text | Should Match 'TESTS: FAILED'
  }

  It "fails verification on nonterminating errors even followed by successful output" {
    Set-TestCommand $sandbox 'Write-Error "verify failed"; Write-Output "done"'
    $r = Invoke-Runner -Sandbox $sandbox -Key 'verify' -NoTui -Touch
    $r.code | Should Be 8
  }

  It "does not turn harmless native stderr with exit zero into a failed verification" {
    Set-TestCommand $sandbox 'cmd.exe /d /c "echo harmless warning 1>&2 & exit /b 0"'
    $r = Invoke-Runner -Sandbox $sandbox -Key 'verify' -NoTui -Touch
    $r.code | Should Be 0
  }
}

Describe "codex-run medium priority safety regressions" {
  BeforeEach { $sandbox = New-Sandbox }
  AfterEach { Remove-Sandbox $sandbox }

  It "detects resume edits when invoked from a subdirectory" {
    $subdir = Join-Path $sandbox.repo 'src'
    New-Item -ItemType Directory -Path $subdir | Out-Null
    Set-Content (Join-Path $sandbox.repo 'fake-change.txt') old
    (Invoke-Runner $sandbox -Key medium -Session fixture -NoTui -Resume -Touch -WorkingDirectory $subdir).code | Should Be 0
  }

  It "blocks Codex while a shared writer guard is held" {
    $path = Join-Path $sandbox.repo '.pipeline\logs\pipeline-run.guard'
    $guard = [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'None')
    try {
      (Invoke-Runner $sandbox -Key medium -NoTui).code | Should Be 10
      @(Get-FakeCalls $sandbox).Count | Should Be 0
    } finally { $guard.Dispose() }
  }

  It "blocks Codex when an OpenCode timeout has not been confirmed stopped" {
    '{}' | Set-Content (Join-Path $sandbox.repo '.pipeline\logs\opencode-pending.json')
    (Invoke-Runner $sandbox -Key medium -NoTui).code | Should Be 10
    @(Get-FakeCalls $sandbox).Count | Should Be 0
  }

  It "detects new edits to an already untracked file on resume" {
    Set-Content (Join-Path $sandbox.repo 'fake-change.txt') 'old'
    (Invoke-Runner $sandbox -Key medium -Session fixture -NoTui -Resume -Touch).code | Should Be 0
  }

  It "detects new edits to an already modified tracked file on resume" {
    Set-Content (Join-Path $sandbox.repo 'fake-change.txt') 'baseline'
    & git -C $sandbox.repo add fake-change.txt
    & git -C $sandbox.repo commit -qm baseline
    Set-Content (Join-Path $sandbox.repo 'fake-change.txt') 'old'
    (Invoke-Runner $sandbox -Key medium -Session fixture -NoTui -Resume -Touch).code | Should Be 0
  }

  It "does not count unchanged dirty content as new work" {
    Set-Content (Join-Path $sandbox.repo 'fake-change.txt') 'old'
    (Invoke-Runner $sandbox -Key medium -Session fixture -NoTui -Resume).code | Should Be 5
  }

  It "cannot reclaim a stale JSON record while another runner holds the guard" {
    $lock = Join-Path $sandbox.repo '.pipeline\logs\codex-run.lock'
    '{"pid":2147483647}' | Set-Content $lock
    $handle = [IO.File]::Open("$lock.guard", 'OpenOrCreate', 'ReadWrite', 'None')
    try {
      (Invoke-Runner $sandbox -Key medium -NoTui).code | Should Be 10
      @(Get-FakeCalls $sandbox).Count | Should Be 0
      (Get-Content -Raw $lock | ConvertFrom-Json).pid | Should Be 2147483647
    } finally { $handle.Dispose() }
    (Invoke-Runner $sandbox -Key medium -NoTui).code | Should Be 5
    (Test-Path $lock) | Should Be $false
    (Test-Path "$lock.guard") | Should Be $true
  }

  It "fails closed on an unreadable owner record" {
    '{broken' | Set-Content (Join-Path $sandbox.repo '.pipeline\logs\codex-run.lock')
    (Invoke-Runner $sandbox -Key medium -NoTui).code | Should Be 10
    @(Get-FakeCalls $sandbox).Count | Should Be 0
  }

  It "returns promptly after kill denial and preserves exclusion for the surviving child" {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Runner $sandbox -Key medium -NoTui -Sleep -TimeoutSec 2 -BoundedWait
    $watch.Stop()
    $r.code | Should Be 124
    ($watch.Elapsed.TotalSeconds -lt 15) | Should Be $true
    $owner = Get-Content -Raw (Join-Path $sandbox.repo '.pipeline\logs\codex-run.lock') | ConvertFrom-Json
    $owner.retained_for | Should Be 'codex-timeout'
    (Get-Process -Id $owner.pid -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
    (Invoke-Runner $sandbox -Key medium -NoTui).code | Should Be 10
    @(Get-FakeCalls $sandbox).Count | Should Be 1
  }
}

Describe "codex-run test cleanup" {
  It "runner va fake source ton tai de don dep an toan" {
    (Test-Path $script:runnerPath) | Should Be $true
  }
  AfterAll {
    Remove-Sandbox $script:sandboxIdentity
    if ($script:fakeSourceDir -and (Test-Path $script:fakeSourceDir)) {
      $fakeRoot = Assert-TestDirectory $script:fakeSourceDir "codex-run-fake-"
      Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe "codex-run rapid process exit code" {
  BeforeAll {
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($script:runnerPath, [ref]$null, [ref]$parseErrors)
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-CodexExec' }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
  }

  It "retains actual success and failure exit codes even for immediately exiting processes" {
    $rapidRoot = Join-Path $env:TEMP ('codex-run-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $rapidRoot | Out-Null
    try {
      $inputFile = Join-Path $rapidRoot 'input.txt'
      Set-Content -LiteralPath $inputFile -Value 'brief' -Encoding UTF8
      foreach ($expectedCode in @(0, 23, 0, 23)) {
        $process = Start-CodexExec 'cmd.exe' "/d /c exit $expectedCode" $rapidRoot $inputFile (Join-Path $rapidRoot 'out.log') (Join-Path $rapidRoot 'err.log')
        try { $process.Complete() | Should Be $expectedCode }
        finally { $process.Dispose() }
      }
    } finally {
      $validatedRoot = Assert-TestDirectory $rapidRoot 'codex-run-test-'
      Remove-Item -LiteralPath $validatedRoot -Recurse -Force
    }
  }

  It "pumps a long UTF-8 brief and concurrent output without deadlocking or losing bytes" {
    $rapidRoot = Join-Path $env:TEMP ('codex-run-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $rapidRoot | Out-Null
    try {
      $inputFile = Join-Path $rapidRoot 'input.txt'
      $outputFile = Join-Path $rapidRoot 'out.log'
      $errorFile = Join-Path $rapidRoot 'err.log'
      $brief = ('Long brief ' + [char]0x1EC7 + ' ') * 20000
      [IO.File]::WriteAllText($inputFile, $brief, [Text.UTF8Encoding]::new($false))
      $command = '[Console]::InputEncoding=[Text.UTF8Encoding]::new($false); [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); [Console]::Error.Write(("e" * 100000)); [Console]::Out.Write([Console]::In.ReadToEnd()); exit 23'
      $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
      $process = Start-CodexExec 'powershell.exe' "-NoProfile -EncodedCommand $encoded" $rapidRoot $inputFile $outputFile $errorFile
      try {
        $process.Process.WaitForExit(10000) | Should Be $true
        $process.Complete() | Should Be 23
        [IO.File]::ReadAllText($outputFile) | Should Be $brief
        ([IO.File]::ReadAllText($errorFile)).Length | Should Be 100000
      } finally {
        if (-not $process.Process.HasExited) { $process.Process.Kill() }
        $process.Dispose()
      }
    } finally {
      $validatedRoot = Assert-TestDirectory $rapidRoot 'codex-run-test-'
      Remove-Item -LiteralPath $validatedRoot -Recurse -Force
    }
  }
}
