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
  @'
param([string]$Key, [string]$Title, [string]$Url, [string]$Session, [switch]$Fresh, [switch]$NoWindow)
$count = 0
if (Test-Path -LiteralPath $env:FAKE_OC_TUI_CALLS) {
  $count = [int](Get-Content -Raw -LiteralPath $env:FAKE_OC_TUI_CALLS)
}
$count++
Set-Content -LiteralPath $env:FAKE_OC_TUI_CALLS -Value $count
if ($count -gt 1) { Write-Output "CONTEXT: fixture rollover before fallback" }
Write-Output "URL=http://127.0.0.1:4096"
Write-Output "SESSION=fake-session-$count"
'@ | Set-Content -LiteralPath (Join-Path $bin "oc-tui.ps1") -Encoding UTF8

  @'
@echo off
echo %*>>"%FAKE_OC_ARGS%"
powershell.exe -NoProfile -Command "[Console]::OpenStandardInput().CopyTo([IO.File]::OpenWrite($env:FAKE_OC_STDIN))"
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

function Invoke-OpenCodeRunner($sandbox, [switch]$WithFallback) {
  $saved = @{
    Path = $env:Path
    STDIN = $env:FAKE_OC_STDIN
    ARGS = $env:FAKE_OC_ARGS
    TUI_CALLS = $env:FAKE_OC_TUI_CALLS
  }
  $env:Path = "$($sandbox.fake);$($saved.Path)"
  $env:FAKE_OC_STDIN = $sandbox.stdinFile
  $env:FAKE_OC_ARGS = $sandbox.argsFile
  $env:FAKE_OC_TUI_CALLS = $sandbox.tuiCalls
  try {
    Push-Location $sandbox.repo
    try {
      $fallbackArgs = @(if ($WithFallback) { '-Fallback'; 'fixture/fallback' } else { '-NoFallback' })
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
    $hintIndex = $result.text.IndexOf('TUI: opencode attach http://127.0.0.1:4096 -s fake-session-2')
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
  }
}
