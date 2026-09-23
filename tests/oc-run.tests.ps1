# Pester 3.4 regression test cho bin/oc-run.ps1.
#
# Dung opencode.cmd gia de xac nhan brief dai di qua stdin (khong qua argv).
# Khong goi OpenCode cloud va khong mo cua so TUI that.

$script:packageRoot = Split-Path -Parent $PSScriptRoot
$script:runnerSource = Join-Path $script:packageRoot "bin\oc-run.ps1"

function New-OpenCodeSandbox {
  $root = Join-Path $env:TEMP ("oc-run-test-" + [guid]::NewGuid().ToString("N"))
  $repo = Join-Path $root "repo"
  $fake = Join-Path $root "fake"
  $bin = Join-Path $repo ".pipeline\bin"
  $taskDir = Join-Path $repo ".pipeline\tasks"
  New-Item -ItemType Directory -Force -Path $repo, $fake, $bin, $taskDir | Out-Null

  Copy-Item -LiteralPath $script:runnerSource -Destination (Join-Path $bin "oc-run.ps1")
  Copy-Item -LiteralPath (Join-Path $script:packageRoot 'bin\pipeline-runtime.ps1') -Destination $bin
  @'
param([string]$Key, [string]$Title, [string]$Url, [string]$Session, [switch]$Fresh, [switch]$NoWindow)
if ($env:FAKE_OC_TUI_EXIT) { Write-Output 'BLOCKED: fixture TUI'; exit ([int]$env:FAKE_OC_TUI_EXIT) }
$count = 0
if (Test-Path -LiteralPath $env:FAKE_OC_TUI_CALLS) {
  $count = [int](Get-Content -Raw -LiteralPath $env:FAKE_OC_TUI_CALLS)
}
$count++
Set-Content -LiteralPath $env:FAKE_OC_TUI_CALLS -Value $count
if ($count -gt 1) { Write-Output "CONTEXT: fixture rollover before fallback" }
$serverUrl = if ($env:FAKE_OC_URL) { $env:FAKE_OC_URL } else { 'http://127.0.0.1:1' }
Write-Output "URL=$serverUrl"
Write-Output "SESSION=fake-session-$count"
'@ | Set-Content -LiteralPath (Join-Path $bin "oc-tui.ps1") -Encoding UTF8

  @'
@echo off
echo %*>>"%FAKE_OC_ARGS%"
powershell.exe -NoProfile -Command "[Console]::OpenStandardInput().CopyTo([IO.File]::OpenWrite($env:FAKE_OC_STDIN)); if($env:FAKE_OC_CHANGE){[IO.File]::WriteAllText((Join-Path (Get-Location) 'change.txt'), $env:FAKE_OC_CHANGE)}; if($env:FAKE_OC_LOG){[Console]::WriteLine([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:FAKE_OC_LOG)))}; if($env:FAKE_OC_SLEEP){Start-Sleep -Seconds 30}; if($env:FAKE_OC_EXIT){exit ([int]$env:FAKE_OC_EXIT)}"
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath (Join-Path $fake "opencode.cmd") -Encoding ASCII

  $taskFile = Join-Path $taskDir "long-brief.md"
  $brief = "Mo ta tieng Viet voi dau nhay ""quoted""." + [Environment]::NewLine + (('x' * 20000) -join '')
  Set-Content -LiteralPath $taskFile -Value $brief -Encoding UTF8
  ".pipeline/logs/" | Set-Content -LiteralPath (Join-Path $repo ".gitignore") -Encoding ASCII

  & git -C $repo init -q 2>$null | Out-Null
  & git -C $repo config user.email "t@example.com"
  & git -C $repo config user.name "tester"
  & git -C $repo add -A 2>$null | Out-Null
  & git -C $repo commit -qm "init" 2>$null | Out-Null

  return @{
    root = $root
    repo = $repo
    fake = $fake
    taskFile = $taskFile
    brief = $brief
    stdinFile = Join-Path $root "received-stdin.txt"
    argsFile = Join-Path $root "received-args.txt"
    tuiCalls = Join-Path $root "tui-calls.txt"
  }
}

function Remove-OpenCodeSandbox($sandbox) {
  if ($sandbox -and $sandbox.root -and (Test-Path $sandbox.root)) {
    $resolvedRoot = (Resolve-Path -LiteralPath $sandbox.root).Path
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedRoot) -notmatch '^oc-run-test-[a-f0-9]{32}$') {
      throw "Refusing to delete unexpected test directory '$resolvedRoot'."
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-OpenCodeRunner($sandbox, [switch]$WithFallback, [switch]$Resume, [string]$Change = '', [int]$ExitCode = 0, [string]$LogText = '', [int]$TuiExit = 0, [string]$WorkingDirectory = '', [int]$TimeoutSec = 0, [switch]$Sleep, [string]$ServerUrl = '') {
  $saved = @{
    Path = $env:Path
    STDIN = $env:FAKE_OC_STDIN
    ARGS = $env:FAKE_OC_ARGS
    TUI_CALLS = $env:FAKE_OC_TUI_CALLS
    CHANGE = $env:FAKE_OC_CHANGE
    EXIT = $env:FAKE_OC_EXIT
    LOG = $env:FAKE_OC_LOG
    TUI_EXIT = $env:FAKE_OC_TUI_EXIT
    SLEEP = $env:FAKE_OC_SLEEP
    URL = $env:FAKE_OC_URL
  }
  $env:Path = "$($sandbox.fake);$($saved.Path)"
  $env:FAKE_OC_STDIN = $sandbox.stdinFile
  $env:FAKE_OC_ARGS = $sandbox.argsFile
  $env:FAKE_OC_TUI_CALLS = $sandbox.tuiCalls
  $env:FAKE_OC_CHANGE = $Change
  $env:FAKE_OC_EXIT = [string]$ExitCode
  $env:FAKE_OC_LOG = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($LogText))
  $env:FAKE_OC_TUI_EXIT = if ($TuiExit) { [string]$TuiExit } else { $null }
  $env:FAKE_OC_SLEEP = if ($Sleep) { '1' } else { $null }
  $env:FAKE_OC_URL = $ServerUrl
  try {
    Push-Location $(if ($WorkingDirectory) { $WorkingDirectory } else { $sandbox.repo })
    try {
      $fallbackArgs = @(if ($WithFallback) { '-Fallback'; 'fixture/fallback' } else { '-NoFallback' })
      if ($Resume) { $fallbackArgs += '-Resume' }
      if ($TimeoutSec) { $fallbackArgs += @('-TimeoutSec', [string]$TimeoutSec) }
      $text = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox.repo ".pipeline\bin\oc-run.ps1") -TaskFile $sandbox.taskFile -Key "claude-test" -NoTui @fallbackArgs -OpenCodeCmd (Join-Path $sandbox.fake "opencode.cmd") 2>&1 | Out-String)
      return @{ code = $LASTEXITCODE; text = $text }
    } finally {
      Pop-Location
    }
  } finally {
    $env:Path = $saved.Path
    $env:FAKE_OC_STDIN = $saved.STDIN
    $env:FAKE_OC_ARGS = $saved.ARGS
    $env:FAKE_OC_TUI_CALLS = $saved.TUI_CALLS
    $env:FAKE_OC_CHANGE = $saved.CHANGE
    $env:FAKE_OC_EXIT = $saved.EXIT
    $env:FAKE_OC_LOG = $saved.LOG
    $env:FAKE_OC_TUI_EXIT = $saved.TUI_EXIT
    $env:FAKE_OC_SLEEP = $saved.SLEEP
    $env:FAKE_OC_URL = $saved.URL
  }
}

Describe "oc-run quota classification" {
  BeforeAll {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\bin\oc-run.ps1'), [ref]$null, [ref]$null)
    $fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-QuotaOrUnavailable'}, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
  }
  It "ignores ordinary prose mentioning quota even on failure" {
    'Implementation includes quota and rate limit handling' | Set-Content TestDrive:\quota.log
    (Test-QuotaOrUnavailable TestDrive:\quota.log 1) | Should Be $false
  }
  It "ignores structured assistant text containing an error example" {
    '{"type":"text","part":{"text":"Error: quota exceeded HTTP 429"}}' | Set-Content TestDrive:\quota.log
    (Test-QuotaOrUnavailable TestDrive:\quota.log 1) | Should Be $false
  }
  It "recognizes structured API errors even when attach exits zero" {
    '{"type":"error","error":{"name":"APIError","data":{"statusCode":429,"message":"quota exceeded"}}}' | Set-Content TestDrive:\quota.log
    (Test-QuotaOrUnavailable TestDrive:\quota.log 0) | Should Be $true
  }
  It "recognizes model unavailable errors" {
    '{"type":"error","error":{"message":"model fixture is not available"}}' | Set-Content TestDrive:\quota.log
    (Test-QuotaOrUnavailable TestDrive:\quota.log 1) | Should Be $true
  }
  It "does not classify authentication failure as quota" {
    '{"type":"error","error":{"message":"Unauthorized","statusCode":401}}' | Set-Content TestDrive:\quota.log
    (Test-QuotaOrUnavailable TestDrive:\quota.log 1) | Should Be $false
  }
  It "requires a failed invocation for formatted error fallback" {
    'Error: rate limit exceeded' | Set-Content TestDrive:\quota.log
    (Test-QuotaOrUnavailable TestDrive:\quota.log 0) | Should Be $false
    (Test-QuotaOrUnavailable TestDrive:\quota.log 1) | Should Be $true
  }
  It "accepts ANSI-colored formatted errors" {
    (([char]27) + '[31mError: quota exceeded' + ([char]27) + '[0m') | Set-Content TestDrive:\quota.log
    (Test-QuotaOrUnavailable TestDrive:\quota.log 1) | Should Be $true
  }
}

Describe "oc-run fallback session dispatch" {
  BeforeAll { $fallbackSandbox = New-OpenCodeSandbox }
  AfterAll { Remove-OpenCodeSandbox $fallbackSandbox }

  It "checks the session before fallback and prints the new TUI hint before dispatch" {
    $result = Invoke-OpenCodeRunner $fallbackSandbox -WithFallback
    $result.code | Should Be 5
    $calls = @(Get-Content -LiteralPath $fallbackSandbox.argsFile)
    $calls.Count | Should Be 2
    $calls[0] | Should Match '--session fake-session-1'
    $calls[1] | Should Match '--session fake-session-2'
    $calls[1] | Should Match '--model fixture/fallback'
    [int](Get-Content -Raw -LiteralPath $fallbackSandbox.tuiCalls) | Should Be 2
    $hintIndex = $result.text.IndexOf('TUI: opencode attach http://127.0.0.1:1 -s fake-session-2')
    $dispatchIndex = $result.text.IndexOf('=> opencode fixture/fallback')
    ($hintIndex -ge 0 -and $dispatchIndex -gt $hintIndex) | Should Be $true
  }
}

Describe "oc-run stdin brief transport" {
  BeforeAll {
    $sandbox = New-OpenCodeSandbox
  }
  AfterAll {
    Remove-OpenCodeSandbox $sandbox
  }

  It "truyen brief dai qua stdin UTF-8 thay vi command line" {
    $result = Invoke-OpenCodeRunner $sandbox
    if (-not (Test-Path $sandbox.stdinFile)) {
      throw ("Runner exit={0}, output:{1}{2}" -f $result.code, [Environment]::NewLine, $result.text)
    }
    $received = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($sandbox.stdinFile))
    $args = Get-Content -Raw -LiteralPath $sandbox.argsFile

    # Khong sua file thi runner ket thuc 5, nhung OpenCode gia da nhan du brief.
    $result.code | Should Be 5
    $received.Contains('Mo ta tieng Viet voi dau nhay "quoted".') | Should Be $true
    $received.Length | Should BeGreaterThan 20000
    $args.Contains($sandbox.brief.Substring(0, 100)) | Should Be $false
    $args.Length | Should BeLessThan 1000
    $args | Should Match '--format json'
  }
}

Describe "oc-run high priority safety regressions" {
  BeforeEach { $caseSandbox = New-OpenCodeSandbox }
  AfterEach { Remove-OpenCodeSandbox $caseSandbox }

  It "treats a structured API failure after edits as error even with CLI exit zero" {
    $r = Invoke-OpenCodeRunner $caseSandbox -Change partial -LogText '{"type":"error","error":{"name":"APIError","data":{"message":"quota exceeded"}}}'
    $r.code | Should Be 7
    (Get-Content -Raw (Join-Path $caseSandbox.repo 'change.txt')) | Should Be 'partial'
  }

  It "does not misclassify quoted CLI help in assistant text" {
    (Invoke-OpenCodeRunner $caseSandbox -Change done -LogText '{"type":"text","part":{"text":"Updated opencode run [message..] documentation"}}').code | Should Be 0
  }

  It "still recognizes actual CLI usage errors" {
    (Invoke-OpenCodeRunner $caseSandbox -WithFallback -ExitCode 1 -LogText 'opencode run [message..]').code | Should Be 7
    @(Get-Content $caseSandbox.argsFile).Count | Should Be 1
  }

  It "preserves blocked exit code from the TUI helper" {
    (Invoke-OpenCodeRunner $caseSandbox -TuiExit 10).code | Should Be 10
    (Test-Path $caseSandbox.argsFile) | Should Be $false
  }

  It "detects edits when invoked from a subdirectory" {
    $subdir = Join-Path $caseSandbox.repo 'src'
    New-Item -ItemType Directory -Path $subdir | Out-Null
    Set-Content (Join-Path $caseSandbox.repo 'change.txt') old
    (Invoke-OpenCodeRunner $caseSandbox -Resume -Change new -WorkingDirectory $subdir).code | Should Be 0
  }

  It "blocks a surviving Codex child before OpenCode dispatch" {
    $logs = Join-Path $caseSandbox.repo '.pipeline\logs'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    @{pid=$PID; started=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $logs 'codex-run.lock')
    (Invoke-OpenCodeRunner $caseSandbox).code | Should Be 10
    (Test-Path $caseSandbox.argsFile) | Should Be $false
  }

  It "retains a server uncertainty marker on timeout and blocks the next dispatch" {
    @{test_command='Set-Content -LiteralPath verify.marker -Value ran'} | ConvertTo-Json | Set-Content (Join-Path $caseSandbox.repo '.pipeline\pipeline.config.json')
    & git -C $caseSandbox.repo add .pipeline/pipeline.config.json
    & git -C $caseSandbox.repo commit -qm config
    $r = Invoke-OpenCodeRunner $caseSandbox -Sleep -TimeoutSec 3 -Change partial
    $r.code | Should Be 124
    (Test-Path (Join-Path $caseSandbox.repo 'change.txt')) | Should Be $true
    (Test-Path (Join-Path $caseSandbox.repo 'verify.marker')) | Should Be $false
    $pending = Join-Path $caseSandbox.repo '.pipeline\logs\opencode-pending.json'
    (Test-Path $pending) | Should Be $true
    (Get-Content -Raw $pending | ConvertFrom-Json).session | Should Be 'fake-session-1'
    (Invoke-OpenCodeRunner $caseSandbox).code | Should Be 10
  }

  It "aborts the independent HTTP session and clears the timeout marker only after confirmation" {
    $ready = Join-Path $caseSandbox.root 'server.port'
    $calls = Join-Path $caseSandbox.root 'server.calls'
    $fixture = Join-Path $PSScriptRoot 'fixtures\oc-timeout-server.ps1'
    $args = @('-NoProfile','-File',('"' + $fixture + '"'),'-RepoPath',('"' + $caseSandbox.repo + '"'),'-ReadyFile',('"' + $ready + '"'),'-CallsFile',('"' + $calls + '"'))
    $server = Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
    try {
      $deadline = (Get-Date).AddSeconds(8)
      while (-not (Test-Path $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
      (Test-Path $ready) | Should Be $true
      $url = 'http://127.0.0.1:' + (Get-Content -Raw $ready).Trim()
      (Invoke-OpenCodeRunner $caseSandbox -Sleep -TimeoutSec 2 -ServerUrl $url).code | Should Be 124
      (Get-Content -Raw $calls) | Should Match 'POST /session/fake-session-1/abort\?directory='
      (Test-Path (Join-Path $caseSandbox.repo '.pipeline\logs\opencode-pending.json')) | Should Be $false
      (Invoke-OpenCodeRunner $caseSandbox -ServerUrl $url).code | Should Be 5
    } finally {
      if (-not $server.HasExited) { $server.Kill(); $server.WaitForExit() }
      $server.Dispose()
    }
  }

  It "blocks a competing owner before selecting a session or dispatching CLI" {
    $logs = Join-Path $caseSandbox.repo '.pipeline\logs'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $handle = [IO.File]::Open((Join-Path $logs 'opencode-run.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
      $r = Invoke-OpenCodeRunner $caseSandbox
      $r.code | Should Be 10
      (Test-Path -LiteralPath $caseSandbox.argsFile) | Should Be $false
      (Test-Path -LiteralPath $caseSandbox.tuiCalls) | Should Be $false
    } finally { $handle.Dispose() }
    # A persistent lock file is not a stale owner: releasing its OS handle
    # must allow the next runner to proceed.
    (Invoke-OpenCodeRunner $caseSandbox).code | Should Be 5
  }

  It "releases the lock on an early dirty-worktree exit" {
    Set-Content -LiteralPath (Join-Path $caseSandbox.repo 'change.txt') -Value 'old'
    (Invoke-OpenCodeRunner $caseSandbox).code | Should Be 3
    (Invoke-OpenCodeRunner $caseSandbox -Resume).code | Should Be 5
  }

  It "does not report old dirty work as a successful resume or start fallback over it" {
    Set-Content -LiteralPath (Join-Path $caseSandbox.repo 'change.txt') -Value 'old'
    $r = Invoke-OpenCodeRunner $caseSandbox -Resume -WithFallback
    $r.code | Should Be 5
    @(Get-Content -LiteralPath $caseSandbox.argsFile).Count | Should Be 1
  }

  It "returns a CLI failure despite preexisting changes" {
    Set-Content -LiteralPath (Join-Path $caseSandbox.repo 'change.txt') -Value 'old'
    (Invoke-OpenCodeRunner $caseSandbox -Resume -ExitCode 23).code | Should Be 7
  }

  It "detects actual content changes to an already untracked file" {
    Set-Content -LiteralPath (Join-Path $caseSandbox.repo 'change.txt') -Value 'old'
    (Invoke-OpenCodeRunner $caseSandbox -Resume -Change 'new').code | Should Be 0
  }

  It "detects edits to an already modified tracked file" {
    Set-Content -LiteralPath (Join-Path $caseSandbox.repo 'change.txt') -Value 'baseline'
    & git -C $caseSandbox.repo add change.txt
    & git -C $caseSandbox.repo commit -qm baseline
    Set-Content -LiteralPath (Join-Path $caseSandbox.repo 'change.txt') -Value 'previous attempt'
    (Invoke-OpenCodeRunner $caseSandbox -Resume -Change 'fixed').code | Should Be 0
  }

  It "preserves edits but returns failure when CLI fails after editing" {
    (Invoke-OpenCodeRunner $caseSandbox -Change 'partial' -ExitCode 23).code | Should Be 7
    (Get-Content -Raw -LiteralPath (Join-Path $caseSandbox.repo 'change.txt')) | Should Be 'partial'
  }

  It "fails verification when the configured PowerShell command throws" {
    @{test_command='throw "verification failed"'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $caseSandbox.repo '.pipeline\pipeline.config.json')
    & git -C $caseSandbox.repo add .pipeline/pipeline.config.json
    & git -C $caseSandbox.repo commit -qm config
    $r = Invoke-OpenCodeRunner $caseSandbox -Change 'new'
    $r.code | Should Be 8
    $r.text | Should Match 'TESTS: FAILED'
  }

  It "fails verification on a nonterminating PowerShell error followed by success" {
    @{test_command='Write-Error "verification failed"; Write-Output "done"'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $caseSandbox.repo '.pipeline\pipeline.config.json')
    & git -C $caseSandbox.repo add .pipeline/pipeline.config.json
    & git -C $caseSandbox.repo commit -qm config
    (Invoke-OpenCodeRunner $caseSandbox -Change 'new').code | Should Be 8
  }
}
