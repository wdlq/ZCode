#Requires -Version 5.1
<#
  ZCode Windows 7 离线安装包 —— 引导脚本

  为什么分两段：
  - 7-Zip SFX 解压到 %TEMP% 下的临时目录，SFX 进程退出后该目录会被清理；
  - 安装需要管理员权限，而 SFX 本身通常不是以管理员启动的。
  因此这里先把 payload 复制到固定临时目录，再以管理员身份启动 install-core.ps1，
  并 -Wait 等待它结束（父进程存活时 SFX 不会清理目录）。
#>
[CmdletBinding()]
param(
  [string]$TargetDir = "C:\Program Files\ZCode-Win7",
  [switch]$NoShortcuts
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Step([string]$Text, [string]$Color = "") {
  try {
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
  } catch { try { [Console]::Out.WriteLine(($Text -replace '[^\x20-\x7E]', '?')) } catch {} }
}

Write-Step "ZCode Windows 7 离线安装"
Write-Step "--------------------------"

$payload = Join-Path $PSScriptRoot "payload.zip"
$core = Join-Path $PSScriptRoot "install-core.ps1"
foreach ($required in @($payload, $core)) {
  if (-not (Test-Path -LiteralPath $required)) {
    Write-Step "安装包不完整，缺少：$required" "Red"
    exit 2
  }
}

$stage = Join-Path $env:TEMP "zcode-win7-setup"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Write-Step "  [1/4] 准备安装文件…"
Copy-Item -LiteralPath $payload -Destination (Join-Path $stage "payload.zip") -Force
Copy-Item -LiteralPath $core -Destination (Join-Path $stage "install-core.ps1") -Force
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot "README.txt")) {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "README.txt") -Destination (Join-Path $stage "README.txt") -Force
}
# 预置依赖（VxKex 安装程序）也要带到固定临时目录，install-core 才能找到。
$prereqDir = Join-Path $PSScriptRoot "prereq"
if (Test-Path -LiteralPath $prereqDir) {
  Copy-Item -LiteralPath $prereqDir -Destination (Join-Path $stage "prereq") -Recurse -Force
}

$installed = Get-ChildItem $stage -Recurse -File | Measure-Object Length -Sum
Write-Step ("      已准备 {0:N0} MB" -f ($installed.Sum / 1MB))

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator
)

$coreArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", (Join-Path $stage "install-core.ps1"),
  "-TargetDir", $TargetDir,
  "-Payload", (Join-Path $stage "payload.zip")
)
if ($NoShortcuts) { $coreArgs += "-NoShortcuts" }

if ($isAdmin) {
  & powershell @coreArgs
  exit $LASTEXITCODE
}

Write-Step "  [2/4] 请求管理员权限…"
try {
  $process = Start-Process -FilePath "powershell.exe" -ArgumentList $coreArgs -Verb RunAs -Wait -PassThru
  exit $process.ExitCode
} catch {
  Write-Step "未获得管理员权限，安装中止。" "Red"
  Write-Step "请右键本安装程序 → 以管理员身份运行。" "Yellow"
  exit 3
}
