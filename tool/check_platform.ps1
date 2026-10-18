$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# Check both Android backup transports and their manifest resource references.
[xml]$manifest = Get-Content (Join-Path $repoRoot 'android/app/src/main/AndroidManifest.xml') -Raw
$android = 'http://schemas.android.com/apk/res/android'
foreach ($pair in @(@('fullBackupContent', 'backup_rules'), @('dataExtractionRules', 'data_extraction_rules'))) {
    if ($manifest.manifest.application.GetAttribute($pair[0], $android) -ne "@xml/$($pair[1])") {
        throw "Android manifest is missing $($pair[0])"
    }
    [xml]$rules = Get-Content (Join-Path $repoRoot "android/app/src/main/res/xml/$($pair[1]).xml") -Raw
    $groups = if ($pair[1] -eq 'backup_rules') { @($rules.'full-backup-content') } else { @($rules.'data-extraction-rules'.'cloud-backup', $rules.'data-extraction-rules'.'device-transfer') }
    foreach ($group in $groups) {
        foreach ($name in @('FlutterSecureStorage.xml', 'FlutterSecureKeyStorage.xml')) {
            if (!($group.exclude | Where-Object { $_.domain -eq 'sharedpref' -and $_.path -eq $name })) {
                throw "Android backup rules must exclude $name in every transport"
            }
        }
    }
}
Write-Output 'Android credential backup exclusions passed (configuration check).'

if ($env:OS -ne 'Windows_NT') {
    Write-Output 'Windows installer runtime tests skipped on this host.'
    return
}
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build'))
$scratch = [IO.Path]::GetFullPath((Join-Path $buildRoot ('platform-tests-' + [guid]::NewGuid().ToString('N'))))
if (!$scratch.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid test workspace' }
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $exe = Join-Path $scratch 'bootstrap-test.exe'
    & $compiler /nologo /target:exe /platform:x64 /main:WindowsBootstrapTest "/out:$exe" /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:System.Windows.Forms.dll /reference:Microsoft.CSharp.dll (Join-Path $repoRoot 'tool/windows_bootstrap.cs') (Join-Path $repoRoot 'test/native/windows_bootstrap_test.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Installer tests did not compile' }
    & $exe $scratch
    if ($LASTEXITCODE -ne 0) { throw 'Installer tests failed' }
} finally {
    # Only this randomly named test workspace is removed.
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
