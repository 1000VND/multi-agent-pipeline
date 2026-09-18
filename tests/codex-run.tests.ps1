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
  Set-Content -Path (Join-Path $repo ".pipeline\tasks\t1.md") -Value "Brief test" -Encoding UTF8
  Copy-Item -LiteralPath (Join-Path $script:packageRoot "templates\pipeline.gitignore") -Destination (Join-Path $repo ".pipeline\.gitignore") -Force
  & git -C $repo init -q 2>$null | Out-Null
  & git -C $repo config user.email "t@example.com"
  & git -C $repo config user.name "tester"
  & git -C $repo add -A 2>$null | Out-Null
  & git -C $repo commit -qm "init" 2>$null | Out-Null
  return @{ root = $root; repo = $repo; fake = $fake; out = $out; codexHome = $codexHome }
}

function Remove-Sandbox($sandbox) {
  if (-not $sandbox -or -not $sandbox.fake) { return }
  Get-Process -Name codex -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($sandbox.fake, [StringComparison]::OrdinalIgnoreCase) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  if ($sandbox.root -and (Test-Path $sandbox.root)) {
    Remove-Item -LiteralPath $sandbox.root -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Reset-State($sandbox) {
  Get-Process -Name codex -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($sandbox.fake, [StringComparison]::OrdinalIgnoreCase) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  $map = Join-Path $sandbox.repo ".pipeline\codex-map.json"
  if (Test-Path $map) { Remove-Item -LiteralPath $map -Force }
  $lock = Join-Path $sandbox.repo ".pipeline\logs\codex-run.lock"
  if (Test-Path $lock) { Remove-Item -LiteralPath $lock -Force }
  $calls = Join-Path $sandbox.fake "calls.txt"
  if (Test-Path $calls) { Remove-Item -LiteralPath $calls -Force }
}

function Invoke-Runner {
  param(
    [hashtable]$Sandbox,
    [string]$Key = "",
    [switch]$FreshSession,
    [switch]$NoTui,
    [int]$TimeoutSec = 0,
    [string]$Thread = "",
    [string]$ClaudeHost = "",
    [string]$ClaudeSession = "",
    [switch]$Sleep,
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
  $env:CODEX_HOME = $null
  $env:FAKE_CODEX_SESSIONS_ROOT = $null
  if ($ClaudeHost) { $env:CLAUDE_CODE_HOST_SESSION_ID = $ClaudeHost }
  if ($ClaudeSession) { $env:CLAUDE_CODE_SESSION_ID = $ClaudeSession }
  if ($Thread) { $env:FAKE_CODEX_THREAD = $Thread }
  if ($Sleep) { $env:FAKE_CODEX_SLEEP = "1" }
  if ($Touch) { $env:FAKE_CODEX_TOUCH = "1" }
  if ($CodexHome) { $env:CODEX_HOME = $CodexHome }
  if ($WriteRollout) { $env:FAKE_CODEX_SESSIONS_ROOT = (Join-Path $Sandbox.codexHome "sessions") }
  $argList = @("-NoProfile", "-File", $script:runnerPath, "-TaskFile", (Join-Path $Sandbox.repo ".pipeline\tasks\t1.md"))
  if ($Key) { $argList += @("-Key", $Key) }
  if ($FreshSession) { $argList += "-FreshSession" }
  if ($NoTui) { $argList += "-NoTui" }
  if ($TimeoutSec -gt 0) { $argList += @("-TimeoutSec", [string]$TimeoutSec) }
  $outPath = Join-Path $Sandbox.out ("run-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".txt")
  $errPath = "$outPath.err"
  try {
  Push-Location $Sandbox.repo
  try {
    & powershell.exe @argList 1>$outPath 2>$errPath
    $runnerCode = $LASTEXITCODE
  } finally {
    Pop-Location
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
  BeforeAll {
    $sandbox = New-Sandbox
  }
  AfterAll {
    Remove-Sandbox $sandbox
  }

  It "tra exit 8 khi test command that bai chi bang exit code" {
    Set-TestCommand $sandbox "cmd.exe /d /c exit 1"

    $r = Invoke-Runner -Sandbox $sandbox -Key "test-exit-key" -Thread "thread-test-exit" -NoTui -Touch
    $r.code | Should Be 8
    $r.text | Should Match "TESTS: FAILED"
  }
}

Describe "codex-run test cleanup" {
  It "runner va fake source ton tai de don dep an toan" {
    (Test-Path $script:runnerPath) | Should Be $true
  }
  AfterAll {
    Remove-Sandbox $script:sandboxIdentity
    if ($script:fakeSourceDir -and (Test-Path $script:fakeSourceDir)) {
      Remove-Item -LiteralPath $script:fakeSourceDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
