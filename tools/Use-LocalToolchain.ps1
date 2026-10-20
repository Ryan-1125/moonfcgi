# Dot-source this file to select the private SDK in the current terminal.
$projectPath = Split-Path -Parent $PSScriptRoot
$localWork = Join-Path $projectPath '.local/work'
$sdkPath = Join-Path $localWork 'moon-sdk'
if (-not (Test-Path -LiteralPath (Join-Path $sdkPath 'bin/moon.exe'))) {
    throw 'Project-local SDK not found. Install a compatible system SDK or restore .local/work/moon-sdk.'
}
$env:MOON_HOME = $sdkPath
$env:PATH = (Join-Path $sdkPath 'bin') + ';' + $env:PATH
$env:MOONFCGI_WORK_DIR = $localWork
$env:GO_REFERENCE_BIN = Join-Path $localWork 'go-ref.exe'
$env:NGINX_BIN = Join-Path $localWork 'nginx-1.28.0/nginx.exe'
