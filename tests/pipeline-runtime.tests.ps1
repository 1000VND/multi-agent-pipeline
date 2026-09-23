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
    $global:PipelineAbortFixture.calls.Count | Should Be 1
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
