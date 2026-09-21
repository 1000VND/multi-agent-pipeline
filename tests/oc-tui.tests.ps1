# Pester 3.4/Windows PowerShell 5.1. Mock HTTP only: no cloud calls or real TUI.
$script:tuiSource = Join-Path (Split-Path -Parent $PSScriptRoot) "bin\oc-tui.ps1"

function New-UsageMessage($inputTokens, $created = 1, $provider = "right") {
  return [pscustomobject]@{
    info = [pscustomobject]@{
      role = "assistant"; providerID = $provider; modelID = "shared-model"
      time = [pscustomobject]@{ created = $created }
      tokens = [pscustomobject]@{
        input = $inputTokens; output = 0; reasoning = 0
        cache = [pscustomobject]@{ read = 0; write = 0 }
      }
    }
  }
}

function Read-TestMap {
  return Get-Content -Raw -LiteralPath $script:testMapPath | ConvertFrom-Json
}

function Save-TestMap($value) {
  $value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:testMapPath -Encoding UTF8
}

function Invoke-TestTui([switch]$Fresh, [string]$Session = "") {
  $global:PipelineOcTuiTestState.messages = $script:messages
  $global:PipelineOcTuiTestState.providers = $script:providers
  $global:PipelineOcTuiTestState.failMessages = $script:failMessages
  $global:PipelineOcTuiTestState.missingSession = $script:missingSession
  Push-Location $script:testRepo
  try {
    $parameters = @{ Key = "claude-A"; Url = "http://127.0.0.1:4097"; NoWindow = $true }
    if ($Fresh) { $parameters.Fresh = $true }
    if ($Session) { $parameters.Session = $Session }
    return (& $script:tuiSource @parameters | Out-String)
  } finally {
    $script:createdCount = $global:PipelineOcTuiTestState.createdCount
    Pop-Location
  }
}

Describe "OpenCode session context rollover and complete association history" {
  AfterAll {
    Remove-Variable -Name PipelineOcTuiTestState -Scope Global -ErrorAction SilentlyContinue
  }

  BeforeEach {
    $script:testRepo = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path (Join-Path $script:testRepo ".pipeline") -Force | Out-Null
    & git -C $script:testRepo init -q
    $script:testMapPath = Join-Path $script:testRepo ".pipeline\tui-map.json"
    Save-TestMap ([pscustomobject]@{
      "claude-A" = [pscustomobject]@{ opencode_session = "ses_old"; last_used = "2026-09-01T01:00:00"; url = "http://127.0.0.1:4097"; custom = "preserved" }
      "claude-B" = [pscustomobject]@{ opencode_session = "ses_other"; custom = "other-key" }
    })
    $script:messages = @((New-UsageMessage 40000))
    $script:providers = '{"all":[{"id":"wrong","models":{"shared-model":{"limit":{"context":40000}}}},{"id":"right","models":{"shared-model":{"limit":{"context":100000}}}}]}' | ConvertFrom-Json
    $script:createdCount = 0
    $script:missingSession = ""
    $script:failMessages = $false
    # Pester 3.4 executes a mock in the called script's scope. Store one
    # shared state object explicitly; $script: inside that mock would point
    # at oc-tui.ps1 instead of this test file.
    $global:PipelineOcTuiTestState = @{
      repo = $script:testRepo
      messages = $script:messages
      providers = $script:providers
      createdCount = 0
      missingSession = ""
      failMessages = $false
      failSession = $false
      failCreate = $false
    }
    Mock Invoke-RestMethod {
      param($Uri, $Method)
      $state = $global:PipelineOcTuiTestState
      if ($Uri -like "*/project/current") { return [pscustomobject]@{ worktree = $state.repo } }
      if ($Uri -eq "http://127.0.0.1:4097/session" -and $Method -eq "Post") {
        if ($state.failCreate) { throw "create API offline" }
        $state.createdCount++
        return [pscustomobject]@{ id = "ses_new_$($state.createdCount)"; directory = $state.repo }
      }
      if ($Uri -match "/session/[^/]+/message\?limit=100$") {
        if ($state.failMessages) { throw "usage API offline" }
        return $state.messages
      }
      if ($Uri -like "*/provider") { return $state.providers }
      if ($Uri -match "/session/([^/]+)$") {
        if ($state.failSession) { throw "session API offline" }
        if ($Matches[1] -eq $state.missingSession) {
          $missing = New-Object System.Exception "session missing"
          $missing | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 404 })
          throw $missing
        }
        return [pscustomobject]@{ directory = $state.repo; tokens = [pscustomobject]@{ input = 90000000 } }
      }
      throw "Unexpected HTTP call $Method $Uri"
    }
    Mock Start-Process { throw "No window or process is allowed in this test" }
  }

  It "does not rotate at exactly 80 percent" {
    $script:messages = @((New-UsageMessage 80000))
    $text = Invoke-TestTui
    (Read-TestMap).'claude-A'.opencode_session | Should Be "ses_old"
    $script:createdCount | Should Be 0
    $text | Should Match "TUI: opencode attach http://127.0.0.1:4097 -s ses_old"
  }

  It "rotates at 80001 of 100000 tokens even though displayed percentage rounds to 80" {
    $script:messages = @((New-UsageMessage 80001))
    $text = Invoke-TestTui
    $record = (Read-TestMap).'claude-A'
    $record.opencode_session | Should Be "ses_new_1"
    @($record.opencode_sessions).Count | Should Be 2
    $old = $record.opencode_sessions | Where-Object { $_.session_id -eq "ses_old" }
    $old.retired_reason | Should Be "context_over_80%"
    $old.last_context_tokens | Should Be 80001
    $old.context_window_tokens | Should Be 100000
    $old.created_at | Should Be "2026-09-01T01:00:00"
    $text | Should Match "TUI: opencode attach http://127.0.0.1:4097 -s ses_new_1"
  }

  It "does not rotate just below the threshold after rounding" {
    $script:messages = @((New-UsageMessage 79999))
    Invoke-TestTui | Out-Null
    (Read-TestMap).'claude-A'.opencode_session | Should Be "ses_old"
  }

  It "honors a customized integer threshold" {
    '{"session_rollover":{"context_percent":70}}' | Set-Content -LiteralPath (Join-Path $script:testRepo '.pipeline\pipeline.config.json')
    $script:messages = @((New-UsageMessage 75000))
    Invoke-TestTui | Out-Null
    (Read-TestMap).'claude-A'.opencode_session | Should Be "ses_new_1"
  }

  It "uses default 80 for an invalid fractional threshold instead of rounding it" {
    '{"session_rollover":{"context_percent":70.5}}' | Set-Content -LiteralPath (Join-Path $script:testRepo '.pipeline\pipeline.config.json')
    $script:messages = @((New-UsageMessage 75000))
    Invoke-TestTui | Out-Null
    (Read-TestMap).'claude-A'.opencode_session | Should Be "ses_old"
  }

  It "uses latest useful assistant usage despite newer empty or user messages" {
    $user = New-UsageMessage 10 4
    $user.info.role = "user"
    $script:messages = @((New-UsageMessage 0 3), $user, (New-UsageMessage 80001 2), (New-UsageMessage 100 1))
    Invoke-TestTui | Out-Null
    (Read-TestMap).'claude-A'.opencode_session | Should Be "ses_new_1"
  }

  It "uses the most recent request and not summed lifetime usage" {
    $script:messages = @((New-UsageMessage 70000 1), (New-UsageMessage 60000 2))
    Invoke-TestTui | Out-Null
    $record = (Read-TestMap).'claude-A'
    $record.opencode_session | Should Be "ses_old"
    $record.opencode_sessions[0].last_context_tokens | Should Be 60000
  }

  It "does not reuse stale high usage from before completed compaction" {
    $summary = New-UsageMessage 95000 2
    $summary.info | Add-Member -NotePropertyName summary -NotePropertyValue $true
    $summary.info.time | Add-Member -NotePropertyName completed -NotePropertyValue 3
    $script:messages = @((New-UsageMessage 90000 1), $summary)
    $text = Invoke-TestTui
    (Read-TestMap).'claude-A'.opencode_session | Should Be "ses_old"
    $script:createdCount | Should Be 0
    $text | Should Match "CANH BAO CONTEXT"
  }

  It "uses new ordinary usage after completed compaction" {
    $summary = New-UsageMessage 95000 2
    $summary.info | Add-Member -NotePropertyName summary -NotePropertyValue $true
    $summary.info.time | Add-Member -NotePropertyName completed -NotePropertyValue 3
    $script:messages = @((New-UsageMessage 90000 1), $summary, (New-UsageMessage 50000 4))
    Invoke-TestTui | Out-Null
    $record = (Read-TestMap).'claude-A'
    $record.opencode_session | Should Be "ses_old"
    $record.opencode_sessions[0].last_context_tokens | Should Be 50000
  }

  It "counts disjoint cache and reasoning buckets once and ignores tokens.total" {
    $message = New-UsageMessage 20000
    $message.info.tokens.cache.read = 50000
    $message.info.tokens.cache.write = 5000
    $message.info.tokens.output = 4000
    $message.info.tokens.reasoning = 1001
    $message.info.tokens | Add-Member -NotePropertyName total -NotePropertyValue 900000
    $script:messages = @($message)
    Invoke-TestTui | Out-Null
    $old = (Read-TestMap).'claude-A'.opencode_sessions | Where-Object { $_.session_id -eq "ses_old" }
    $old.last_context_tokens | Should Be 80001
    $old.retired_reason | Should Be "context_over_80%"
  }

  It "matches provider and model together instead of the first model with matching id" {
    $script:messages = @((New-UsageMessage 60000))
    Invoke-TestTui | Out-Null
    $record = (Read-TestMap).'claude-A'
    $record.opencode_session | Should Be "ses_old"
    $record.opencode_sessions[0].context_window_tokens | Should Be 100000
  }

  It "warns and preserves session if its exact provider has no context limit" {
    $script:messages = @((New-UsageMessage 90000 1 "unknown-provider"))
    $text = Invoke-TestTui
    (Read-TestMap).'claude-A'.opencode_session | Should Be "ses_old"
    $text | Should Match "CANH BAO CONTEXT"
    $script:createdCount | Should Be 0
  }

  It "warns and preserves session when usage API fails" {
    $script:failMessages = $true
    $text = Invoke-TestTui
    (Read-TestMap).'claude-A'.opencode_session | Should Be "ses_old"
    $text | Should Match "CANH BAO CONTEXT"
  }

  It "does not mistake a session API transport failure for a deleted session" {
    $global:PipelineOcTuiTestState.failSession = $true
    $text = Invoke-TestTui
    (Read-TestMap).'claude-A'.opencode_session | Should Be "ses_old"
    $script:createdCount | Should Be 0
    $text | Should Match "CANH BAO CONTEXT"
  }

  It "preserves legacy associations, project metadata and other Claude sessions" {
    Invoke-TestTui | Out-Null
    $map = Read-TestMap
    $map.'claude-A'.custom | Should Be "preserved"
    $map.'claude-B'.custom | Should Be "other-key"
    $map.'claude-B'.opencode_session | Should Be "ses_other"
    @($map.'claude-A'.opencode_sessions).Count | Should Be 1
    $map.'claude-A'.opencode_sessions[0].created_reason | Should Be "legacy_map"
    $map.'claude-A'.opencode_sessions[0].url | Should Be "http://127.0.0.1:4097"
  }

  It "keeps every Fresh session and records a reopen command" {
    Invoke-TestTui -Fresh | Out-Null
    Invoke-TestTui -Fresh | Out-Null
    Invoke-TestTui | Out-Null
    $record = (Read-TestMap).'claude-A'
    @($record.opencode_sessions).Count | Should Be 3
    $record.opencode_session | Should Be "ses_new_2"
    @($record.opencode_sessions | Where-Object { $_.retired_reason -eq "fresh" }).Count | Should Be 2
    $latest = $record.opencode_sessions | Where-Object { $_.session_id -eq "ses_new_2" }
    $latest.resume_command | Should Be "opencode attach http://127.0.0.1:4097 -s ses_new_2"
    [bool]$latest.last_used | Should Be $true
  }

  It "records unavailable old session rather than losing its association" {
    $script:missingSession = "ses_old"
    Invoke-TestTui | Out-Null
    $record = (Read-TestMap).'claude-A'
    @($record.opencode_sessions).Count | Should Be 2
    $record.opencode_sessions[0].retired_reason | Should Be "unavailable"
  }

  It "honors explicit session and preserves the formerly active one" {
    Invoke-TestTui -Session "ses_pinned" | Out-Null
    $record = (Read-TestMap).'claude-A'
    $record.opencode_session | Should Be "ses_pinned"
    @($record.opencode_sessions).Count | Should Be 2
    $record.opencode_sessions[0].retired_reason | Should Be "explicit_selection"
  }

  It "also rotates an explicitly selected session over 80 percent" {
    $script:messages = @((New-UsageMessage 90000))
    Invoke-TestTui -Session "ses_pinned" | Out-Null
    $record = (Read-TestMap).'claude-A'
    $record.opencode_session | Should Be "ses_new_1"
    @($record.opencode_sessions).Count | Should Be 3
    $pinned = $record.opencode_sessions | Where-Object { $_.session_id -eq "ses_pinned" }
    $pinned.retired_reason | Should Be "context_over_80%"
  }

  It "preserves a selected high-usage session even when replacement creation fails" {
    $script:messages = @((New-UsageMessage 90000))
    $global:PipelineOcTuiTestState.failCreate = $true
    { Invoke-TestTui -Session "ses_pinned" } | Should Throw
    $record = (Read-TestMap).'claude-A'
    @($record.opencode_sessions).Count | Should Be 2
    $pinned = $record.opencode_sessions | Where-Object { $_.session_id -eq "ses_pinned" }
    $pinned.retired_reason | Should Be "context_over_80%"
    $pinned.resume_command | Should Be "opencode attach http://127.0.0.1:4097 -s ses_pinned"
  }

  It "does not silently substitute a different explicit session when it is unavailable" {
    $script:missingSession = "ses_pinned"
    { Invoke-TestTui -Session "ses_pinned" } | Should Throw
    (Read-TestMap).'claude-A'.opencode_session | Should Be "ses_old"
    $script:createdCount | Should Be 0
  }

  It "deduplicates history while keeping metadata from duplicate entries" {
    $map = Read-TestMap
    $map.'claude-A' | Add-Member -NotePropertyName opencode_sessions -NotePropertyValue @(
      [pscustomobject]@{ session_id = "ses_old"; created_at = "2026-08-01T00:00:00" },
      [pscustomobject]@{ session_id = "ses_old"; note = "keep this" }
    )
    Save-TestMap $map
    Invoke-TestTui | Out-Null
    $history = (Read-TestMap).'claude-A'.opencode_sessions
    @($history).Count | Should Be 1
    $history[0].created_at | Should Be "2026-08-01T00:00:00"
    $history[0].note | Should Be "keep this"
  }

  It "fails closed instead of overwriting malformed history" {
    "{bad json" | Set-Content -LiteralPath $script:testMapPath
    { Invoke-TestTui } | Should Throw
    (Get-Content -Raw $script:testMapPath).Trim() | Should Be "{bad json"
    $script:createdCount | Should Be 0
  }

  It "requires a Claude key before any session API or window action" {
    $savedHostId = $env:CLAUDE_CODE_HOST_SESSION_ID
    $savedId = $env:CLAUDE_CODE_SESSION_ID
    try {
      $env:CLAUDE_CODE_HOST_SESSION_ID = ""
      $env:CLAUDE_CODE_SESSION_ID = ""
      Push-Location $script:testRepo
      try {
        & $script:tuiSource -NoWindow -Url "http://127.0.0.1:4097" | Out-Null
        $LASTEXITCODE | Should Be 11
      }
      finally { Pop-Location }
    } finally {
      $env:CLAUDE_CODE_HOST_SESSION_ID = $savedHostId
      $env:CLAUDE_CODE_SESSION_ID = $savedId
    }
    Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
  }
}
