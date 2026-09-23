# Shared safety primitives. Dot-source only; no processes or requests on load.
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
  $query = '?directory=' + [uri]::EscapeDataString($repoRoot)
  $sessionPath = $baseUrl + '/session/' + [uri]::EscapeDataString($sessionId)
  try {
    # Never abort a session in another repository.
    $sessionInfo = Invoke-RestMethod -Uri ($sessionPath + $query) -TimeoutSec 4 -ErrorAction Stop
    if ($sessionInfo.id -ne $sessionId -or -not $sessionInfo.directory -or
        ([string]$sessionInfo.directory).Replace('/', '\').TrimEnd('\') -ine $repoRoot.Replace('/', '\').TrimEnd('\')) { return $false }
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
