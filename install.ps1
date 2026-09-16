<#
  install.ps1 - Cai goi claude-pipeline vao mot repo git dich.

  Phan code cua goi (agents, skill, bin) luon duoc copy de (cap nhat).
  Du lieu cua nguoi dung (config, state, PROJECT_RULES, template, gitignore)
  chi duoc tao khi chua co; dung -Force de de va se in ro tung file bi de.
#>
param(
  [string]$Target = ".",
  [switch]$Force,
  [switch]$NoGitTrack
)

$ErrorActionPreference = "Stop"
$packageRoot = $PSScriptRoot

# 1. Giai duong dan dich va kiem tra git repo.
if (-not (Test-Path $Target)) {
  Write-Output "LOI: khong thay thu muc dich: $Target"
  exit 2
}
$targetPath = (Resolve-Path $Target).Path
# Ha EAP xuong Continue khi goi git: PS 5.1 coi stderr cua native command la
# terminating error khi EAP=Stop, lam script chet thay vi bao loi ro rang.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$gitRoot = (& git -C $targetPath rev-parse --show-toplevel 2>$null)
$ErrorActionPreference = $prevEAP
if (-not $gitRoot) {
  Write-Output "LOI: '$targetPath' khong phai git repo. Hay 'git init' truoc khi cai."
  exit 2
}
$projectName = Split-Path $targetPath -Leaf

Write-Output "Cai claude-pipeline vao: $targetPath"
Write-Output ""

# 2. Tao cay thu muc dich neu chua co.
$dirs = @(
  ".claude\agents",
  ".claude\skills\pipeline",
  ".pipeline\bin",
  ".pipeline\tasks",
  ".pipeline\logs"
)
foreach ($d in $dirs) {
  $full = Join-Path $targetPath $d
  if (-not (Test-Path $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null }
}

# 3. Copy de phan code cua goi.
$agentDir = Join-Path $packageRoot "agents"
foreach ($f in @(Get-ChildItem -Path $agentDir -Filter *.md -File)) {
  Copy-Item -Path $f.FullName -Destination (Join-Path $targetPath ".claude\agents") -Force
  Write-Output "COPY: .claude\agents\$($f.Name)"
}
Copy-Item -Path (Join-Path $packageRoot "skill\SKILL.md") `
  -Destination (Join-Path $targetPath ".claude\skills\pipeline\SKILL.md") -Force
Write-Output "COPY: .claude\skills\pipeline\SKILL.md"
$binDir = Join-Path $packageRoot "bin"
foreach ($f in @(Get-ChildItem -Path $binDir -Filter *.ps1 -File)) {
  Copy-Item -Path $f.FullName -Destination (Join-Path $targetPath ".pipeline\bin") -Force
  Write-Output "COPY: .pipeline\bin\$($f.Name)"
}

# 4. Du lieu nguoi dung: chi tao khi chua co (hoac -Force).
$configTemplate = Join-Path $packageRoot "templates\pipeline.config.json"
$dataFiles = @(
  @{ Src = $configTemplate;                                          Dst = ".pipeline\pipeline.config.json"; IsConfig = $true },
  @{ Src = (Join-Path $packageRoot "templates\state.json");          Dst = ".pipeline\state.json";           IsConfig = $false },
  @{ Src = (Join-Path $packageRoot "templates\PROJECT_RULES.md");    Dst = ".pipeline\PROJECT_RULES.md";     IsConfig = $false },
  @{ Src = (Join-Path $packageRoot "templates\task-template.md");    Dst = ".pipeline\tasks\_TEMPLATE.md";   IsConfig = $false },
  @{ Src = (Join-Path $packageRoot "templates\pipeline.gitignore");  Dst = ".pipeline\.gitignore";           IsConfig = $false }
)
foreach ($f in $dataFiles) {
  $dest = Join-Path $targetPath $f.Dst
  if ((Test-Path $dest) -and (-not $Force)) {
    Write-Output "GIU NGUYEN: $($f.Dst) (da co, dung -Force neu muon de)"
    continue
  }
  if (Test-Path $dest) {
    Write-Output "DE: $($f.Dst)"
  } else {
    Write-Output "TAO: $($f.Dst)"
  }
  if ($f.IsConfig) {
    $raw = Get-Content -Raw -Encoding UTF8 $f.Src
    $raw = $raw.Replace('<ten repo>', $projectName)
    Set-Content -Path $dest -Value $raw -Encoding UTF8
  } else {
    Copy-Item -Path $f.Src -Destination $dest -Force
  }
}

# 4b. -NoGitTrack: dat .gitignore '*' vao cac thu muc cua goi de git khong thay.
# '*' ignore moi thu trong thu muc, ke ca chinh file .gitignore nay; file da
# tracked tu truoc khong bi anh huong. Chay sau muc 4 nen luon thang ca
# "GIU NGUYEN" lan -Force.
if ($NoGitTrack) {
  $trackDirs = @(".pipeline", ".claude\agents", ".claude\skills\pipeline")
  foreach ($d in $trackDirs) {
    $dest = Join-Path $targetPath (Join-Path $d ".gitignore")
    if (Test-Path $dest) {
      Write-Output "DE: $d\.gitignore (NoGitTrack)"
    } else {
      Write-Output "TAO: $d\.gitignore (NoGitTrack)"
    }
    Set-Content -Path $dest -Value "*" -Encoding UTF8
  }
}

# 5. Bao cao dieu kien chay (thieu thi khong fail).
function Show-ToolStatus($name) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  if ($cmd) {
    Write-Output "OK    $name -> $($cmd.Source)"
  } else {
    Write-Output "THIEU $name"
  }
}

Write-Output ""
Write-Output "== DIEU KIEN CHAY =="
Show-ToolStatus "git"
$psv = $PSVersionTable.PSVersion
if ($psv.Major -eq 5 -and $psv.Minor -eq 1) {
  Write-Output "OK    Windows PowerShell $psv"
} else {
  Write-Output "CANH BAO PowerShell $psv - pipeline viet cho Windows PowerShell 5.1"
}
Show-ToolStatus "codex"
Show-ToolStatus "opencode"
Show-ToolStatus "python"
if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
  Write-Output "CANH BAO: thieu codex - lane Codex se khong dung duoc."
}
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
  Write-Output "CANH BAO: thieu opencode - lane OpenCode se khong dung duoc."
}

# 6. Viec can lam tiep.
Write-Output ""
Write-Output "== VIEC CAN LAM TIEP =="
Write-Output "1. Dien 'test_command' (va 'test_command_targeted') trong .pipeline\pipeline.config.json."
Write-Output "2. Viet luat cung cua repo vao .pipeline\PROJECT_RULES.md."
Write-Output "3. TUI Codex can thu muc duoc Codex tin cay: chay mot luot -NoTui nho truoc la dang ky duoc."
exit 0
