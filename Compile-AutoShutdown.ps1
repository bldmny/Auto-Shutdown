param(
    [string]$SourceScript = "",
    [string]$IconFile = "",
    [string]$OutputExe = ""
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")

if ([string]::IsNullOrWhiteSpace($SourceScript)) {

    $SourceScript = Join-Path $root "outputs\NetworkAutoShutdown-GUI.ps1"
}

if ([string]::IsNullOrWhiteSpace($IconFile)) {

    $IconFile = Join-Path $root "outputs\AutoShutdown.ico"
}

if ([string]::IsNullOrWhiteSpace($OutputExe)) {

    $OutputExe = Join-Path $root "release\app\AutoShutdown.exe"
}

$SourceScript = (Resolve-Path $SourceScript).Path
$IconFile = (Resolve-Path $IconFile).Path
$outputDirectory = Split-Path -Parent $OutputExe

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

if (Test-Path -LiteralPath $OutputExe) {

    Remove-Item -LiteralPath $OutputExe -Force
}

Import-Module ps2exe -ErrorAction Stop

Invoke-ps2exe `
    -inputFile $SourceScript `
    -outputFile $OutputExe `
    -iconFile $IconFile `
    -noConsole `
    -noOutput `
    -STA `
    -DPIAware `
    -supportOS `
    -longPaths `
    -title "Auto Shutdown" `
    -description "Network activity based automatic shutdown utility" `
    -product "Auto Shutdown" `
    -version "1.1.0.0"

Get-Item -LiteralPath $OutputExe
