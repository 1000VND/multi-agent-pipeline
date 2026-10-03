. (Join-Path $PSScriptRoot '..\bin\pipeline-runtime.ps1')

Describe 'shared pipeline writer guard' {
  BeforeEach {
    $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $repo '.pipeline\logs') -Force | Out-Null
  }
  It 'excludes both lane directions and releases on dispose' {
    foreach ($lane in @('codex','opencode')) {
      $other = if ($lane -eq 'codex') { 'opencode' } else { 'codex' }
      $guard = Enter-PipelineRun $repo $lane
      try { { Enter-PipelineRun $repo $other } | Should Throw }
      finally { $guard.Dispose() }
      $next = Enter-PipelineRun $repo $other
      $next.Dispose()
    }
  }
  It 'blocks both lanes on an unconfirmed OpenCode session without clearing the marker' {
    $marker = Join-Path $repo '.pipeline\logs\opencode-pending.json'
    '{}' | Set-Content $marker
    { Enter-PipelineRun $repo 'codex' } | Should Throw
    { Enter-PipelineRun $repo 'opencode' } | Should Throw
    (Test-Path $marker) | Should Be $true
  }
}

Describe 'OpenCode server abort confirmation' {
  BeforeEach {
    $repo = 'C:\fixture project'
    $global:PipelineAbortFixture = @{ repo=$repo; ack=$true; status=[pscustomobject]@{}; fail=$false; calls=@() }
    Mock Invoke-RestMethod {
      param($Uri, $Method)
      $state = $global:PipelineAbortFixture
      $state.calls += "$Method $(([uri]$Uri).AbsoluteUri)"
      if ($state.fail) { throw 'offline' }
      if ($Uri -match '/abort\?') { return $state.ack }
      if ($Uri -match '/status\?') { return $state.status }
      return [pscustomobject]@{id='ses_test'; directory=$state.repo}
    }
  }
  AfterAll { Remove-Variable PipelineAbortFixture -Scope Global -ErrorAction SilentlyContinue }
  It 'aborts only the selected session in the correct directory and confirms idle' {
    (Stop-OpenCodeSession 'http://127.0.0.1:4097' 'ses_test' $repo) | Should Be $true
    ($global:PipelineAbortFixture.calls -join "`n") | Should Match 'Post http://127.0.0.1:4097/session/ses_test/abort\?directory=C%3A%5Cfixture%20project'
  }
  It 'does not abort a session from a different repo' {
    $global:PipelineAbortFixture.repo = 'C:\different'
    (Stop-OpenCodeSession 'http://localhost:4097' 'ses_test' $repo) | Should Be $false
    # Probing the server version is allowed; any POST (abort) is not.
    @($global:PipelineAbortFixture.calls | Where-Object { $_ -match '^Post ' }).Count | Should Be 0
  }
  It 'fails closed if abort fails or returns false' {
    $global:PipelineAbortFixture.ack = $false
    (Stop-OpenCodeSession 'http://localhost:4097' 'ses_test' $repo) | Should Be $false
    $global:PipelineAbortFixture.fail = $true
    (Stop-OpenCodeSession 'http://localhost:4097' 'ses_test' $repo) | Should Be $false
  }
  It 'does not accept busy or malformed status as stopped' {
    $global:PipelineAbortFixture.status = [pscustomobject]@{ses_test=[pscustomobject]@{type='busy'}}
    (Stop-OpenCodeSession 'http://localhost:4097' 'ses_test' $repo) | Should Be $false
    $global:PipelineAbortFixture.status = $null
    (Stop-OpenCodeSession 'http://localhost:4097' 'ses_test' $repo) | Should Be $false
    $global:PipelineAbortFixture.status = [pscustomobject]@{error='offline'}
    (Stop-OpenCodeSession 'http://localhost:4097' 'ses_test' $repo) | Should Be $false
  }
}

Describe 'OpenCode V2 detection and Basic auth' {
  BeforeEach {
    $savedPassword = $env:OPENCODE_PASSWORD
    $savedServerPassword = $env:OPENCODE_SERVER_PASSWORD
    $env:OPENCODE_PASSWORD = 'fixture-password'
    $env:OPENCODE_SERVER_PASSWORD = $null
    $global:PipelineV2Fixture = @{ calls = @(); auth = @(); status = 0; directory = 'C:\fixture v2'; active = [pscustomobject]@{} }
    Mock Invoke-RestMethod {
      param($Uri, $Method, $Headers)
      $state = $global:PipelineV2Fixture
      $state.calls += "$Method $Uri"
      $state.auth += [string]$Headers.Authorization
      if ($state.status) {
        $failure = New-Object System.Exception 'http failure'
        $failure | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $state.status })
        throw $failure
      }
      if ($Uri -like '*/api/info') { return [pscustomobject]@{ version = '2.0.16'; pid = 42; urls = @(); paths = [pscustomobject]@{ tmp = 'x' } } }
      if ($Uri -like '*/api/session/active') { return [pscustomobject]@{ data = $state.active } }
      if ($Uri -like '*/interrupt') { return [pscustomobject]@{ interrupted = $true } }
      if ($Uri -like '*/api/session/ses_v2') {
        return [pscustomobject]@{ data = [pscustomobject]@{ id = 'ses_v2'; location = [pscustomobject]@{ directory = $state.directory } } }
      }
      throw "Unexpected HTTP call $Method $Uri"
    }
  }
  AfterEach {
    $env:OPENCODE_PASSWORD = $savedPassword
    $env:OPENCODE_SERVER_PASSWORD = $savedServerPassword
    Clear-OpenCodeAuth
  }
  AfterAll { Remove-Variable PipelineV2Fixture -Scope Global -ErrorAction SilentlyContinue }

  It 'detects V2 from /api/info and authenticates as user opencode' {
    (Initialize-OpenCodeAuth 'C:\fixture v2').source | Should Be 'env:OPENCODE_PASSWORD'
    (Get-OpenCodeApiPrefix 'http://127.0.0.1:4097') | Should Be '/api'
    $global:PipelineV2Fixture.calls[0] | Should Match '/api/info$'
    $expected = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('opencode:fixture-password'))
    $global:PipelineV2Fixture.auth[0] | Should Be $expected
  }
  It 'reports HTTP 401 as a password-protected server instead of a missing one' {
    Initialize-OpenCodeAuth 'C:\fixture v2' | Out-Null
    $global:PipelineV2Fixture.status = 401
    $probe = Get-OpenCodeServerProbe 'http://127.0.0.1:4097'
    $probe.authRejected | Should Be $true
    $probe.prefix | Should Be ''
  }
  It 'interrupts a V2 session in the same repo and confirms it left the active map' {
    Initialize-OpenCodeAuth 'C:\fixture v2' | Out-Null
    (Stop-OpenCodeSession 'http://127.0.0.1:4097' 'ses_v2' 'C:/fixture v2') | Should Be $true
    ($global:PipelineV2Fixture.calls -join "`n") | Should Match 'Post http://127.0.0.1:4097/api/session/ses_v2/interrupt'
  }
  It 'never interrupts a V2 session that belongs to another repo' {
    Initialize-OpenCodeAuth 'C:\fixture v2' | Out-Null
    $global:PipelineV2Fixture.directory = 'C:\other'
    (Stop-OpenCodeSession 'http://127.0.0.1:4097' 'ses_v2' 'C:/fixture v2') | Should Be $false
    @($global:PipelineV2Fixture.calls | Where-Object { $_ -match '^Post ' }).Count | Should Be 0
  }
  It 'does not confirm a V2 session that stays active' {
    Initialize-OpenCodeAuth 'C:\fixture v2' | Out-Null
    $global:PipelineV2Fixture.active = [pscustomobject]@{ ses_v2 = [pscustomobject]@{ type = 'running' } }
    (Stop-OpenCodeSession 'http://127.0.0.1:4097' 'ses_v2' 'C:/fixture v2') | Should Be $false
  }
}

Describe 'pipeline OpenCode credential' {
  BeforeEach {
    $savedPassword = $env:OPENCODE_PASSWORD
    $savedServerPassword = $env:OPENCODE_SERVER_PASSWORD
    $env:OPENCODE_PASSWORD = $null
    $env:OPENCODE_SERVER_PASSWORD = $null
    $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $repo | Out-Null
  }
  AfterEach {
    $env:OPENCODE_PASSWORD = $savedPassword
    $env:OPENCODE_SERVER_PASSWORD = $savedServerPassword
  }
  It 'prefers OPENCODE_PASSWORD, then OPENCODE_SERVER_PASSWORD, without writing a file' {
    $env:OPENCODE_SERVER_PASSWORD = 'server-password'
    (Get-OpenCodeServerPassword $repo).password | Should Be 'server-password'
    $env:OPENCODE_PASSWORD = 'client-password'
    (Get-OpenCodeServerPassword $repo).password | Should Be 'client-password'
    (Test-Path (Join-Path $repo '.pipeline\logs\opencode-auth.json')) | Should Be $false
  }
  It 'creates one git-ignored per-repo password and reuses it' {
    $first = Get-OpenCodeServerPassword $repo
    $first.source | Should Be 'file'
    $first.file | Should Be (Join-Path $repo '.pipeline\logs\opencode-auth.json')
    $first.password.Length | Should BeGreaterThan 30
    (Get-OpenCodeServerPassword $repo).password | Should Be $first.password
  }
}

Describe 'worktree fingerprint' {
  It 'detects new edits to an already dirty file with a non-ASCII name' {
    $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $repo | Out-Null
    & git -C $repo init -q 2>$null
    # Build the name from code points: this file stays ASCII for PowerShell 5.1.
    $name = 'ti' + [char]0x1EBF + 'ng-vi' + [char]0x1EC7 + 't.txt'
    $file = Join-Path $repo $name
    [IO.File]::WriteAllText($file, 'attempt 1')
    $before = Get-PipelineWorktreeFingerprint $repo
    [IO.File]::WriteAllText($file, 'attempt 2')
    $after = Get-PipelineWorktreeFingerprint $repo
    $after | Should Not Be $before
    $after | Should Match ([regex]::Escape($name) + ':[0-9A-F]{64}')
  }
}
