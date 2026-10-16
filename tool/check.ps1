param(
    [string]$Flutter = 'flutter',
    [switch]$BuildApk,
    # Kept for compatibility; full coverage is now always required.
    [switch]$RequireFullCoverage
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$flutterPath = (Get-Command $Flutter -ErrorAction Stop).Source
$dartName = if ($flutterPath.EndsWith('.bat')) { 'dart.bat' } else { 'dart' }
$dartPath = Join-Path (Split-Path -Parent $flutterPath) $dartName

Push-Location -LiteralPath $repoRoot
try {
    & $flutterPath analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed.' }
    & $flutterPath test --no-pub --branch-coverage --coverage-path=build/coverage/lcov.info
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
    & $dartPath run tool/coverage_report.dart --check --require-full
    if ($LASTEXITCODE -ne 0) { throw 'Coverage must be 100% for lines and branches across all executable lib files. See build/coverage/report.txt.' }
    if ($BuildApk) {
        & $flutterPath build apk --debug --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Android debug build failed.' }
    }
} finally {
    Pop-Location
}
