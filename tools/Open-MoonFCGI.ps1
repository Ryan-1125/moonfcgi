# A separate editor process ensures the language server inherits this SDK.
. (Join-Path $PSScriptRoot 'Use-LocalToolchain.ps1')
$editor = (Get-Command code -ErrorAction Stop).Source
$profilePath = Join-Path $projectPath '.local/vscode'
& $editor --new-window --user-data-dir $profilePath $projectPath
