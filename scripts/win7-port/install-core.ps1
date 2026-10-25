#Requires -Version 5.1
<#
  ZCode Windows 7 离线安装包 —— 核心安装逻辑（需管理员权限）

  做的事：
  1. 环境自检（64 位、PowerShell 5.1、VxKex-NEXT）
  2. 解包 payload.zip 到安装目录（先解到临时目录再原子替换，便于覆盖升级）
  3. 为两个 exe 注册 VxKex 过滤项（按绝对路径匹配，换目录必须重注册）
  4. 创建桌面 / 开始菜单快捷方式
  5. 写 install.json 并输出下一步指引
#>
[CmdletBinding()]
param(
  [string]$TargetDir = "C:\Program Files\ZCode-Win7",
  [string]$Payload = "",
  [switch]$NoShortcuts
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Step([string]$Text, [string]$Color = "") {
  try {
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
  } catch { try { [Console]::Out.WriteLine(($Text -replace '[^\x20-\x7E]', '?')) } catch {} }
}
function Fail([string]$Text) {
  Write-Step $Text "Red"
  exit 1
}

Write-Step ""
Write-Step "=== ZCode Windows 7 离线安装 ==="

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) { Fail "需要管理员权限：请右键安装程序 → 以管理员身份运行。" }
if (-not [Environment]::Is64BitOperatingSystem) { Fail "仅支持 64 位 Windows 7。" }
if ($PSVersionTable.PSVersion.Major -lt 5) { Fail "需要 PowerShell 5.1（当前 $($PSVersionTable.PSVersion)），请先安装 WMF 5.1。" }

# ---------------------------------------------------------------- 1. VxKex
$vxKexRoot = Join-Path $env:ProgramFiles "VxKex"
$vxKexDll = Join-Path $vxKexRoot "Kex64\KxBase.dll"
if (-not (Test-Path -LiteralPath $vxKexDll)) {
  Write-Step "未检测到 VxKex-NEXT。" "Yellow"
  Write-Step "Windows 7 上 Electron 41 与 Node 24 必须依赖 VxKex 补齐 Win8/Win10 导出。" "Yellow"
  $prereq = Join-Path $PSScriptRoot "prereq\KexSetup_Release_1_1_3_2038.exe"
  if (Test-Path -LiteralPath $prereq) {
    Write-Step "正在启动 VxKex 安装程序，请按其向导完成安装后重新运行本安装包…"
    Start-Process -FilePath $prereq | Out-Null
  } else {
    Write-Step "请先安装 VxKex-NEXT（https://github.com/vxiiduu/VxKex 的 NEXT 分支），再重新运行。" 
  }
  exit 2
}

# ---------------------------------------------------------------- 2. 解包
if ([string]::IsNullOrWhiteSpace($Payload)) {
  $Payload = Join-Path $PSScriptRoot "payload.zip"
}
if (-not (Test-Path -LiteralPath $Payload)) { Fail "缺少 payload.zip：$Payload" }

Write-Step "  [1/4] 解压运行文件到 $TargetDir …"
# 覆盖安装前先停掉本目录下运行中的实例，否则文件被占用会导致目录替换失败。
Get-Process ZCode -ErrorAction SilentlyContinue | Where-Object {
  $_.Path -and $_.Path.StartsWith($TargetDir, [System.StringComparison]::OrdinalIgnoreCase)
} | Stop-Process -Force -ErrorAction SilentlyContinue
Get-WmiObject Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object {
  $_.CommandLine -and $_.CommandLine.IndexOf($TargetDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$staging = Join-Path $env:TEMP ("zcode-extract-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($Payload, $staging)

$parent = Split-Path -Parent $TargetDir
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$retired = $null
if (Test-Path -LiteralPath $TargetDir) {
  $retired = $TargetDir + ".old-" + (Get-Date -Format "yyyyMMddHHmmss")
  Move-Item -LiteralPath $TargetDir -Destination $retired -Force
}
Move-Item -LiteralPath $staging -Destination $TargetDir -Force
if ($retired) { Remove-Item -LiteralPath $retired -Recurse -Force -ErrorAction SilentlyContinue }

Write-Step "  [2/4] 注册 VxKex 兼容项…"
# 过滤项名按路径哈希生成：同一个 exe 名（ZCode.exe / node.exe）可能在同一台机器上
# 存在多份安装（如测试目录与正式目录），固定名字会让后装的覆盖先装的 FilterFullPath。
function Get-PathFilterName {
  param([string]$ExePath)
  $sha = [System.Security.Cryptography.SHA1]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ExePath.ToLowerInvariant())
    $hex = -join ($sha.ComputeHash($bytes)[0..3] | ForEach-Object { $_.ToString("x2") })
    return "VxKex_ZCODE_$hex"
  } finally { $sha.Dispose() }
}

function Register-VxKexFilter {
  param([string]$ExePath, [string]$FilterName)
  if (-not $FilterName) { $FilterName = Get-PathFilterName -ExePath $ExePath }
  $leaf = Split-Path -Leaf $ExePath
  $base = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$leaf"
  $filterKey = Join-Path $base $FilterName
  if (-not (Test-Path -LiteralPath $base)) { New-Item -Path $base -Force | Out-Null }
  New-Item -Path $filterKey -Force | Out-Null
  $values = @{
    FilterFullPath         = @("String", $ExePath)
    KEX_DisableForChild    = @("DWord", 0)
    KEX_DisableAppSpecific = @("DWord", 0)
    KEX_WinVerSpoof        = @("DWord", 0)
    KEX_StrongVersionSpoof = @("DWord", 0)
    GlobalFlag             = @("DWord", 256)
    VerifierFlags          = @("DWord", 2147483648)
    VerifierDlls           = @("String", "kexdll.dll")
  }
  foreach ($name in $values.Keys) {
    New-ItemProperty -Path $filterKey -Name $name -PropertyType $values[$name][0] `
      -Value $values[$name][1] -Force | Out-Null
  }
  New-ItemProperty -Path $base -Name UseFilter -PropertyType DWord -Value 1 -Force | Out-Null
  Write-Step "      $leaf → $ExePath"
}

$desktopExe = Join-Path $TargetDir "desktop\ZCode.exe"
$webNodeExe = Join-Path $TargetDir "web\runtime\node.exe"
if (Test-Path -LiteralPath $desktopExe) { Register-VxKexFilter -ExePath $desktopExe }
if (Test-Path -LiteralPath $webNodeExe) { Register-VxKexFilter -ExePath $webNodeExe }

# ---------------------------------------------------------------- 3. 快捷方式
if (-not $NoShortcuts) {
  Write-Step "  [3/4] 创建快捷方式…"
  $shell = New-Object -ComObject WScript.Shell
  $startMenuDir = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\ZCode"
  New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
  $targets = @(
    @{ Path = (Join-Path $TargetDir "启动 ZCode 桌面版.cmd"); Name = "ZCode 桌面版" },
    @{ Path = (Join-Path $TargetDir "启动 ZCode Web 版.cmd"); Name = "ZCode Web 版" }
  )
  foreach ($item in $targets) {
    if (-not (Test-Path -LiteralPath $item.Path)) { continue }
    $link = $shell.CreateShortcut((Join-Path $startMenuDir ($item.Name + ".lnk")))
    $link.TargetPath = $item.Path
    $link.WorkingDirectory = $TargetDir
    $link.Description = "ZCode for Windows 7"
    $link.Save()
  }
  $desktopLink = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "ZCode 桌面版.lnk"))
  $desktopLink.TargetPath = Join-Path $TargetDir "启动 ZCode 桌面版.cmd"
  $desktopLink.WorkingDirectory = $TargetDir
  $desktopLink.Save()
} else {
  Write-Step "  [3/4] 跳过快捷方式"
}

# ---------------------------------------------------------------- 4. 完成
Write-Step "  [4/4] 写入安装记录…"
$manifest = @{
  product   = "ZCode for Windows 7"
  version   = "3.16.2"
  installedAt = (Get-Date).ToString("s")
  targetDir = $TargetDir
  payloadSha256 = (Get-FileHash -LiteralPath $Payload -Algorithm SHA256).Hash
} | ConvertTo-Json -Depth 3
Set-Content -LiteralPath (Join-Path $TargetDir "install.json") -Value $manifest -Encoding UTF8

Write-Step ""
Write-Step "安装完成：$TargetDir" "Green"
Write-Step ""
Write-Step "下一步：" 
Write-Step "  1) 双击桌面「ZCode 桌面版」启动（首次启动会创建 %APPDATA%\ZCode）"
Write-Step "  2) 设置 → 模型设置 → 添加供应商 → 创建自定义供应商"
Write-Step "     Base URL 填局域网模型地址（如 http://192.168.x.x:8000/v1，OpenAI 兼容）"
Write-Step "     或 Anthropic 兼容地址；填入 API Key 并启用模型"
Write-Step "  3) Web 版：双击「启动 ZCode Web 版」，浏览器打开 http://127.0.0.1:3030/"
Write-Step "     需要局域网访问时用 web\launcher\start-zcode.ps1 -LanAccess"
exit 0
