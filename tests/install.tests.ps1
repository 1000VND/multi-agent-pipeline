# Pester 3.4 / Windows PowerShell 5.1: real installer, temporary git projects.
# No user project, model call, or interactive window is used.
$script:installPackageRoot = Split-Path -Parent $PSScriptRoot
$script:installerPath = Join-Path $script:installPackageRoot "install.ps1"
$script:installTemplatePath = Join-Path $script:installPackageRoot "templates\pipeline.config.json"

function New-InstallSandbox {
  $root = Join-Path ([IO.Path]::GetTempPath()) ("pipeline-install-test-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path (Join-Path $root ".pipeline") -Force | Out-Null
  & git -C $root init -q 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Cannot initialize temporary git project: $root" }
  return @{ root = $root; configPath = Join-Path $root ".pipeline\pipeline.config.json" }
}

function Remove-InstallSandbox($sandbox) {
  if (-not $sandbox -or -not $sandbox.root -or -not (Test-Path -LiteralPath $sandbox.root)) { return }
  $full = [IO.Path]::GetFullPath($sandbox.root).TrimEnd('\', '/')
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if ((Split-Path -Parent $full) -ne $temp -or (Split-Path -Leaf $full) -notmatch '^pipeline-install-test-[a-f0-9]{32}$') {
    throw "Refusing to remove unrecognized installer sandbox: $full"
  }
  Remove-Item -LiteralPath $full -Recurse -Force
}

function Invoke-TestInstaller($sandbox) {
  $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:installerPath -Target $sandbox.root 2>&1 | Out-String)
  return @{ code = $LASTEXITCODE; text = $output }
}

function Get-InstallTemplate {
  return (Get-Content -LiteralPath $script:installTemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-InstallConfig($sandbox, $config) {
  $config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $sandbox.configPath -Encoding UTF8
}

function Read-InstallConfig($sandbox) {
  return (Get-Content -LiteralPath $sandbox.configPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-ModelOrder($entries) {
  return (@($entries | ForEach-Object { "{0}:{1}" -f $_.model, $_.variant }) -join '|')
}

Describe "installer config migrations" {
  BeforeEach { $installSandbox = New-InstallSandbox }
  AfterEach { Remove-InstallSandbox $installSandbox }

  It "installs the default 80 percent session rollover setting for a new project" {
    $result = Invoke-TestInstaller $installSandbox
    $result.code | Should Be 0
    (Read-InstallConfig $installSandbox).session_rollover.context_percent | Should Be 80
  }

  It "migrates legacy fallback while preserving project and custom settings" {
    $config = [pscustomobject]@{
      project_name = "kept-project"
      test_command = "dotnet test"
      test_command_targeted = "dotnet test --filter TestName"
      timeout_sec = 1800
      forbidden_paths = @(".claude/", "custom/", "**/appsettings*.json")
      rules_docs = @("CLAUDE.md", ".claude/rules/client.md")
      custom_setting = [pscustomobject]@{ enabled = $true; labels = @("one", "two") }
      model_policy = [pscustomobject]@{
        custom_lane = [pscustomobject]@{ mode = "keep" }
        opencode = [pscustomobject]@{ primary = "custom/primary"; variant = "custom-variant"; fallback = "opencode-go/mimo-v2.5-pro"; custom_flag = "keep" }
        codex = [pscustomobject]@{ default = [pscustomobject]@{ model = "keep-codex"; reasoning_effort = "keep-effort" }; forbidden = @("custom/forbidden") }
      }
    }
    Save-InstallConfig $installSandbox $config
    $rulesPath = Join-Path $installSandbox.root ".pipeline\PROJECT_RULES.md"
    Set-Content -LiteralPath $rulesPath -Value "Custom project rules" -Encoding UTF8

    $result = Invoke-TestInstaller $installSandbox
    $actual = Read-InstallConfig $installSandbox
    $template = Get-InstallTemplate
    $result.code | Should Be 0
    $result.text | Should Match 'MIGRATE: .pipeline\\pipeline.config.json'
    $actual.project_name | Should Be $config.project_name
    $actual.test_command | Should Be $config.test_command
    $actual.test_command_targeted | Should Be $config.test_command_targeted
    $actual.timeout_sec | Should Be 1800
    ($actual.forbidden_paths -join '|') | Should Be ($config.forbidden_paths -join '|')
    ($actual.rules_docs -join '|') | Should Be ($config.rules_docs -join '|')
    ($actual.custom_setting | ConvertTo-Json -Compress) | Should Be ($config.custom_setting | ConvertTo-Json -Compress)
    ($actual.model_policy.codex | ConvertTo-Json -Depth 10 -Compress) | Should Be ($config.model_policy.codex | ConvertTo-Json -Depth 10 -Compress)
    $actual.model_policy.custom_lane.mode | Should Be "keep"
    $actual.model_policy.opencode.primary | Should Be "custom/primary"
    $actual.model_policy.opencode.variant | Should Be "custom-variant"
    $actual.model_policy.opencode.custom_flag | Should Be "keep"
    [bool]$actual.model_policy.opencode.PSObject.Properties["fallback"] | Should Be $false
    (Get-ModelOrder $actual.model_policy.opencode.fallback_on_no_change) | Should Be (Get-ModelOrder $template.model_policy.opencode.fallback_on_no_change)
    (Get-ModelOrder $actual.model_policy.opencode.fallback_on_quota) | Should Be (Get-ModelOrder $template.model_policy.opencode.fallback_on_quota)
    $actual.session_rollover.context_percent | Should Be 80
    (Get-Content -LiteralPath $rulesPath -Raw).Trim() | Should Be "Custom project rules"
  }

  It "adds missing session settings when fallback is already current and does not rewrite on a second install" {
    $config = Get-InstallTemplate
    [void]$config.PSObject.Properties.Remove("session_rollover")
    Save-InstallConfig $installSandbox $config

    $result = Invoke-TestInstaller $installSandbox
    $result.code | Should Be 0
    $result.text | Should Match 'MIGRATE: .pipeline\\pipeline.config.json'
    (Read-InstallConfig $installSandbox).session_rollover.context_percent | Should Be 80
    $before = Get-Content -LiteralPath $installSandbox.configPath -Raw
    $beforeTime = (Get-Item -LiteralPath $installSandbox.configPath).LastWriteTimeUtc

    $second = Invoke-TestInstaller $installSandbox
    $second.code | Should Be 0
    $second.text | Should Not Match 'MIGRATE:'
    $second.text | Should Match 'GIU NGUYEN: .pipeline\\pipeline.config.json'
    (Get-Content -LiteralPath $installSandbox.configPath -Raw) | Should Be $before
    (Get-Item -LiteralPath $installSandbox.configPath).LastWriteTimeUtc | Should Be $beforeTime
  }

  It "fills a missing context percentage inside an existing session object and keeps its other fields" {
    $config = Get-InstallTemplate
    [void]$config.session_rollover.PSObject.Properties.Remove("context_percent")
    $config.session_rollover | Add-Member -NotePropertyName "custom_setting" -NotePropertyValue "keep"
    Save-InstallConfig $installSandbox $config

    $result = Invoke-TestInstaller $installSandbox
    $result.code | Should Be 0
    $actual = Read-InstallConfig $installSandbox
    $actual.session_rollover.context_percent | Should Be 80
    $actual.session_rollover.custom_setting | Should Be "keep"
  }

  It "preserves a customized context threshold" {
    $config = Get-InstallTemplate
    $config.session_rollover.context_percent = 90
    Save-InstallConfig $installSandbox $config
    $before = Get-Content -LiteralPath $installSandbox.configPath -Raw

    $result = Invoke-TestInstaller $installSandbox
    $result.code | Should Be 0
    $result.text | Should Not Match 'MIGRATE:'
    (Read-InstallConfig $installSandbox).session_rollover.context_percent | Should Be 90
    (Get-Content -LiteralPath $installSandbox.configPath -Raw) | Should Be $before
  }

  It "persists missing primary and variant defaults even when fallback arrays are unchanged" {
    $config = Get-InstallTemplate
    [void]$config.model_policy.opencode.PSObject.Properties.Remove("primary")
    [void]$config.model_policy.opencode.PSObject.Properties.Remove("variant")
    Save-InstallConfig $installSandbox $config

    $result = Invoke-TestInstaller $installSandbox
    $result.code | Should Be 0
    $result.text | Should Match 'MIGRATE:'
    $actual = Read-InstallConfig $installSandbox
    $actual.model_policy.opencode.primary | Should Be "opencode-go/deepseek-v4.1-flash"
    $actual.model_policy.opencode.variant | Should Be "max"
  }

  It "leaves invalid JSON untouched and reports a warning without claiming migration succeeded" {
    Set-Content -LiteralPath $installSandbox.configPath -Value '{"project_name": "broken",' -Encoding UTF8
    $before = Get-Content -LiteralPath $installSandbox.configPath -Raw
    $beforeTime = (Get-Item -LiteralPath $installSandbox.configPath).LastWriteTimeUtc

    $result = Invoke-TestInstaller $installSandbox
    $result.code | Should Be 0
    $result.text | Should Match 'CANH BAO: khong doc duoc config hop le'
    $result.text | Should Not Match 'MIGRATE:'
    $result.text | Should Match 'GIU NGUYEN: .pipeline\\pipeline.config.json'
    (Get-Content -LiteralPath $installSandbox.configPath -Raw) | Should Be $before
    (Get-Item -LiteralPath $installSandbox.configPath).LastWriteTimeUtc | Should Be $beforeTime
  }
}
