# Shared OpenCode/API and pipeline safety helpers. Dot-source only; no requests
# or processes are started on load.

# OpenCode V2 `serve` always enables HTTP Basic auth (user "opencode"); its CLI
# reads the password from OPENCODE_PASSWORD, then OPENCODE_SERVER_PASSWORD.
$script:OpenCodeAuth = $null
$script:OpenCodeAuthHeaders = @{}

function ConvertTo-WindowsPath($path) {
  if (-not $path) { return '' }
  return ([string]$path).Replace('/', '\').TrimEnd('\')
}

function New-OpenCodePassword {
  $bytes = New-Object byte[] 32
  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $random.GetBytes($bytes) } finally { $random.Dispose() }
  return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Read-OpenCodePasswordFile($file) {
  if (-not (Test-Path -LiteralPath $file)) { return '' }
  try {
    $stored = Get-Content -Raw -Encoding UTF8 -LiteralPath $file | ConvertFrom-Json -ErrorAction Stop
    if ($stored -and $stored.password) { return [string]$stored.password }
  } catch { }
  return ''
}

function Get-OpenCodeServerPassword($repoRoot) {
  foreach ($name in @('OPENCODE_PASSWORD', 'OPENCODE_SERVER_PASSWORD')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrEmpty($value)) { return @{ password = $value; source = "env:$name"; file = '' } }
  }
  # logs/ is git-ignored in every install mode, so the credential never makes
  # the worktree dirty. Servers started by the pipeline keep using it.
  $logs = Join-Path $repoRoot '.pipeline\logs'
  $file = Join-Path $logs 'opencode-auth.json'
  $password = Read-OpenCodePasswordFile $file
  if ($password) { return @{ password = $password; source = 'file'; file = $file } }
  if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
  $password = New-OpenCodePassword
  $temp = '{0}.{1}.tmp' -f $file, [guid]::NewGuid().ToString('N')
  try {
    [IO.File]::WriteAllText($temp, (@{ username = 'opencode'; password = $password } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $file) {
      [IO.File]::Replace($temp, $file, [NullString]::Value)
    } else {
      try { [IO.File]::Move($temp, $file) }
      catch {
        # Another helper created the file first; its password is the one in use.
        $existing = Read-OpenCodePasswordFile $file
        if (-not $existing) { throw }
        $password = $existing
      }
    }
  } finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
  }
  return @{ password = $password; source = 'file'; file = $file }
}

function Initialize-OpenCodeAuth($repoRoot) {
  $script:OpenCodeAuth = Get-OpenCodeServerPassword $repoRoot
  $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('opencode:' + $script:OpenCodeAuth.password))
  $script:OpenCodeAuthHeaders = @{ Authorization = "Basic $token" }
  return $script:OpenCodeAuth
}

function Clear-OpenCodeAuth {
  $script:OpenCodeAuth = $null
  $script:OpenCodeAuthHeaders = @{}
}

function Invoke-OpenCodeApi {
  param([string]$Uri, [string]$Method = 'Get', [object]$Body = $null, [string]$ContentType = '', [int]$TimeoutSec = 5)
  $request = @{ Uri = $Uri; Method = $Method; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
  if ($script:OpenCodeAuthHeaders -and $script:OpenCodeAuthHeaders.Count -gt 0) { $request.Headers = $script:OpenCodeAuthHeaders }
  if ($null -ne $Body) { $request.Body = $Body }
  if ($ContentType) { $request.ContentType = $ContentType }
  Invoke-RestMethod @request
}

function Get-HttpStatusCode($failure) {
  $exception = if ($failure -is [Management.Automation.ErrorRecord]) { $failure.Exception } else { $failure }
  while ($exception) {
    $response = $null
    if ($exception.PSObject.Properties['Response']) { $response = $exception.Response }
    if ($response -and $response.StatusCode) {
      try { return [int]$response.StatusCode } catch { }
    }
    $exception = $exception.InnerException
  }
  return 0
}

function Get-OpenCodeServerProbe($baseUrl) {
  $probe = @{ prefix = ''; authRejected = $false }
  if (-not $baseUrl) { return $probe }
  try {
    # V2 has no /api/health; /api/info returns ServerInfo {version, pid, ...}.
    $info = Invoke-OpenCodeApi -Uri ($baseUrl.TrimEnd('/') + '/api/info') -TimeoutSec 3
    if ($info -and $info.PSObject.Properties['version'] -and $info.version -and $info.PSObject.Properties['pid']) { $probe.prefix = '/api' }
  } catch {
    # 401 is a password-protected OpenCode server (V2 always is), not another service.
    if ((Get-HttpStatusCode $_) -eq 401) { $probe.authRejected = $true }
  }
  return $probe
}

function Get-OpenCodeApiPrefix($baseUrl) {
  return (Get-OpenCodeServerProbe $baseUrl).prefix
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

# PowerShell 5.1 decodes native output with the console code page, which
# mangles the UTF-8 paths printed by `git -z`. Read git output as UTF-8.
# Arguments must be plain tokens without spaces.
function Invoke-PipelineGitText($repoRoot, [string[]]$Arguments) {
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = 'git'
  $startInfo.Arguments = $Arguments -join ' '
  $startInfo.WorkingDirectory = ([string]$repoRoot).Replace('/', '\')
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
  $process = [Diagnostics.Process]::Start($startInfo)
  try {
    $errorText = $process.StandardError.ReadToEndAsync()
    $outputText = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw ('git {0} failed ({1}): {2}' -f $startInfo.Arguments, $process.ExitCode, $errorText.Result.Trim()) }
    return $outputText
  } finally { $process.Dispose() }
}

# Compare content, not just porcelain: a resumed task may modify a file that
# was already dirty. Git supplies NUL-separated paths, including untracked files.
function Get-PipelineWorktreeFingerprint($repoRoot) {
  $rawPaths = Invoke-PipelineGitText $repoRoot @('-c', 'core.quotepath=false', 'ls-files', '-z', '--modified', '--deleted', '--others', '--exclude-standard')
  $stagedPaths = Invoke-PipelineGitText $repoRoot @('-c', 'core.quotepath=false', 'diff', '--cached', '--name-only', '-z')
  $entries = foreach ($relative in @(($rawPaths + "`0" + $stagedPaths) -split "`0" | Where-Object { $_ } | Sort-Object -Unique)) {
    $path = Join-Path $repoRoot $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      try { $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash }
      catch {
        # A file locked by another process must not crash the runner after the coder finished.
        $item = Get-Item -LiteralPath $path -Force
        $hash = 'unreadable:{0}:{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
      }
      '{0}:{1}' -f $relative, $hash
    } elseif (Test-Path -LiteralPath $path -PathType Container) {
      # A tracked submodule is a directory, not a file.
      '{0}:submodule:{1}:{2}' -f $relative, ((& git -C $path rev-parse HEAD) -join ''), ((& git -C $path status --porcelain) -join "`n")
    } else { '{0}:deleted' -f $relative }
  }
  $indexState = Invoke-PipelineGitText $repoRoot @('diff', '--cached', '--raw', '--no-abbrev')
  return (($entries -join "`n") + "`nINDEX:`n" + $indexState)
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
  # The server keys its instance by the native Windows path it was started in.
  $repoPath = ([string]$repoRoot).Replace('/', '\')
  $query = '?directory=' + [uri]::EscapeDataString($repoPath)
  $sessionPath = Get-OpenCodeApiUri $baseUrl $apiPrefix ('session/' + [uri]::EscapeDataString($sessionId))
  try {
    # Never abort a session in another repository.
    $sessionUri = if ($apiPrefix -eq '/api') { $sessionPath } else { $sessionPath + $query }
    $sessionInfo = Get-OpenCodeApiData (Invoke-OpenCodeApi -Uri $sessionUri -TimeoutSec 4) $apiPrefix
    $sessionDirectory = Get-OpenCodeSessionDirectory $sessionInfo $apiPrefix
    if ([string]$sessionInfo.id -ne $sessionId -or -not $sessionDirectory -or
        (ConvertTo-WindowsPath $sessionDirectory) -ine (ConvertTo-WindowsPath $repoPath)) { return $false }

    if ($apiPrefix -eq '/api') {
      # V2 interrupt returns {interrupted}; activity is confirmed by polling
      # the documented active-session map until this ID disappears.
      $null = Invoke-OpenCodeApi -Uri ($sessionPath + '/interrupt') -Method Post -TimeoutSec 4
      for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $activeResponse = Invoke-OpenCodeApi -Uri (Get-OpenCodeApiUri $baseUrl $apiPrefix 'session/active') -TimeoutSec 4
        if (-not $activeResponse -or -not $activeResponse.PSObject.Properties['data'] -or
            $activeResponse.data -isnot [pscustomobject]) { return $false }
        if (-not $activeResponse.data.PSObject.Properties[$sessionId]) { return $true }
        Start-Sleep -Milliseconds 250
      }
      return $false
    }

    $ack = Invoke-OpenCodeApi -Uri ($sessionPath + '/abort' + $query) -Method Post -TimeoutSec 4
    if ($ack -isnot [bool] -or -not $ack) { return $false }
    # OpenCode omits idle sessions from its status map. Confirm the session
    # exists above, and accept absence only in a valid status object after abort.
    $status = Invoke-OpenCodeApi -Uri ($baseUrl + '/session/status' + $query) -TimeoutSec 4
    if ($null -eq $status -or $status -isnot [pscustomobject]) { return $false }
    foreach ($property in $status.PSObject.Properties) {
      if ($property.Value.type -notin @('idle','busy','retry')) { return $false }
    }
    $entry = $status.PSObject.Properties[$sessionId]
    return (-not $entry -or $entry.Value.type -eq 'idle')
  } catch { return $false }
}
