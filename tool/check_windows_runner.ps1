param([string]$WindowSource)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (!$WindowSource) { $WindowSource = Join-Path $repoRoot 'windows/runner/flutter_window.cpp' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$installation) { throw 'Visual Studio C++ tools are required' }
$dev = Join-Path $installation 'Common7/Tools/VsDevCmd.bat'
$scratch = Join-Path $repoRoot ('build/runner-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$flutter = Join-Path $repoRoot 'windows/flutter/ephemeral'
$wrapper = Join-Path $repoRoot 'build/windows/x64/flutter/Release/flutter_wrapper_app.lib'
$exe = Join-Path $scratch 'runner-test.exe'
# The wrapper library comes from the Windows release build. The test invokes
# the real native message handler without opening a window or user database.
$arguments = @('/nologo', '/std:c++17', '/EHsc', '/MD', '/DUNICODE', '/D_UNICODE',
    ('/I"' + $flutter + '"'), ('/I"' + $flutter + '/cpp_client_wrapper/include"'),
    ('/I"' + $repoRoot + '/windows"'), ('/I"' + $repoRoot + '/windows/runner"'),
    ('"' + $repoRoot + '/test/native/flutter_window_test.cpp"'), ('"' + $WindowSource + '"'),
    ('"' + $repoRoot + '/windows/runner/win32_window.cpp"'), ('/Fe"' + $exe + '"'),
    '/link', ('"' + $wrapper + '"'), ('"' + $flutter + '/flutter_windows.dll.lib"'),
    'user32.lib', 'advapi32.lib', 'dwmapi.lib') -join ' '
Push-Location -LiteralPath $scratch
try {
    $compile = @('@echo off', ('call "' + $dev + '" -arch=x64 -host_arch=x64 >nul'), 'if errorlevel 1 exit /b 1', ('cl.exe ' + $arguments))
    Set-Content -LiteralPath (Join-Path $scratch 'compile.cmd') -Value $compile -Encoding ascii
    & $env:COMSPEC /d /c compile.cmd
    if ($LASTEXITCODE -ne 0) { throw 'Native window test compilation failed' }
    Copy-Item -LiteralPath (Join-Path $flutter 'flutter_windows.dll') -Destination $scratch
    & $exe
    if ($LASTEXITCODE -ne 0) { throw "Native window lifecycle test failed: $LASTEXITCODE" }
    Write-Output 'Native font-change messages before initialization and after teardown passed.'
} finally {
    Pop-Location
}
