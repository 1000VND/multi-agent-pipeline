# Shared OpenCode/API and pipeline safety helpers. Dot-source only; no requests
# or processes are started on load.
function Get-OpenCodeApiPrefix($baseUrl) {
  if (-not $baseUrl) { return '' }
  try {
    $health = Invoke-RestMethod -Uri ($baseUrl.TrimEnd('/') + '/api/health') -TimeoutSec 3 -ErrorAction Stop
    if ($health -and $health.healthy -eq $true -and $health.version) { return '/api' }
  } catch { }
  return ''
}

function Get-OpenCodeApiUri($baseUrl, $apiPrefix, $path) {
  return ($baseUrl.TrimEnd('/') + $apiPrefix + '/' + ([string]$path).TrimStart('/'))
}

function Get-OpenCodeApiData($response, $apiPrefix) {
  if ($apiPrefix -eq '/api' -and $response -and $response.PSObject.Properties['data']) {
    return $response.data
  }
  return $response
}

function Get-OpenCodeSessionDirectory($sessionInfo, $apiPrefix) {
  if (-not $sessionInfo) { return '' }
  if ($apiPrefix -eq '/api') { return [string]$sessionInfo.location.directory }
  return [string]$sessionInfo.directory
}

function Get-OpenCodeResumeCommand($url, $sessionId, $apiPrefix) {
  if ($apiPrefix -eq '/api') { return "opencode --server $url --session $sessionId" }
  return "opencode attach $url -s $sessionId"
}

function Enter-PipelineRun($repoRoot, $lane) {
  $logs = Join-Path $repoRoot '.pipeline\logs'
  $guard = [IO.File]::Open((Join-Path $logs 'pipeline-run.guard'), 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    $pending = Join-Path $logs 'opencode-pending.json'
    if (Test-Path -LiteralPath $pending) {
      throw "OpenCode chua xac nhan dung session cu. Kiem tra $pending va server truoc khi cho phep chay lai; khong tu xoa ban ghi."
    }
    # Also respect the previous release's lane locks during an upgrade.
    $otherLock = if ($lane -eq 'codex') { 'opencode-run.lock' } else { 'codex-run.lock.guard' }
    $probe = [IO.File]::Open((Join-Path $logs $otherLock), 'OpenOrCreate', 'ReadWrite', 'None')
    $probe.Dispose()
    if ($lane -eq 'opencode') {
      $ownerFile = Join-Path $logs 'codex-run.lock'
      if (Test-Path -LiteralPath $ownerFile) {
        $owner = Get-Content -Raw -Encoding UTF8 -LiteralPath $ownerFile | ConvertFrom-Json -ErrorAction Stop
        $ownerId = 0
        if (-not $owner -or -not [int]::TryParse([string]$owner.pid, [ref]$ownerId) -or $ownerId -le 0) { throw 'Codex lock khong hop le.' }
        $process = Get-Process -Id $ownerId -ErrorAction SilentlyContinue
        if ($process) {
          if (-not $owner.started -or $process.StartTime.ToUniversalTime().ToString('o') -eq [string]$owner.started) {
            throw "Codex PID $ownerId van con song."
          }
        }
      }
    }
    return $guard
  } catch {
    $guard.Dispose()
    throw
  }
}

function Stop-OpenCodeSession($url, $sessionId, $repoRoot) {
  if (-not $url -or -not $sessionId) { return $false }
  $baseUrl = $url.TrimEnd('/')
  $apiPrefix = Get-OpenCodeApiPrefix $baseUrl
  $query = '?directory=' + [uri]::EscapeDataString($repoRoot)
  $sessionPath = Get-OpenCodeApiUri $baseUrl $apiPrefix ('session/' + [uri]::EscapeDataString($sessionId))
  try {
    # Never abort a session in another repository.
    $sessionUri = if ($apiPrefix -eq '/api') { $sessionPath } else { $sessionPath + $query }
    $sessionInfo = Get-OpenCodeApiData (Invoke-RestMethod -Uri $sessionUri -TimeoutSec 4 -ErrorAction Stop) $apiPrefix
    $sessionDirectory = Get-OpenCodeSessionDirectory $sessionInfo $apiPrefix
    if ([string]$sessionInfo.id -ne $sessionId -or -not $sessionDirectory -or
        $sessionDirectory.Replace('/', '\').TrimEnd('\') -ine $repoRoot.Replace('/', '\').TrimEnd('\')) { return $false }

    if ($apiPrefix -eq '/api') {
      # V2 uses an interrupt endpoint that returns 204; activity is confirmed
      # by polling the documented active-session map until this ID disappears.
      $null = Invoke-RestMethod -Uri ($sessionPath + '/interrupt') -Method Post -TimeoutSec 4 -ErrorAction Stop
      for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $activeResponse = Invoke-RestMethod -Uri (Get-OpenCodeApiUri $baseUrl $apiPrefix 'session/active') -TimeoutSec 4 -ErrorAction Stop
        if (-not $activeResponse -or -not $activeResponse.PSObject.Properties['data'] -or
            $activeResponse.data -isnot [pscustomobject]) { return $false }
        if (-not $activeResponse.data.PSObject.Properties[$sessionId]) { return $true }
        Start-Sleep -Milliseconds 250
      }
      return $false
    }

    $ack = Invoke-RestMethod -Uri ($sessionPath + '/abort' + $query) -Method Post -TimeoutSec 4 -ErrorAction Stop
    if ($ack -isnot [bool] -or -not $ack) { return $false }
    # OpenCode omits idle sessions from its status map. Confirm the session
    # exists above, and accept absence only in a valid status object after abort.
    $status = Invoke-RestMethod -Uri ($baseUrl + '/session/status' + $query) -TimeoutSec 4 -ErrorAction Stop
    if ($null -eq $status -or $status -isnot [pscustomobject]) { return $false }
    foreach ($property in $status.PSObject.Properties) {
      if ($property.Value.type -notin @('idle','busy','retry')) { return $false }
    }
    $entry = $status.PSObject.Properties[$sessionId]
    return (-not $entry -or $entry.Value.type -eq 'idle')
  } catch { return $false }
}
