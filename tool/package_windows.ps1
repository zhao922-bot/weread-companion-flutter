param([string]$Version)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (!$Version) {
    $Version = [regex]::Match((Get-Content (Join-Path $repoRoot 'pubspec.yaml') -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)').Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid release version' }
$bundle = Join-Path $repoRoot 'build/windows/x64/runner/Release'
foreach ($required in @('weread_companion.exe', 'flutter_windows.dll', 'sqlite3.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'data/app.so', 'data/icudtl.dat')) {
    if (!(Test-Path -LiteralPath (Join-Path $bundle $required))) { throw "Missing runtime file: $required" }
}
$output = Join-Path $repoRoot 'build/releases'
$payload = Join-Path $repoRoot 'build/windows-package'
New-Item -ItemType Directory -Path $output, $payload -Force | Out-Null
$portable = Join-Path $output "readamber-v$Version-windows-x64.zip"
Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $portable -Force
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw 'Windows .NET Framework compiler is required' }
$metadata = Join-Path $payload 'AssemblyInfo.cs'
$build = [regex]::Match((Get-Content (Join-Path $repoRoot 'pubspec.yaml') -Raw), '(?m)^version:\s*\d+\.\d+\.\d+\+(\d+)').Groups[1].Value
$attributes = @"
using System.Reflection;
[assembly: AssemblyTitle("ReadAmber Setup")]
[assembly: AssemblyProduct("ReadAmber")]
[assembly: AssemblyCompany("zhao922-bot")]
[assembly: AssemblyVersion("$Version.$build")]
[assembly: AssemblyFileVersion("$Version.$build")]
"@
[IO.File]::WriteAllText($metadata, $attributes)
$exe = Join-Path $output "readamber-v$Version-windows-x64-setup.exe"
& $compiler /nologo /target:winexe /platform:x64 /optimize+ "/out:$exe" "/resource:$portable,application.zip" "/win32icon:$(Join-Path $repoRoot 'windows/runner/resources/app_icon.ico')" /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:System.Windows.Forms.dll /reference:Microsoft.CSharp.dll (Join-Path $repoRoot 'tool/windows_bootstrap.cs') $metadata
if ($LASTEXITCODE -ne 0) { throw 'Windows bundle compilation failed' }
Get-Item -LiteralPath $exe, $portable | Select-Object Name, Length
