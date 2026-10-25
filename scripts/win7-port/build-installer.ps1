# 在 Windows 7 目标机上组装离线安装包（payload.zip + 7z SFX 单文件安装器）。
#
# 前置：
#   - 已装 7-Zip（默认 C:\Program Files\7-Zip）；
#   - C:\ZCode（Web 形态）与 desktop-runtime（桌面形态）已就绪；
#   - tools/browser-verify.mjs、desktop-ui-check.mjs、AGENTS.md 已就位（见 -ToolsRoot）。
#
# 用法：
#   powershell -File scripts\win7-port\build-installer.ps1
#   可选参数见 param 块。
param(
  [string]$DesktopRoot = "C:\Users\sun-laptop\desktop-runtime",
  [string]$WebRoot = "C:\ZCode",
  [string]$ToolsRoot = "C:\Users\sun-laptop\ZCodeWorkspace",
  [string]$InstallerSrc = "",           # 默认取本脚本所在目录
  [string]$OutDir = "C:\win7-setup",
  [string]$PrereqInstaller = "",        # KexSetup_*.exe，可选
  [string]$SevenZip = "C:\Program Files\7-Zip\7z.exe"
)

$ErrorActionPreference = "Stop"
function Step([string]$Text) { Write-Host "==> $Text" }

if ([string]::IsNullOrWhiteSpace($InstallerSrc)) { $InstallerSrc = $PSScriptRoot }
$payload = Join-Path $OutDir "payload"
$sfxDir = Join-Path $OutDir "sfx"
foreach ($dir in @($payload, $sfxDir)) {
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# ---------------------------------------------------------------- desktop
Step "copy desktop runtime (exclude electron.exe)"
robocopy $DesktopRoot (Join-Path $payload "desktop") /E /XF electron.exe /NFL /NDL /NJH /NJS /NP | Out-Null

# ---------------------------------------------------------------- web
Step "copy web runtime"
robocopy (Join-Path $WebRoot "app\zcode") (Join-Path $payload "web\app\zcode") /E /NFL /NDL /NJH /NJS /NP | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $payload "web\runtime") | Out-Null
Copy-Item -LiteralPath (Join-Path $WebRoot "runtime\node.exe") -Destination (Join-Path $payload "web\runtime\node.exe") -Force
robocopy (Join-Path $WebRoot "launcher") (Join-Path $payload "web\launcher") /E /NFL /NDL /NJH /NJS /NP | Out-Null

# ---------------------------------------------------------------- tools / policy
Step "copy tools and AGENTS.md"
New-Item -ItemType Directory -Force -Path (Join-Path $payload "tools") | Out-Null
foreach ($tool in @("browser-verify.mjs", "desktop-ui-check.mjs")) {
  $source = Join-Path $ToolsRoot ("tools\" + $tool)
  if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $payload "tools\$tool") -Force }
}
if (Test-Path -LiteralPath (Join-Path $ToolsRoot "AGENTS.md")) {
  Copy-Item -LiteralPath (Join-Path $ToolsRoot "AGENTS.md") -Destination (Join-Path $payload "AGENTS.md") -Force
}
Copy-Item -LiteralPath (Join-Path $InstallerSrc "README.txt") -Destination (Join-Path $payload "README.txt") -Force

# ---------------------------------------------------------------- launchers
Step "write launchers"
function Write-Ascii([string]$Path, [string[]]$Lines) {
  [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
}
Write-Ascii (Join-Path $payload "启动 ZCode 桌面版.cmd") @(
  "@echo off",
  "start `"`" `"%~dp0desktop\ZCode.exe`""
)
Write-Ascii (Join-Path $payload "启动 ZCode 桌面版（调试）.cmd") @(
  "@echo off",
  "start `"`" `"%~dp0desktop\ZCode.exe`" --remote-debugging-port=9333"
)
Write-Ascii (Join-Path $payload "启动 ZCode Web 版.cmd") @(
  "@echo off",
  "setlocal",
  "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0web\launcher\start-zcode.ps1`" %*",
  "if errorlevel 1 pause"
)
Write-Ascii (Join-Path $payload "停止 ZCode Web 版.cmd") @(
  "@echo off",
  "setlocal",
  "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0web\launcher\stop-zcode.ps1`" %*",
  "timeout /t 3 >nul"
)

# ---------------------------------------------------------------- payload.zip
$payloadZip = Join-Path $OutDir "payload.zip"
if (Test-Path -LiteralPath $payloadZip) { Remove-Item -LiteralPath $payloadZip -Force }
Step "compress payload.zip (several minutes)"
& $SevenZip a -tzip -mx5 -mm=Deflate -bso0 -bsp0 $payloadZip (Join-Path $payload "*") | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z zip failed: $LASTEXITCODE" }

# ---------------------------------------------------------------- sfx
Step "assemble sfx sources"
foreach ($name in @("install.ps1", "install-core.ps1", "README.txt", "config.txt")) {
  Copy-Item -LiteralPath (Join-Path $InstallerSrc $name) -Destination (Join-Path $sfxDir $name) -Force
}
Copy-Item -LiteralPath $payloadZip -Destination (Join-Path $sfxDir "payload.zip") -Force
if ($PrereqInstaller -and (Test-Path -LiteralPath $PrereqInstaller)) {
  New-Item -ItemType Directory -Force -Path (Join-Path $sfxDir "prereq") | Out-Null
  Copy-Item -LiteralPath $PrereqInstaller -Destination (Join-Path $sfxDir "prereq") -Force
}

$setupExe = Join-Path $OutDir "ZCode-Win7-Offline-Setup.exe"
if (Test-Path -LiteralPath $setupExe) { Remove-Item -LiteralPath $setupExe -Force }
Step "build self-extracting installer"
# 注意：`-mx0` 避免对已压缩的 payload.zip 二次压缩；
#       SFX 模块用默认 `7z.sfx`（`-sfx7zCon.sfx` 在部分环境报 cannot find specified SFX module）。
Push-Location $OutDir
try {
  & $SevenZip a -sfx -mx0 -bso0 $setupExe (Join-Path $sfxDir "*") | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "7z sfx failed: $LASTEXITCODE" }
} finally { Pop-Location }

Write-Host ("payload.zip : {0:N1} MB" -f ((Get-Item $payloadZip).Length / 1MB))
Write-Host ("setup exe   : {0:N1} MB" -f ((Get-Item $setupExe).Length / 1MB))
(Get-FileHash $setupExe -Algorithm SHA256).Hash | Out-File "$setupExe.sha256" -Encoding ascii
Write-Host "done: $setupExe"
