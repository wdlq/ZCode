#Requires -Version 5.1
<#
  ZCode for Windows 7 - core installer (requires administrator, unless -SkipRegistry)

  Steps:
    1. pre-checks (64-bit, PowerShell 5.1, free space, running instances)
    2. extract payload.zip into a staging folder, with live progress
    3. swap staging into the target folder (old install retired, then removed)
    4. register VxKex filter entries for ZCode.exe and node.exe
    5. create shortcuts + write install.json

  Notes:
  - Output is ASCII only. Windows 7 consoles may be CP936, CP65001 or use a raster
    font; non-ASCII output produced mojibake and even 0x1F write failures in the field.
  - Extraction prefers 7-Zip (multithreaded, shows %), falls back to .NET ZipFile
    with a per-500-files progress line. A 1 GB / 40k-file payload takes minutes on
    Windows 7 either way, so progress output is not cosmetic.
#>
[CmdletBinding()]
param(
  [string]$TargetDir = "C:\Program Files\ZCode-Win7",
  [string]$Payload = "",
  [string]$PrereqDir = "",
  [switch]$NoShortcuts,
  [switch]$SkipRegistry
)

$ErrorActionPreference = "Stop"

function Say {
  param(
    [Parameter(Position = 0)][string]$Text = "",
    [Parameter(Position = 1)][string]$Color = ""
  )
  try {
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
  } catch {
    try { [Console]::Out.WriteLine(($Text -replace '[^\x20-\x7E]', '?')) } catch { }
  }
}
function Fail([string]$Text) {
  Say ""
  Say "ERROR: $Text" "Red"
  exit 1
}

Say ""
Say "ZCode for Windows 7 - installer core"
Say "===================================="

# ---------------------------------------------------------------- 1. checks
if (-not $SkipRegistry) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
  )
  if (-not $isAdmin) { Fail "administrator rights required. Right-click the installer and choose 'Run as administrator'." }
}
if (-not [Environment]::Is64BitOperatingSystem) { Fail "64-bit Windows is required." }
if ($PSVersionTable.PSVersion.Major -lt 5) { Fail "PowerShell 5.1 is required (found $($PSVersionTable.PSVersion))." }

if ([string]::IsNullOrWhiteSpace($Payload)) { $Payload = Join-Path $PSScriptRoot "payload.zip" }
if (-not (Test-Path -LiteralPath $Payload)) { Fail "payload.zip not found: $Payload" }

$TargetDir = [System.IO.Path]::GetFullPath($TargetDir)
Say "Target  : $TargetDir"
Say ("Payload : {0:N1} MB" -f ((Get-Item -LiteralPath $Payload).Length / 1MB))

try {
  $driveRoot = [System.IO.Path]::GetPathRoot($TargetDir)
  $freeGb = [math]::Round((New-Object System.IO.DriveInfo($driveRoot)).AvailableFreeSpace / 1GB, 1)
  Say "Free    : $freeGb GB on $driveRoot"
  if ($freeGb -lt 2.0) { Fail "at least 2 GB free space is required on $driveRoot." }
} catch {
  Say "Free    : (could not determine)"
}

Say "Stopping running ZCode instances under the target folder..."
Get-Process ZCode -ErrorAction SilentlyContinue | Where-Object {
  $_.Path -and $_.Path.StartsWith($TargetDir, [System.StringComparison]::OrdinalIgnoreCase)
} | Stop-Process -Force -ErrorAction SilentlyContinue
Get-WmiObject Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object {
  $_.CommandLine -and $_.CommandLine.IndexOf($TargetDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------- 2. extract
# Staging must live at a SHORT path: Windows 7 enforces MAX_PATH (260). A
# %TEMP%\zcode-extract-<guid> prefix (~75 chars) plus deep node_modules entries
# overflows and makes 7-Zip abort mid-way (23k of 30k files in the field).
$staging = Join-Path $env:SystemDrive ("zc-stage-" + ([Guid]::NewGuid().ToString("N").Substring(0, 6)))
New-Item -ItemType Directory -Force -Path $staging | Out-Null

$entryCount = 0
$maxRelative = 0
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $probe = [System.IO.Compression.ZipFile]::OpenRead($Payload)
  try {
    $entryCount = $probe.Entries.Count
    foreach ($entry in $probe.Entries) {
      if ($entry.FullName.Length -gt $maxRelative) { $maxRelative = $entry.FullName.Length }
    }
  } finally { $probe.Dispose() }
} catch { }

Say ""
Say ("[1/4] Extracting {0:N0} entries to {1}..." -f $entryCount, $staging)
Say "      This can take several minutes on Windows 7. Progress below."
$longestPath = $staging.Length + 1 + $maxRelative
Say ("      Longest target path: {0} chars (Windows 7 limit is 260)." -f $longestPath)
if ($longestPath -gt 255) {
  Fail "the target path is too long for Windows 7 (MAX_PATH). Choose a shorter -TargetDir such as 'D:\ZCode'."
}
$started = Get-Date

$sevenZip = Join-Path $env:ProgramFiles "7-Zip\7z.exe"
if (Test-Path -LiteralPath $sevenZip) {
  Say "      Using 7-Zip (fast path)."
  # Native stderr must not become a terminating error: 7-Zip writes warnings there
  # and PowerShell would translate them into NativeCommandError and abort the run.
  $logOut = Join-Path $env:SystemDrive "zc-7z.out.log"
  $logErr = Join-Path $env:SystemDrive "zc-7z.err.log"
  $arguments = @("x", "-y", "-bso0", "-bsp1", "-o$staging", $Payload)
  $sevenZipProcess = Start-Process -FilePath $sevenZip -ArgumentList $arguments -NoNewWindow -PassThru `
    -RedirectStandardOutput $logOut -RedirectStandardError $logErr -ErrorAction Stop
  while (-not $sevenZipProcess.HasExited) {
    Start-Sleep -Seconds 5
    $last = ""
    try { $last = (Get-Content -LiteralPath $logOut -Tail 1 -ErrorAction SilentlyContinue) } catch { }
    if ($last -match "(\d{1,3})%") { Say ("      ... {0}%" -f [int]$Matches[1]) }
  }
  # Start-Process -PassThru does not always populate ExitCode after WaitForExit();
  # it can stay $null and then "$code -ne 0" would wrongly report a failure.
  $sevenZipProcess.WaitForExit()
  $sevenZipProcess.Refresh()
  $exitCode = $sevenZipProcess.ExitCode
  $extractedOk = (Test-Path -LiteralPath (Join-Path $staging "desktop\ZCode.exe")) -and
    (Test-Path -LiteralPath (Join-Path $staging "web\runtime\node.exe"))
  if (-not $extractedOk -or ($null -ne $exitCode -and $exitCode -ne 0)) {
    Say "      7-Zip reported errors:" "Yellow"
    try { Get-Content -LiteralPath $logErr -Tail 8 | ForEach-Object { Say ("      " + $_) } } catch { }
    Fail "extraction failed (exit code: $exitCode). A common cause is the 260-character path limit; try a shorter -TargetDir."
  }
  Remove-Item -LiteralPath $logOut, $logErr -Force -ErrorAction SilentlyContinue
} else {
  Say "      Using built-in .NET extraction (no 7-Zip found)."
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Payload)
  try {
    $index = 0
    foreach ($entry in $archive.Entries) {
      $index += 1
      $destination = Join-Path $staging $entry.FullName
      if ([string]::IsNullOrEmpty($entry.Name)) {
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
      } else {
        $parentDir = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parentDir)) { New-Item -ItemType Directory -Force -Path $parentDir | Out-Null }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $true)
      }
      if ($index % 500 -eq 0) { Say ("      ... {0:N0} / {1:N0} files" -f $index, $entryCount) }
    }
  } finally { $archive.Dispose() }
}
$elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 0)
Say ("      Extraction finished in {0} s." -f $elapsed)

# ---------------------------------------------------------------- 3. swap
Say ""
Say "[2/4] Installing into the target folder..."
$parent = Split-Path -Parent $TargetDir
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$retired = $null
if (Test-Path -LiteralPath $TargetDir) {
  $retired = $TargetDir + ".old-" + (Get-Date -Format "yyyyMMddHHmmss")
  Move-Item -LiteralPath $TargetDir -Destination $retired -Force
}
Move-Item -LiteralPath $staging -Destination $TargetDir -Force
if ($retired) { Remove-Item -LiteralPath $retired -Recurse -Force -ErrorAction SilentlyContinue }
Say "      Files are in place."

# ---------------------------------------------------------------- 4. VxKex
Say ""
Say "[3/4] Registering VxKex compatibility entries..."
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
  param([string]$ExePath)
  if (-not (Test-Path -LiteralPath $ExePath)) { return }
  $filterName = Get-PathFilterName -ExePath $ExePath
  $leaf = Split-Path -Leaf $ExePath
  $base = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$leaf"
  $filterKey = Join-Path $base $filterName
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
  Say "      $leaf -> $ExePath"
}

if ($SkipRegistry) {
  Say "      skipped (-SkipRegistry)."
} else {
  $vxKexDll = Join-Path $env:ProgramFiles "VxKex\Kex64\KxBase.dll"
  if (-not (Test-Path -LiteralPath $vxKexDll)) {
    Say "      VxKex-NEXT was not detected." "Yellow"
    $setup = if ($PrereqDir) { Join-Path $PrereqDir "KexSetup_Release_1_1_3_2038.exe" } else { "" }
    if ($setup -and (Test-Path -LiteralPath $setup)) {
      Say "      Launching the bundled VxKex installer. Re-run this installer afterwards."
      Start-Process -FilePath $setup | Out-Null
    } else {
      Say "      Install VxKex-NEXT first, then re-run this installer." "Yellow"
    }
    exit 2
  }
  Register-VxKexFilter -ExePath (Join-Path $TargetDir "desktop\ZCode.exe")
  Register-VxKexFilter -ExePath (Join-Path $TargetDir "web\runtime\node.exe")
}

# ---------------------------------------------------------------- 5. finish
Say ""
Say "[4/4] Shortcuts and install record..."
if (-not $NoShortcuts) {
  $shell = New-Object -ComObject WScript.Shell
  $startMenu = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\ZCode"
  New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
  foreach ($item in @(
      @{ File = "启动 ZCode 桌面版.cmd"; Name = "ZCode Desktop" },
      @{ File = "启动 ZCode Web 版.cmd"; Name = "ZCode Web" }
    )) {
    $target = Join-Path $TargetDir $item.File
    if (-not (Test-Path -LiteralPath $target)) { continue }
    $link = $shell.CreateShortcut((Join-Path $startMenu ($item.Name + ".lnk")))
    $link.TargetPath = $target
    $link.WorkingDirectory = $TargetDir
    $link.Save()
  }
  $desktopTarget = Join-Path $TargetDir "启动 ZCode 桌面版.cmd"
  if (Test-Path -LiteralPath $desktopTarget) {
    $desktopLink = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "ZCode Desktop.lnk"))
    $desktopLink.TargetPath = $desktopTarget
    $desktopLink.WorkingDirectory = $TargetDir
    $desktopLink.Save()
  }
  Say "      Shortcuts created."
} else {
  Say "      skipped (-NoShortcuts)."
}

$manifest = @{
  product       = "ZCode for Windows 7"
  version       = "3.16.2"
  installedAt   = (Get-Date).ToString("s")
  targetDir     = $TargetDir
  payloadSha256 = (Get-FileHash -LiteralPath $Payload -Algorithm SHA256).Hash
} | ConvertTo-Json -Depth 3
Set-Content -LiteralPath (Join-Path $TargetDir "install.json") -Value $manifest -Encoding UTF8

Say ""
Say "Installation completed: $TargetDir" "Green"
Say ""
Say "Next steps:"
Say "  1) Desktop: double-click the 'ZCode Desktop' shortcut (data: %APPDATA%\ZCode)"
Say "  2) Settings -> Models -> add a custom provider -> LAN base URL, e.g."
Say "     http://192.168.1.10:8000/v1 (OpenAI compatible) or an Anthropic endpoint."
Say "  3) Web: run 'ZCode Web' shortcut, then open http://127.0.0.1:3030/"
Say "     For LAN access run web\launcher\start-zcode.ps1 -LanAccess"
Say ""
exit 0
