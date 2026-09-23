<#
  oc-tui.ps1 - Moi PHIEN CLAUDE gan voi MOT phien opencode dang hoat dong.

  Goi truoc moi lan giao task cho opencode:
    - dong cua so CMD dang mo (bat ke no thuoc phien Claude nao)
    - tim phien opencode da gan voi phien Claude hien tai:
        co va con song   -> dung lai; context >80% thi tao moi va giu ID cu
        chua co / da mat -> tao moi roi ghi vao map
    - mo cua so CMD moi ghim vao phien do
    - in "SESSION=<id>" o dong cuoi cho ben goi dung

  Nho vay: mo lai mot phien Claude cu roi giao task tiep -> cua so TUI quay ve
  dung phien opencode cua no, khong phai phien trang.
#>
param(
  [string]$Url   = "",   # rong = tu tim server cua repo (cong 4096-4105); truyen ro = ton trong nhung phai dung repo
  [string]$Title = "",
  [string]$Key   = "",   # khoa phien Claude; bat buoc neu khong co CLAUDE_CODE_*_SESSION_ID
  [string]$Session = "", # chon session ban dau ro rang; van rollover neu vuot nguong
  [switch]$Fresh,        # ep tao phien opencode moi cho phien Claude nay
  [switch]$CloseOnly,    # chi dong cua so dang mo
  [switch]$NoWindow      # chi lay/tao session, khong dong/mo CMD TUI
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'pipeline-runtime.ps1')
$repo = (& git rev-parse --show-toplevel 2>$null)
if (-not $repo) { Write-Error "Khong phai git repo."; exit 2 }

$stateDir = Join-Path $repo ".pipeline"
$winFile  = Join-Path $stateDir "tui.json"      # cua so dang mo
$mapFile  = Join-Path $stateDir "tui-map.json"  # phien Claude -> phien opencode
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }

$contextRolloverPercent = 80
try {
  $configPath = Join-Path $stateDir "pipeline.config.json"
  if (Test-Path $configPath) {
    $config = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json
    $configuredPercent = 0
    if ([int]::TryParse([string]$config.session_rollover.context_percent, [ref]$configuredPercent) -and
        $configuredPercent -ge 1 -and $configuredPercent -le 99) {
      $contextRolloverPercent = $configuredPercent
    }
  }
} catch { }

function Read-Json($path) {
  if (-not (Test-Path $path)) { return $null }
  # Khong ghi de map hong: se lam mat tat ca lien ket phien cu.
  return (Get-Content -Raw -Encoding UTF8 $path | ConvertFrom-Json -ErrorAction Stop)
}
function Set-ObjectProperty($object, $name, $value) {
  $prop = $object.PSObject.Properties[$name]
  if ($prop) { $prop.Value = $value } else { $object | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}
function Test-Server {
  try {
    $prefix = Get-OpenCodeApiPrefix $Url
    Invoke-RestMethod -Uri (Get-OpenCodeApiUri $Url $prefix 'session') -TimeoutSec 4 -ErrorAction Stop | Out-Null
    return $true
  }
  catch { return $false }
}
# Kho phien cua opencode dung chung toan may: hoi server cua repo A ve phien cua
# repo B van tra ve day du. Phien chi dung duoc khi directory cua no khop repo hien tai.
# Tra ve: ok = phien ton tai VA thuoc dung repo; exists = phien con tren server;
# directory = thu muc that cua phien. Khong goi duoc server hoac khong doc duoc
# directory thi chua biet (unknown = true), khong xoa lien ket vi loi mang.
function Test-Session($sid) {
  $dir = $null
  $prefix = Get-OpenCodeApiPrefix $Url
  try {
    $one = Invoke-RestMethod -Uri (Get-OpenCodeApiUri $Url $prefix ('session/' + [uri]::EscapeDataString($sid))) -TimeoutSec 6 -ErrorAction Stop
    $one = Get-OpenCodeApiData $one $prefix
    $dir = Get-OpenCodeSessionDirectory $one $prefix
  } catch {
    $statusCode = 0
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
    }
    return @{ ok = $false; exists = $false; unknown = ($statusCode -ne 404); directory = "" }
  }
  if (-not $dir) { return @{ ok = $false; exists = $false; unknown = $true; directory = "" } }
  $same = ((Normalize-RepoPath $dir) -ieq (Normalize-RepoPath $repo))
  return @{ ok = $same; exists = $true; directory = $dir }
}
# Chuan hoa duong dan truoc khi so sanh: git tra F:/x, server tra F:\x.
function Normalize-RepoPath($p) {
  if (-not $p) { return "" }
  return ([string]$p -replace '/', '\').TrimEnd('\')
}
# worktree cua server: $null = khong ket noi duoc, "" = co dich vu khac, con lai la duong dan.
function Get-Worktree($baseUrl) {
  $prefix = Get-OpenCodeApiPrefix $baseUrl
  try {
    $proj = Invoke-RestMethod -Uri (Get-OpenCodeApiUri $baseUrl $prefix 'project/current') -TimeoutSec 3 -ErrorAction Stop
  } catch {
    return $null
  }
  if ($prefix -eq '/api' -and $proj -and $proj.directory) { return [string]$proj.directory }
  if ($proj -and $proj.worktree) { return [string]$proj.worktree }
  return ""
}

# OpenCode ghi usage theo từng message va cong lifetime theo session. Chi dung
# message gan nhat (context thuc te cua request), TUYET DOI khong dung tong
# lifetime vi cache.read se lam no phinh ra du context window.
function Get-Number($object, $names) {
  if (-not $object) { return 0L }
  foreach ($name in $names) {
    $prop = $object.PSObject.Properties[$name]
    if ($prop -and $null -ne $prop.Value) {
      try { return [int64]$prop.Value } catch { }
    }
  }
  return 0L
}
function Get-ModelContextLimit($modelCatalog, $providerId, $modelId, $apiPrefix) {
  if ($apiPrefix -eq '/api') {
    foreach ($model in @($modelCatalog.data)) {
      if ([string]$model.providerID -cne $providerId) { continue }
      $candidateId = if ($model.modelID) { [string]$model.modelID } else { [string]$model.id }
      if ($candidateId -ceq $modelId) { return Get-Number $model.limit @("context") }
    }
    return 0L
  }
  # GET /provider tra { all: Provider[], ... }. Hai provider co the co model
  # cung id nhung context khac nhau: chi dung dung cap providerID + modelID.
  if (-not $providerId -or -not $modelId) { return 0L }
  foreach ($provider in @($modelCatalog.all)) {
    if ([string]$provider.id -cne $providerId) { continue }
    $property = $provider.models.PSObject.Properties[$modelId]
    if ($property -and $property.Value.limit) {
      return Get-Number $property.Value.limit @("context")
    }
  }
  return 0L
}
function Get-OpenCodeSessionContext($sid) {
  try {
    $prefix = $script:OpenCodeApiPrefix
    if ($prefix -eq '/api') {
      $response = Invoke-RestMethod -Uri (Get-OpenCodeApiUri $Url $prefix ('session/' + [uri]::EscapeDataString($sid) + '/context')) -TimeoutSec 8 -ErrorAction Stop
    } else {
      $response = Invoke-RestMethod -Uri "$Url/session/$sid/message?limit=100" -TimeoutSec 8 -ErrorAction Stop
    }
    # On PowerShell 5.1, $array.missingProperty yields an array of nulls
    # whose boolean value is true. Detect envelopes on the object itself.
    $messages = if ($response -and $response.PSObject.Properties['data']) { @($response.data) }
      elseif ($response -and $response.PSObject.Properties['items']) { @($response.items) }
      else { @($response) }
    $message = $null
    $used = 0L
    # Server messages are oldest-first. Sort by created time too, so wrappers
    # returning newest-first cannot select stale usage. Ignore failed/empty
    # assistant placeholders and user messages (including compacted history).
    if ($prefix -eq '/api') {
      $ordered = @($messages | Where-Object { $_.type -eq 'assistant' } |
        Sort-Object { Get-Number $_.time @("created") })
    } else {
      $ordered = @($messages | Where-Object { $_.info.role -eq "assistant" } |
        Sort-Object { Get-Number $_.info.time @("created") })
    }
    foreach ($item in $ordered) {
      if ($prefix -eq '/api') {
        $tokens = $item.tokens
        $current = (Get-Number $tokens @("input")) + (Get-Number $tokens.cache @("read")) +
          (Get-Number $tokens.cache @("write")) + (Get-Number $tokens @("output")) +
          (Get-Number $tokens @("reasoning"))
        if ($current -gt 0) { $message = $item; $used = $current }
        continue
      }
      # A completed summary describes context BEFORE compaction. The next
      # ordinary request provides the new window usage; until then it is
      # unknown, not the old near-full value.
      if ($item.info.summary) {
        if ($item.info.time.completed) { $message = $null; $used = 0L }
        continue
      }
      $tokens = $item.info.tokens
      # OpenCode v1.18.31 Session.getUsage stores disjoint buckets: input
      # excludes cached tokens, output excludes reasoning. Do not add total.
      # https://github.com/anomalyco/opencode/blob/v1.18.31/packages/opencode/src/session/session.ts
      $current = (Get-Number $tokens @("input")) + (Get-Number $tokens.cache @("read")) +
        (Get-Number $tokens.cache @("write")) + (Get-Number $tokens @("output")) +
        (Get-Number $tokens @("reasoning"))
      if ($current -gt 0) { $message = $item; $used = $current }
    }
    if (-not $message) { return $null }
    if ($prefix -eq '/api') {
      $modelId = [string]$message.model.id
      $providerId = [string]$message.model.providerID
      try { $catalog = Invoke-RestMethod -Uri (Get-OpenCodeApiUri $Url $prefix 'model') -TimeoutSec 8 -ErrorAction Stop } catch { $catalog = $null }
    } else {
      $modelId = [string]$message.info.modelID
      $providerId = [string]$message.info.providerID
      try { $catalog = Invoke-RestMethod -Uri "$Url/provider" -TimeoutSec 8 -ErrorAction Stop } catch { $catalog = $null }
    }
    $window = Get-ModelContextLimit $catalog $providerId $modelId $prefix
    if ($used -le 0 -or $window -le 0) { return $null }
    return @{ used_tokens = [int64]$used; context_window = [int64]$window; percent = [math]::Round((100.0 * $used / $window), 1) }
  } catch {
    Write-Verbose "Khong doc duoc context session ${sid}: $($_.Exception.Message)"
    return $null
  }
}
function Get-OpenCodeSessionHistory($existing) {
  $history = [System.Collections.Generic.List[object]]::new()
  if ($existing) {
    foreach ($entry in @($existing.opencode_sessions)) {
      if ($entry -and $entry.session_id) {
        $duplicate = @($history | Where-Object { $_.session_id -eq $entry.session_id } | Select-Object -First 1)
        if ($duplicate.Count -eq 0) { $history.Add($entry) }
        else {
          foreach ($property in $entry.PSObject.Properties) {
            if (-not $duplicate[0].PSObject.Properties[$property.Name]) {
              Set-ObjectProperty $duplicate[0] $property.Name $property.Value
            }
          }
        }
      }
    }
    if ($existing.opencode_session -and -not (@($history | Where-Object { $_.session_id -eq $existing.opencode_session }).Count)) {
      $history.Add([pscustomobject]@{
        session_id = [string]$existing.opencode_session
        created_at = if ($existing.last_used) { [string]$existing.last_used } else { (Get-Date).ToString("s") }
        last_used = if ($existing.last_used) { [string]$existing.last_used } else { (Get-Date).ToString("s") }
        url = [string]$existing.url
        created_reason = "legacy_map"
      })
    }
  }
  return ,$history
}
function Retire-OpenCodeSession($table, $key, $sid, $reason, $context) {
  if (-not $table.ContainsKey($key)) { return }
  $record = $table[$key]
  $history = Get-OpenCodeSessionHistory $record
  $entry = @($history | Where-Object { $_.session_id -eq $sid } | Select-Object -First 1)
  if ($entry.Count -eq 0) {
    $entry = @([pscustomobject]@{ session_id = $sid; created_at = (Get-Date).ToString("s") })
    $history.Add($entry[0])
  }
  Set-ObjectProperty $entry[0] "retired_at" (Get-Date).ToString("s")
  Set-ObjectProperty $entry[0] "retired_reason" $reason
  if (-not $entry[0].url) { Set-ObjectProperty $entry[0] "url" $Url }
  Set-ObjectProperty $entry[0] "resume_command" (Get-OpenCodeResumeCommand $entry[0].url $sid $script:OpenCodeApiPrefix)
  if ($context) {
    Set-ObjectProperty $entry[0] "last_context_tokens" ([int64]$context.used_tokens)
    Set-ObjectProperty $entry[0] "context_window_tokens" ([int64]$context.context_window)
  }
  Set-ObjectProperty $record "opencode_sessions" @($history.ToArray())
  $table[$key] = $record
}
function Save-OpenCodeMap($table) {
  # logs/ is ignored by installed projects. A crash must not leave a temp
  # map that makes the next runner's clean-worktree check fail.
  $pendingDir = Join-Path $stateDir "logs"
  if (-not (Test-Path -LiteralPath $pendingDir)) { New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null }
  $pendingMap = Join-Path $pendingDir ("tui-map-{0}.tmp" -f [guid]::NewGuid().ToString("N"))
  try {
    $table | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $pendingMap -Encoding utf8
    if (Test-Path -LiteralPath $mapFile) { [IO.File]::Replace($pendingMap, $mapFile, [NullString]::Value) }
    else { [IO.File]::Move($pendingMap, $mapFile) }
  } finally {
    if (Test-Path -LiteralPath $pendingMap) { Remove-Item -LiteralPath $pendingMap -Force }
  }
}

# ---------- khoa phien Claude ----------
if ([string]::IsNullOrWhiteSpace($Key)) { $Key = $env:CLAUDE_CODE_HOST_SESSION_ID }
if ([string]::IsNullOrWhiteSpace($Key)) { $Key = $env:CLAUDE_CODE_SESSION_ID }
if ([string]::IsNullOrWhiteSpace($Key) -and -not $CloseOnly) {
  Write-Output "BLOCKED: khong co CLAUDE_CODE_*_SESSION_ID. Truyen -Key <claude-session-id> de tranh lan lich su."
  exit 11
}
if ($Session -and $Fresh) { throw "Khong the dung -Session va -Fresh cung luc." }
Write-Output "  phien Claude: $Key"

function Get-OpenCodeProcessStart($process) {
  try { return $process.StartTime.ToUniversalTime().ToString('o') } catch { return $null }
}

function Close-ManagedOpenCodeTui {
  $win = Read-Json $winFile
  if (-not $win -or -not $win.pid) { return $true }
  $proc = Get-Process -Id $win.pid -ErrorAction SilentlyContinue
  if ($proc -and $proc.ProcessName -eq 'cmd') {
    $started = Get-OpenCodeProcessStart $proc
    if (-not $win.proc_started -or -not $started -or $started -ne $win.proc_started) {
      Write-Host "CANH BAO: khong xac minh duoc TUI PID $($win.pid); khong dong de tranh giet nham."
    } else {
      $previousEAP = $ErrorActionPreference
      try {
        $ErrorActionPreference = 'Continue'
        & taskkill.exe /PID $win.pid /T /F 2>&1 | Out-Null
      } finally { $ErrorActionPreference = $previousEAP }
      $deadline = (Get-Date).AddSeconds(3)
      do {
        $remaining = Get-Process -Id $win.pid -ErrorAction SilentlyContinue
        if (-not $remaining -or (Get-OpenCodeProcessStart $remaining) -ne $started) { break }
        Start-Sleep -Milliseconds 100
      } while ((Get-Date) -lt $deadline)
      if ($remaining -and (Get-OpenCodeProcessStart $remaining) -eq $started) {
        Write-Host "BLOCKED: khong dong duoc TUI PID $($win.pid); giu ban ghi, khong mo them cua so."
        return $false
      }
      Write-Host "  dong cua so cu (PID $($win.pid))"
    }
  }
  Remove-Item -LiteralPath $winFile -Force -ErrorAction SilentlyContinue
  return $true
}

# ---------- 1. dong cua so dang mo ----------
# Headless van can session/URL de nguoi dung co the attach lai sau nay, nhung
# khong duoc dong TUI ma ho dang xem.
if (-not $NoWindow) {
  if (-not (Close-ManagedOpenCodeTui)) { exit 10 }
}
if ($CloseOnly) { Write-Output "CloseOnly: xong."; exit 0 }

# ---------- 2. tim hoac tao server cua dung repo nay ----------
# Server opencode gan chat voi thu muc no duoc khoi dong: attach vao server cua
# repo khac la coder doc/sua nham du an. Vi vay moi repo phai co server rieng.
$repoNorm = Normalize-RepoPath $repo

function Start-RepoServer($port) {
  Write-Output "  bat server tren cong $port ..."
  Start-Process -FilePath "opencode.cmd" -ArgumentList @("serve", "--port", "$port") `
                -WorkingDirectory $repo -WindowStyle Hidden | Out-Null
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -le $deadline) {
    $wt = Get-Worktree "http://127.0.0.1:$port"
    if ($wt -and ((Normalize-RepoPath $wt) -ieq $repoNorm)) { return }
    Start-Sleep -Milliseconds 400
  }
  [Console]::Error.WriteLine("LOI: server tren cong $port khong dung repo '$repo' sau 30s.")
  exit 4
}

if ($Url -ne "") {
  # Nguoi goi chi dinh ro: ton trong, nhung phai la server cua dung repo.
  $Url = $Url.TrimEnd('/')
  $wt = Get-Worktree $Url
  if ($null -eq $wt) {
    Start-RepoServer ([uri]$Url).Port
  } elseif ($wt -eq "") {
    [Console]::Error.WriteLine("LOI: $Url co dich vu khac, khong phai opencode.")
    exit 4
  } elseif ((Normalize-RepoPath $wt) -ine $repoNorm) {
    [Console]::Error.WriteLine("LOI: server $Url dang phuc vu repo '$wt', khong phai '$repo'. Tu choi.")
    exit 4
  }
} else {
  # Quet cong 4096-4105: uu tien server cua dung repo, ghi nho cong trong dau tien.
  $firstFree = 0
  $chosen    = ""
  for ($p = 4096; $p -le 4105; $p++) {
    $cand = "http://127.0.0.1:$p"
    $wt = Get-Worktree $cand
    if ($null -eq $wt) {
      if ($firstFree -eq 0) { $firstFree = $p }
      continue
    }
    if ($wt -eq "") { continue }
    if ((Normalize-RepoPath $wt) -ieq $repoNorm) { $chosen = $cand; break }
  }
  if ($chosen -ne "") {
    $Url = $chosen
    Write-Output "  dung server san co cua repo tren cong $(([uri]$Url).Port)"
  } elseif ($firstFree -ne 0) {
    $Url = "http://127.0.0.1:$firstFree"
    Start-RepoServer $firstFree
  } else {
    [Console]::Error.WriteLine("LOI: het cong 4096-4105, moi cong deu bi server cua repo khac chiem.")
    exit 4
  }
}

# One server can speak either the v1 routes or the v2 /api surface. The
# detected version also determines the command we print for manual TUI resume.
$script:OpenCodeApiPrefix = Get-OpenCodeApiPrefix $Url
$script:OpenCodeVersion = if ($script:OpenCodeApiPrefix -eq '/api') { 2 } else { 1 }

# ---------- 3. tra map: phien Claude -> phien opencode ----------
# Serialize read/modify/write across runners so parallel Claude sessions do
# not overwrite each other's associations. Atomic replacement keeps old JSON
# readable if the process is interrupted while saving.
$hash = [Security.Cryptography.SHA256]::Create()
try { $mapHash = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($mapFile.ToLowerInvariant()))).Replace("-", "") }
finally { $hash.Dispose() }
$mapLock = New-Object Threading.Mutex($false, "Local\pipeline-oc-$mapHash")
$lockTaken = $false
try {
  try { $lockTaken = $mapLock.WaitOne(60000) } catch [Threading.AbandonedMutexException] { $lockTaken = $true }
  if (-not $lockTaken) { throw "Khong lay duoc khoa tui-map.json sau 60s." }
  $map = Read-Json $mapFile
  if ($null -ne $map -and $map -isnot [pscustomobject]) { throw "tui-map.json phai la JSON object; khong ghi de map cu." }
  $table = @{}
  if ($map) { $map.PSObject.Properties | ForEach-Object { $table[$_.Name] = $_.Value } }
  $previous = if ($table.ContainsKey($Key)) { $table[$Key] } else { [pscustomobject]@{} }
  if ($null -eq $previous -or $previous -isnot [pscustomobject]) { throw "Ban ghi session '$Key' khong hop le; khong ghi de map cu." }
  $table[$Key] = $previous
  $history = Get-OpenCodeSessionHistory $previous
  Set-ObjectProperty $previous "opencode_sessions" @($history.ToArray())

  $sid = $null
  $context = $null
  $creationReason = "initial"
  $candidate = if ($Session) { $Session } else { [string]$previous.opencode_session }
  if ($Session -and $previous.opencode_session -and $previous.opencode_session -ne $Session) {
    Retire-OpenCodeSession $table $Key $previous.opencode_session "explicit_selection" $null
  }
  # Record an explicitly selected session before checking/rotating it too.
  if ($Session) {
    $history = Get-OpenCodeSessionHistory $previous
    if (-not @($history | Where-Object { $_.session_id -eq $Session }).Count) {
      $history.Add([pscustomobject]@{ session_id = $Session; created_at = (Get-Date).ToString("s"); url = $Url; created_reason = "explicit_selection" })
    }
    Set-ObjectProperty $previous "opencode_sessions" @($history.ToArray())
  }
  if ($Fresh -and $candidate) {
    $creationReason = "fresh"
    Retire-OpenCodeSession $table $Key $candidate $creationReason $null
  } elseif ($candidate) {
    $check = Test-Session $candidate
    if ($check.ok) {
      $context = Get-OpenCodeSessionContext $candidate
      # Compare raw counts: 80.0001% rotates; exactly 80% does not.
      if ($context -and ([decimal]$context.used_tokens * 100 -gt [decimal]$context.context_window * $contextRolloverPercent)) {
        $creationReason = "context_over_$contextRolloverPercent%"
        Write-Output "CONTEXT: phien opencode $candidate dang $($context.percent)% ($($context.used_tokens)/$($context.context_window) tokens) - tao phien moi"
        Retire-OpenCodeSession $table $Key $candidate $creationReason $context
      } else {
        $sid = $candidate
        if (-not $context) { Write-Output "CANH BAO CONTEXT: khong doc duoc usage/context model cua $sid; giu session hien tai." }
        Write-Output "  DUNG LAI phien opencode cu: $sid"
      }
    } elseif ($check.unknown) {
      if ($Session -and $Session -ne $previous.opencode_session) {
        throw "Khong xac minh duoc repo cua session -Session '$Session'; giu nguyen map."
      }
      $sid = $candidate
      Write-Output "CANH BAO CONTEXT: khong xac minh duoc session $sid (API/ket noi); giu session hien tai."
    } else {
      if ($Session) { throw "Session -Session '$Session' khong ton tai hoac khong thuoc repo '$repo'." }
      $creationReason = if ($check.exists) { "repo_mismatch" } else { "unavailable" }
      Retire-OpenCodeSession $table $Key $candidate $creationReason $null
      Write-Output "  phien cu ($candidate) khong dung duoc ($creationReason) - se tao phien moi"
    }
  }

  if (-not $sid) {
    # Persist known associations before POST too: a failed creation must
    # not drop an explicitly selected session we have just retired.
    Save-OpenCodeMap $table
    if ($Title -eq "") {
      $short = $Key.Substring(0, [Math]::Min(12, $Key.Length))
      $Title = "Claude $short - $(Get-Date -Format 'HH:mm')"
    }
    $body = @{ title = $Title } | ConvertTo-Json -Compress
    if ($script:OpenCodeApiPrefix -eq '/api') {
      $body = @{ title = $Title; location = @{ directory = $repo } } | ConvertTo-Json -Compress
    }
    $created = Invoke-RestMethod -Uri (Get-OpenCodeApiUri $Url $script:OpenCodeApiPrefix 'session') -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20
    $created = Get-OpenCodeApiData $created $script:OpenCodeApiPrefix
    $sid = [string]$created.id
    if (-not $sid) { throw "Khong tao duoc session." }
    Write-Output "  TAO MOI phien opencode: $sid"
  }

  $history = Get-OpenCodeSessionHistory $previous
  $now = (Get-Date).ToString("s")
  $entry = @($history | Where-Object { $_.session_id -eq $sid } | Select-Object -First 1)
  if ($entry.Count -eq 0) {
    $entry = @([pscustomobject]@{ session_id = $sid; created_at = $now; created_reason = $creationReason })
    $history.Add($entry[0])
  }
  Set-ObjectProperty $entry[0] "last_used" $now
  Set-ObjectProperty $entry[0] "url" $Url
  Set-ObjectProperty $entry[0] "resume_command" (Get-OpenCodeResumeCommand $Url $sid $script:OpenCodeApiPrefix)
  if ($context -and $sid -eq $candidate) {
    Set-ObjectProperty $entry[0] "last_context_tokens" ([int64]$context.used_tokens)
    Set-ObjectProperty $entry[0] "context_window_tokens" ([int64]$context.context_window)
  }
  Set-ObjectProperty $previous "opencode_session" $sid
  Set-ObjectProperty $previous "claude_session_id" $Key
  Set-ObjectProperty $previous "last_used" $now
  Set-ObjectProperty $previous "url" $Url
  Set-ObjectProperty $previous "opencode_sessions" @($history.ToArray())
  Save-OpenCodeMap $table
} finally {
  if ($lockTaken) { $mapLock.ReleaseMutex() }
  $mapLock.Dispose()
}

# ---------- 4. mo cua so CMD moi ----------
if (-not $NoWindow) {
  $resumeCommand = Get-OpenCodeResumeCommand $Url $sid $script:OpenCodeApiPrefix
  $proc = Start-Process -FilePath "cmd.exe" `
            -ArgumentList @("/k", "title opencode $sid && $resumeCommand") `
            -WorkingDirectory $repo -PassThru

  @{ pid = $proc.Id; sid = $sid; key = $Key; started = (Get-Date).ToString("s"); proc_started = (Get-OpenCodeProcessStart $proc) } |
    ConvertTo-Json | Set-Content -Path $winFile -Encoding utf8

  Write-Output "  mo cua so TUI (PID $($proc.Id))"
} else {
  Write-Output "  khong mo cua so TUI (-NoWindow)"
}
Write-Output "URL=$Url"
Write-Output "SESSION=$sid"
$resumeCommand = Get-OpenCodeResumeCommand $Url $sid $script:OpenCodeApiPrefix
Write-Output "API_VERSION=$script:OpenCodeVersion"
Write-Output "TUI: $resumeCommand"
