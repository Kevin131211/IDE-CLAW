param(
    [Parameter(Mandatory = $false)]
    [string]$Workspace = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [string]$IdeClawHome = $env:IDE_CLAW_HOME,

    [Parameter(Mandatory = $false)]
    [string]$Python = $env:IDE_CLAW_PYTHON,

    [Parameter(Mandatory = $false)]
    [string]$Text
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($IdeClawHome)) {
    $IdeClawHome = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..\..")).Path
}

if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = "python"
}

$notify = Join-Path $IdeClawHome "cascade\notify.py"
if (-not (Test-Path -LiteralPath $notify)) {
    throw "notify.py not found: $notify"
}

$workspacePath = $Workspace
try {
    $workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
} catch {
    # notify.py can still derive a stable ID from the supplied path string.
}

$argsList = @($notify, "--workspace", $workspacePath)
if (-not [string]::IsNullOrWhiteSpace($Text)) {
    $argsList += @("--text", $Text)
}

& $Python @argsList
exit $LASTEXITCODE
