# Native entrypoint: never resolve bare bash.exe (which may be WSL).
param([ValidateSet('manager', 'open')][string]$Mode = 'manager')
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'open') {
    $herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
    & $herdr plugin pane open --plugin ray.plugin-manager --entrypoint manager-windows --placement popup --focus
    exit $LASTEXITCODE
}

$candidates = @()
if ($env:HERDR_PM_GIT_BASH) {
    $candidates = @($env:HERDR_PM_GIT_BASH)
} else {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if ($base) { $candidates += Join-Path $base 'Git\bin\bash.exe' }
    }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $gitDir = Split-Path $git.Source
        $candidates += Join-Path (Split-Path $gitDir) 'bin\bash.exe'
        $candidates += Join-Path $gitDir 'bash.exe'
    }
}
$bash = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $bash) {
    throw 'Git Bash not found. Install Git for Windows or set HERDR_PM_GIT_BASH to its bin\bash.exe (not WSL).'
}
# Supply the script as one argument rather than a bash -c expression: Windows
# PowerShell's legacy native quoting would strip its embedded double quotes.
$bashDir = Split-Path $bash
$tools = Join-Path (Split-Path $bashDir) 'usr\bin'
$env:PATH = "$tools;$bashDir;$env:PATH"
& $bash -- ($env:HERDR_PLUGIN_ROOT.Replace('\', '/') + '/bin/manager.sh')
exit $LASTEXITCODE
