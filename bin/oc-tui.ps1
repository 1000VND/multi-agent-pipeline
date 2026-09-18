<#
  oc-tui.ps1 - Moi PHIEN CLAUDE gan voi DUNG MOT phien opencode.

  Goi truoc moi lan giao task cho opencode:
    - dong cua so CMD dang mo (bat ke no thuoc phien Claude nao)
    - tim phien opencode da gan voi phien Claude hien tai:
        co va con song   -> dung lai (giu nguyen lich su hoi thoai)
        chua co / da mat -> tao moi roi ghi vao map
    - mo cua so CMD moi ghim vao phien do
    - in "SESSION=<id>" o dong cuoi cho ben goi dung

  Nho vay: mo lai mot phien Claude cu roi giao task tiep -> cua so TUI quay ve
  dung phien opencode cua no, khong phai phien trang.
#>
param(
  [string]$Url   = "",   # rong = tu tim server cua repo (cong 4096-4105); truyen ro = ton trong nhung phai dung repo
  [string]$Title = "",
  [string]$Key   = "",   # ghi de khoa phien Claude (chu yeu de test)
  [switch]$Fresh,        # ep tao phien opencode moi cho phien Claude nay
  [switch]$CloseOnly,    # chi dong cua so dang mo
  [switch]$NoWindow      # chi lay/tao session, khong dong/mo CMD TUI
)

$ErrorActionPreference = "Stop"
$repo = (& git rev-parse --show-toplevel 2>$null)
if (-not $repo) { Write-Error "Khong phai git repo."; exit 2 }

$stateDir = Join-Path $repo ".pipeline"
$winFile  = Join-Path $stateDir "tui.json"      # cua so dang mo
$mapFile  = Join-Path $stateDir "tui-map.json"  # phien Claude -> phien opencode
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }

function Read-Json($path) {
  if (-not (Test-Path $path)) { return $null }
  try { return (Get-Content -Raw $path | ConvertFrom-Json) } catch { return $null }
}
function Test-Server {
  try { Invoke-RestMethod -Uri "$Url/session" -TimeoutSec 4 -ErrorAction Stop | Out-Null; return $true }
  catch { return $false }
}
# Kho phien cua opencode dung chung toan may: hoi server cua repo A ve phien cua
# repo B van tra ve day du. Phien chi dung duoc khi directory cua no khop repo hien tai.
# Tra ve: ok = phien ton tai VA thuoc dung repo; exists = phien con tren server;
# directory = thu muc that cua phien. Khong goi duoc server hoac khong doc duoc
# directory thi coi nhu khong dung duoc (exists = false).
function Test-Session($sid) {
  $dir = $null
  try {
    $one = Invoke-RestMethod -Uri "$Url/session/$sid" -TimeoutSec 6 -ErrorAction Stop
    if ($one -and $one.directory) { $dir = [string]$one.directory }
  } catch {
    return @{ ok = $false; exists = $false; directory = "" }
  }
  if (-not $dir) { return @{ ok = $false; exists = $false; directory = "" } }
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
  try {
    $proj = Invoke-RestMethod -Uri "$baseUrl/project/current" -TimeoutSec 3 -ErrorAction Stop
  } catch {
    return $null
  }
  if ($proj -and $proj.worktree) { return [string]$proj.worktree }
  return ""
}

# ---------- khoa phien Claude ----------
if ($Key -eq "") { $Key = $env:CLAUDE_CODE_HOST_SESSION_ID }
if (-not $Key)   { $Key = $env:CLAUDE_CODE_SESSION_ID }
if (-not $Key)   { $Key = "no-claude-session" }
Write-Output "  phien Claude: $Key"

# ---------- 1. dong cua so dang mo ----------
# Headless van can session/URL de nguoi dung co the attach lai sau nay, nhung
# khong duoc dong TUI ma ho dang xem.
if (-not $NoWindow) {
  $win = Read-Json $winFile
  if ($win -and $win.pid) {
    $proc = Get-Process -Id $win.pid -ErrorAction SilentlyContinue
    # chi giet dung cmd.exe ta da spawn; Windows tai su dung PID nen phai kiem
    if ($proc -and $proc.ProcessName -eq "cmd") {
      & taskkill /PID $win.pid /T /F 2>&1 | Out-Null
      Write-Output "  dong cua so cu (PID $($win.pid))"
    }
    Remove-Item $winFile -Force -ErrorAction SilentlyContinue
  }
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

# ---------- 3. tra map: phien Claude -> phien opencode ----------
$map   = Read-Json $mapFile
$table = @{}
if ($map) { $map.PSObject.Properties | ForEach-Object { $table[$_.Name] = $_.Value } }

$sid = $null
if (-not $Fresh -and $table.ContainsKey($Key)) {
  $candidate = $table[$Key].opencode_session
  $check = $null
  if ($candidate) { $check = Test-Session $candidate }
  if ($candidate -and $check.ok) {
    $sid = $candidate
    Write-Output "  DUNG LAI phien opencode cu: $sid"
  } elseif ($candidate -and $check.exists) {
    Write-Output "  phien cu ($candidate) thuoc repo '$($check.directory)', khong dung duoc o day - se tao phien moi"
  } else {
    Write-Output "  phien cu ($candidate) khong con tren server, se tao moi"
  }
}

if (-not $sid) {
  if ($Title -eq "") {
    $short = $Key.Substring(0, [Math]::Min(12, $Key.Length))
    $Title = "Claude $short - $(Get-Date -Format 'HH:mm')"
  }
  $body    = @{ title = $Title } | ConvertTo-Json -Compress
  $created = Invoke-RestMethod -Uri "$Url/session" -Method Post -Body $body `
                               -ContentType "application/json" -TimeoutSec 20
  $sid = $created.id
  if (-not $sid) { Write-Error "Khong tao duoc session."; exit 5 }
  Write-Output "  TAO MOI phien opencode: $sid"
}

$table[$Key] = @{
  opencode_session  = $sid
  claude_session_id = $env:CLAUDE_CODE_SESSION_ID
  last_used         = (Get-Date).ToString("s")
}
$table | ConvertTo-Json -Depth 5 | Set-Content -Path $mapFile -Encoding utf8

# ---------- 4. mo cua so CMD moi ----------
if (-not $NoWindow) {
  $proc = Start-Process -FilePath "cmd.exe" `
            -ArgumentList @("/k", "title opencode $sid && opencode attach $Url -s $sid") `
            -WorkingDirectory $repo -PassThru

  @{ pid = $proc.Id; sid = $sid; key = $Key; started = (Get-Date).ToString("s") } |
    ConvertTo-Json | Set-Content -Path $winFile -Encoding utf8

  Write-Output "  mo cua so TUI (PID $($proc.Id))"
} else {
  Write-Output "  khong mo cua so TUI (-NoWindow)"
}
Write-Output "URL=$Url"
Write-Output "SESSION=$sid"
