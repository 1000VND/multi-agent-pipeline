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
  [string]$Url   = "http://127.0.0.1:4096",
  [string]$Title = "",
  [string]$Key   = "",   # ghi de khoa phien Claude (chu yeu de test)
  [switch]$Fresh,        # ep tao phien opencode moi cho phien Claude nay
  [switch]$CloseOnly     # chi dong cua so dang mo
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
function Test-Session($sid) {
  try { Invoke-RestMethod -Uri "$Url/session/$sid" -TimeoutSec 6 -ErrorAction Stop | Out-Null; return $true }
  catch { return $false }
}

# ---------- khoa phien Claude ----------
if ($Key -eq "") { $Key = $env:CLAUDE_CODE_HOST_SESSION_ID }
if (-not $Key)   { $Key = $env:CLAUDE_CODE_SESSION_ID }
if (-not $Key)   { $Key = "no-claude-session" }
Write-Output "  phien Claude: $Key"

# ---------- 1. dong cua so dang mo ----------
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
if ($CloseOnly) { Write-Output "CloseOnly: xong."; exit 0 }

# ---------- 2. dam bao server song ----------
if (-not (Test-Server)) {
  $port = ([uri]$Url).Port
  Write-Output "  bat server tren cong $port ..."
  Start-Process -FilePath "opencode.cmd" -ArgumentList @("serve", "--port", "$port") `
                -WorkingDirectory $repo -WindowStyle Hidden | Out-Null
  $deadline = (Get-Date).AddSeconds(30)
  while (-not (Test-Server)) {
    if ((Get-Date) -gt $deadline) { Write-Error "Server khong len sau 30s."; exit 4 }
    Start-Sleep -Milliseconds 400
  }
}

# ---------- 3. tra map: phien Claude -> phien opencode ----------
$map   = Read-Json $mapFile
$table = @{}
if ($map) { $map.PSObject.Properties | ForEach-Object { $table[$_.Name] = $_.Value } }

$sid = $null
if (-not $Fresh -and $table.ContainsKey($Key)) {
  $candidate = $table[$Key].opencode_session
  if ($candidate -and (Test-Session $candidate)) {
    $sid = $candidate
    Write-Output "  DUNG LAI phien opencode cu: $sid"
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
$proc = Start-Process -FilePath "cmd.exe" `
          -ArgumentList @("/k", "title opencode $sid && opencode attach $Url -s $sid") `
          -WorkingDirectory $repo -PassThru

@{ pid = $proc.Id; sid = $sid; key = $Key; started = (Get-Date).ToString("s") } |
  ConvertTo-Json | Set-Content -Path $winFile -Encoding utf8

Write-Output "  mo cua so TUI (PID $($proc.Id))"
Write-Output "SESSION=$sid"
