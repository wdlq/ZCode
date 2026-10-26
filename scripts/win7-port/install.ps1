#Requires -Version 5.1
<#
  ZCode for Windows 7 - offline installer (bootstrap)

  Why this split:
  - The self-extracting package unpacks itself into %TEMP% and deletes that folder
    as soon as this script exits, while the elevated child process still needs the
    payload. So when elevation is required we copy the payload to a stable folder.
  - When we are already elevated (e.g. right-click "Run as administrator") we run
    the core installer in place and skip a 322 MB copy.

  All console output is ASCII on purpose: Windows 7 consoles may run CP936, CP65001
  or a raster font that cannot render CJK, which produced mojibake in the field.
#>
[CmdletBinding()]
param(
  [string]$TargetDir = "C:\Program Files\ZCode-Win7",
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

Say ""
Say "ZCode for Windows 7 - offline installer"
Say "======================================="
Say "Target : $TargetDir"

$payload = Join-Path $PSScriptRoot "payload.zip"
$core = Join-Path $PSScriptRoot "install-core.ps1"
$prereqDir = Join-Path $PSScriptRoot "prereq"
foreach ($required in @($payload, $core)) {
  if (-not (Test-Path -LiteralPath $required)) {
    Say "ERROR: incomplete package, missing $required" "Red"
    exit 2
  }
}
$payloadMb = [math]::Round((Get-Item -LiteralPath $payload).Length / 1MB, 1)
Say "Payload: $payloadMb MB"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator
)
if ($isAdmin) {
  Say "Running with administrator rights."
  Say ""
}

# Always stage to a stable folder: the self-extracting launcher may remove its own
# temp folder as soon as this script exits, while the installer (or its elevated
# child) is still reading payload.zip.
Say "Copying installer files to a temporary folder..."
$stage = Join-Path $env:TEMP "zcode-win7-setup"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item -LiteralPath $payload -Destination (Join-Path $stage "payload.zip") -Force
Copy-Item -LiteralPath $core -Destination (Join-Path $stage "install-core.ps1") -Force
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot "README.txt")) {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "README.txt") -Destination (Join-Path $stage "README.txt") -Force
}
if (Test-Path -LiteralPath $prereqDir) {
  Copy-Item -LiteralPath $prereqDir -Destination (Join-Path $stage "prereq") -Recurse -Force
}
Say "Done."

$stagedArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", ('"' + (Join-Path $stage "install-core.ps1") + '"'),
  "-TargetDir", ('"' + $TargetDir + '"'),
  "-Payload", ('"' + (Join-Path $stage "payload.zip") + '"')
)
if (Test-Path -LiteralPath (Join-Path $stage "prereq")) { $stagedArgs += @("-PrereqDir", ('"' + (Join-Path $stage "prereq") + '"')) }
if ($NoShortcuts) { $stagedArgs += "-NoShortcuts" }
if ($SkipRegistry) { $stagedArgs += "-SkipRegistry" }

if ($isAdmin) {
  # Detach: the self-extracting launcher exits immediately after starting Setup and
  # takes its whole process tree (job object) with it. A WMI-created process is
  # outside that job, so extraction survives. `start` gives it its own console.
  $argumentLine = @(
    '-NoProfile', '-ExecutionPolicy Bypass', '-File', ('"' + (Join-Path $stage 'install-core.ps1') + '"'),
    '-TargetDir', ('"' + $TargetDir + '"'),
    '-Payload', ('"' + (Join-Path $stage 'payload.zip') + '"')
  )
  if (Test-Path -LiteralPath (Join-Path $stage 'prereq')) {
    $argumentLine += @('-PrereqDir', ('"' + (Join-Path $stage 'prereq') + '"'))
  }
  if ($NoShortcuts) { $argumentLine += '-NoShortcuts' }
  if ($SkipRegistry) { $argumentLine += '-SkipRegistry' }
  $commandLine = 'cmd.exe /c start "ZCode Setup" powershell.exe ' + ($argumentLine -join ' ')
  $result = ([wmiclass]"Win32_Process").Create($commandLine, $stage, $null)
  if ($result.ReturnValue -ne 0) {
    Say "ERROR: failed to start the installer (Win32_Process.Create returned $($result.ReturnValue))." "Red"
    exit 4
  }
  Say "Installer started in a separate window (PID $($result.ProcessId))."
  Say "Follow the progress there; this window can be closed."
  exit 0
}

Say "Requesting administrator privileges (please confirm the UAC prompt)..."
try {
  $process = Start-Process -FilePath "powershell.exe" -ArgumentList $stagedArgs -Verb RunAs -Wait -PassThru
  exit $process.ExitCode
} catch {
  Say "ERROR: administrator rights were not granted. Installation aborted." "Red"
  Say "Right-click the installer and choose 'Run as administrator'." "Yellow"
  exit 3
}
