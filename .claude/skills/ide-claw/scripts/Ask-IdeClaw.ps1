param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Message,

    [Parameter(Mandatory = $false)]
    [string]$Workspace = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [switch]$MobileOnly,

    [Parameter(Mandatory = $false)]
    [string]$IdeClawHome = $env:IDE_CLAW_HOME,

    [Parameter(Mandatory = $false)]
    [string]$Python = $env:IDE_CLAW_PYTHON,

    [Parameter(Mandatory = $false)]
    [string]$DesktopExe = $env:IDE_CLAW_DESKTOP_EXE
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($IdeClawHome)) {
    $IdeClawHome = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..\..")).Path
}

if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = "python"
}

if ([string]::IsNullOrWhiteSpace($DesktopExe)) {
    $DesktopExe = Join-Path $IdeClawHome "dist\ide-claw-windows\ide_claw.exe"
}

$dialog = Join-Path $IdeClawHome "cascade\dialog.py"
if (-not (Test-Path -LiteralPath $dialog)) {
    throw "dialog.py not found: $dialog"
}

$workspacePath = $Workspace
try {
    $workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
} catch {
    # dialog.py can still continue and report the missing workspace path.
}

Write-Output "WORKSPACE=$workspacePath"

if (-not $MobileOnly) {
    $desktopAlive = $false
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:13800/ping" -TimeoutSec 2
        $desktopAlive = $true
    } catch {
        $desktopAlive = $false
    }

    if (-not $desktopAlive) {
        if (Test-Path -LiteralPath $DesktopExe) {
            Start-Process -FilePath $DesktopExe
            Start-Sleep -Seconds 4
        } else {
            Write-Warning "Desktop EXE not found: $DesktopExe"
        }
    }
}

& $Python $dialog $Message --workspace $workspacePath
exit $LASTEXITCODE
