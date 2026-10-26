# 组装 Windows 7 离线安装包（payload.zip + WinRAR SFX 单文件安装器）。
#
# 必须在一台 Windows 7 目标机上执行打包，且使用 WinRAR >= 7.21：
#   - 7-Zip 自带的 7z.sfx 只解压、不执行 config.txt 里的 RunProgram（实测 24.09 无效），
#     所以不能用 `7z a -sfx` 做"一键安装器"；
#   - WinRAR 7.11 的 SFX stub 在 Win7 上会静默退出（0 秒、退出码 0、什么都不做），
#     7.21.1 实测正常。版本对不上时表现为"双击没反应"。
#
# 用法：
#   powershell -File scripts\win7-port\build-installer.ps1 `
#     -DesktopRoot "C:\Users\sun-laptop\desktop-runtime" `
#     -WebRoot "C:\ZCode" `
#     -ToolsRoot "C:\Users\sun-laptop\ZCodeWorkspace" `
#     -OutDir "C:\win7-setup"
param(
  [string]$DesktopRoot = "C:\Users\sun-laptop\desktop-runtime",
  [string]$WebRoot = "C:\ZCode",
  [string]$ToolsRoot = "C:\Users\sun-laptop\ZCodeWorkspace",
  [string]$InstallerSrc = "",           # 默认取本脚本所在目录
  [string]$OutDir = "C:\win7-setup",
  [string]$PrereqInstaller = "",        # KexSetup_*.exe，可选
  [string]$WinRar = "C:\Program Files\WinRAR\WinRAR.exe",
  [string]$SevenZip = "C:\Program Files\7-Zip\7z.exe"
)

$ErrorActionPreference = "Stop"
function Step([string]$Text) { Write-Host "==> $Text" }

if ([string]::IsNullOrWhiteSpace($InstallerSrc)) { $InstallerSrc = $PSScriptRoot }
if (-not (Test-Path -LiteralPath $WinRar)) { throw "WinRAR not found: $WinRar (SFX building requires it)." }
$winRarVersion = (Get-Item $WinRar).VersionInfo.FileVersion
Write-Host "WinRAR: $winRarVersion"

$payload = Join-Path $OutDir "payload"
$sfxDir = Join-Path $OutDir "sfx"
foreach ($dir in @($payload, $sfxDir)) {
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# ---------------------------------------------------------------- payload
Step "copy desktop runtime (exclude electron.exe)"
robocopy $DesktopRoot (Join-Path $payload "desktop") /E /XF electron.exe /NFL /NDL /NJH /NJS /NP | Out-Null

Step "copy web runtime"
robocopy (Join-Path $WebRoot "app\zcode") (Join-Path $payload "web\app\zcode") /E /NFL /NDL /NJH /NJS /NP | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $payload "web\runtime") | Out-Null
Copy-Item -LiteralPath (Join-Path $WebRoot "runtime\node.exe") -Destination (Join-Path $payload "web\runtime\node.exe") -Force
robocopy (Join-Path $WebRoot "launcher") (Join-Path $payload "web\launcher") /E /NFL /NDL /NJH /NJS /NP | Out-Null

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

$payloadZip = Join-Path $OutDir "payload.zip"
if (Test-Path -LiteralPath $payloadZip) { Remove-Item -LiteralPath $payloadZip -Force }
Step "compress payload.zip (several minutes)"
& $SevenZip a -tzip -mx5 -mm=Deflate -bso0 -bsp0 $payloadZip (Join-Path $payload "*") | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z zip failed: $LASTEXITCODE" }

# ---------------------------------------------------------------- sfx
Step "assemble sfx sources"
foreach ($name in @("install.ps1", "install-core.ps1", "README.txt")) {
  Copy-Item -LiteralPath (Join-Path $InstallerSrc $name) -Destination (Join-Path $sfxDir $name) -Force
}
Copy-Item -LiteralPath $payloadZip -Destination (Join-Path $sfxDir "payload.zip") -Force
if ($PrereqInstaller -and (Test-Path -LiteralPath $PrereqInstaller)) {
  New-Item -ItemType Directory -Force -Path (Join-Path $sfxDir "prereq") | Out-Null
  Copy-Item -LiteralPath $PrereqInstaller -Destination (Join-Path $sfxDir "prereq") -Force
}

$sfxConfig = Join-Path $OutDir "sfx-config.txt"
Copy-Item -LiteralPath (Join-Path $InstallerSrc "sfx-config.txt") -Destination $sfxConfig -Force

$setupExe = Join-Path $OutDir "ZCode-Win7-Offline-Setup.exe"
if (Test-Path -LiteralPath $setupExe) { Remove-Item -LiteralPath $setupExe -Force }
Step "build WinRAR SFX installer"
Push-Location $sfxDir
try {
  # -r 必须带上，否则 prereq\ 不会被收进归档；
  # -m0 只存储（payload.zip 已压缩），避免二次压缩。
  & $WinRar a -sfx -r -m0 -ep1 -z"$sfxConfig" $setupExe * | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "WinRAR sfx failed: $LASTEXITCODE" }
} finally { Pop-Location }

Write-Host ("payload.zip : {0:N1} MB" -f ((Get-Item $payloadZip).Length / 1MB))
Write-Host ("setup exe   : {0:N1} MB" -f ((Get-Item $setupExe).Length / 1MB))
(Get-FileHash $setupExe -Algorithm SHA256).Hash | Out-File "$setupExe.sha256" -Encoding ascii
Write-Host "done: $setupExe"
