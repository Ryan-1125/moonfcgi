[CmdletBinding()]
param([switch]$Isolated)

. (Join-Path $PSScriptRoot 'Use-LocalToolchain.ps1')
$editor = (Get-Command code -ErrorAction Stop).Source
if ($Isolated) {
    # Opt in to a separate extension host and separate editor preferences.
    $profilePath = Join-Path $projectPath '.local/vscode'
    & $editor --new-window --user-data-dir $profilePath $projectPath
} else {
    # Preserve the user's normal language, extensions and preferences.
    & $editor --reuse-window $projectPath
    Write-Host 'In a new terminal, run: . ./tools/Use-LocalToolchain.ps1'
    Write-Host 'An existing editor language server may still use its original SDK. Use -Isolated only if a separate SDK environment is needed.'
}
