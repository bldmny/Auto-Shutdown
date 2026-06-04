# ==============================
# AUTO SHUTDOWN GUI v1.1
# WPF front end with external XAML layout
# ==============================

param(
    [switch]$SmokeTest
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("AutoShutdownDwm" -as [type])) {

    try {

        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class AutoShutdownDwm
{
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(
        IntPtr hwnd,
        int dwAttribute,
        ref int pvAttribute,
        int cbAttribute
    );

    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWCP_ROUNDSMALL = 3;
}
"@ -ErrorAction Stop
    }
    catch {
        # Windows 10 and older systems can run without DWM corner preferences.
    }
}

if (-not ("AutoShutdownPower" -as [type])) {

    try {

        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class AutoShutdownPower
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
}
"@ -ErrorAction Stop
    }
    catch {
        # The app can still monitor normally if Windows power requests are unavailable.
    }
}

# Locate the folder containing the script during development
# or the compiled EXE after release.
$appDirectoryCandidates = @()

if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {

    $appDirectoryCandidates += $PSScriptRoot
}

try {

    $commandPath = [Environment]::GetCommandLineArgs()[0]

    if (-not [string]::IsNullOrWhiteSpace($commandPath)) {

        $commandDirectory = Split-Path -Parent -Path $commandPath

        if (-not [string]::IsNullOrWhiteSpace($commandDirectory)) {

            $appDirectoryCandidates += $commandDirectory
        }
    }
}
catch {
}

$appDirectoryCandidates += (Get-Location).Path
$appDirectoryCandidates = @(
    $appDirectoryCandidates |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
)

$AppDirectory = $null

foreach ($candidate in $appDirectoryCandidates) {

    if (
        Test-Path -LiteralPath (
            Join-Path $candidate "NetworkAutoShutdown.xaml"
        )
    ) {

        $AppDirectory = $candidate
        break
    }
}

if ([string]::IsNullOrWhiteSpace($AppDirectory)) {

    $AppDirectory = $appDirectoryCandidates | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($AppDirectory)) {

    $AppDirectory = "."
}

$SettingsFile = Join-Path $AppDirectory "settings.ini"
$XamlFile = Join-Path $AppDirectory "NetworkAutoShutdown.xaml"

$script:SettingsLoadWarning = ""
$script:SettingsReadFailed = $false
$script:SettingsOperationError = ""
$script:ThemeName = "Dark"
$script:MonitoringState = $null
$script:IsClosing = $false
$script:IsPausedForWindowMove = $false
$script:MonitorTimerWasRunningBeforeMove = $false
$script:IdleStatusTimerWasRunningBeforeMove = $false
$script:ShootingStarTimerWasRunningBeforeMove = $false
$script:WindowMoveMessageSource = $null
$script:WindowMoveMessageHook = $null
$script:SleepPreventionActive = $false
$script:notifyIcon = $null
$script:trayMenu = $null
$script:AppIcon = $null

# ==============================
# DEFAULT SETTINGS
# Change defaults here only.
# ==============================

function Get-DefaultSettings {

    return @{
        ThresholdValue = [int64]100
        ThresholdUnit = "KBps"
        ThresholdKBps = [int64]100
        CountdownValue = [int64]60
        CountdownUnit = "Seconds"
        CountdownSeconds = [int64]60
        MonitorTraffic = "Downloads"
        MonitorMode = "All"
        Operation = "Shutdown"
        Theme = "Dark"
    }
}

# ==============================
# SETTINGS HELPERS
# ==============================

function Test-SettingsMatch($firstSettings, $secondSettings) {

    return (
        $firstSettings.ThresholdValue -eq $secondSettings.ThresholdValue -and
        $firstSettings.ThresholdUnit -eq $secondSettings.ThresholdUnit -and
        $firstSettings.ThresholdKBps -eq $secondSettings.ThresholdKBps -and
        $firstSettings.CountdownValue -eq $secondSettings.CountdownValue -and
        $firstSettings.CountdownUnit -eq $secondSettings.CountdownUnit -and
        $firstSettings.CountdownSeconds -eq $secondSettings.CountdownSeconds -and
        $firstSettings.MonitorTraffic -eq $secondSettings.MonitorTraffic -and
        $firstSettings.MonitorMode -eq $secondSettings.MonitorMode -and
        $firstSettings.Operation -eq $secondSettings.Operation -and
        $firstSettings.Theme -eq $secondSettings.Theme
    )
}

function ConvertTo-PositiveInteger($text) {

    if ($null -eq $text) {

        return $null
    }

    $value = [int64]0
    $candidate = $text.ToString().Trim()

    if (
        [int64]::TryParse($candidate, [ref]$value) -and
        $value -gt 0
    ) {
        return $value
    }

    return $null
}

function Get-MonitorModeDisplayName($monitorMode) {

    switch ($monitorMode) {

        "WiFi" { return "Wi-Fi" }
        "Ethernet" { return "Ethernet" }
        default { return "All Interfaces" }
    }
}

function Get-MonitorModeFromDisplayName($displayName) {

    switch ($displayName) {

        "Wi-Fi" { return "WiFi" }
        "Ethernet" { return "Ethernet" }
        default { return "All" }
    }
}

function Get-MonitorTrafficDisplayName($monitorTraffic) {

    switch ($monitorTraffic) {

        "Uploads" { return "Uploads" }
        "Both" { return "Downloads + uploads" }
        default { return "Downloads" }
    }
}

function Get-MonitorTrafficFromDisplayName($displayName) {

    switch ($displayName) {

        "Uploads" { return "Uploads" }
        "Downloads + uploads" { return "Both" }
        default { return "Downloads" }
    }
}

function Get-OperationDisplayName($operation) {

    switch ($operation) {

        "Restart" { return "Restart" }
        "Sleep" { return "Sleep" }
        "Lock" { return "Lock" }
        default { return "Shutdown" }
    }
}

function Get-OperationFromDisplayName($displayName) {

    switch ($displayName) {

        "Restart" { return "Restart" }
        "Sleep" { return "Sleep" }
        "Lock" { return "Lock" }
        default { return "Shutdown" }
    }
}

function Get-OperationPendingText($operation) {

    return ("{0} pending" -f (Get-OperationDisplayName $operation))
}

function Get-OperationRunningText($operation) {

    switch ($operation) {

        "Restart" { return "Restarting" }
        "Sleep" { return "Sleeping" }
        "Lock" { return "Locking" }
        default { return "Shutting down" }
    }
}

function Get-OperationErrorName($operation) {

    return (Get-OperationDisplayName $operation).ToLowerInvariant()
}

function ConvertTo-ThresholdKBps($value, $unit) {

    switch ($unit) {

        "MBps" { return [int64]$value * 1024 }
        "GBps" { return [int64]$value * 1024 * 1024 }
        default { return [int64]$value }
    }
}

function ConvertTo-CountdownSeconds($value, $unit) {

    switch ($unit) {

        "Minutes" { return [int64]$value * 60 }
        "Hours" { return [int64]$value * 60 * 60 }
        default { return [int64]$value }
    }
}

function Get-ThresholdUnitDisplayName($unit) {

    switch ($unit) {

        "MBps" { return "MB/s" }
        "GBps" { return "GB/s" }
        default { return "KB/s" }
    }
}

function Get-ThresholdUnitFromDisplayName($displayName) {

    switch ($displayName) {

        "MB/s" { return "MBps" }
        "GB/s" { return "GBps" }
        default { return "KBps" }
    }
}

function Get-CountdownUnitDisplayName($unit) {

    switch ($unit) {

        "Minutes" { return "minutes" }
        "Hours" { return "hours" }
        default { return "seconds" }
    }
}

function Get-CompactCountdownUnitDisplayName($unit) {

    switch ($unit) {

        "Minutes" { return "min" }
        "Hours" { return "hr" }
        default { return "sec" }
    }
}

function Get-CountdownUnitFromDisplayName($displayName) {

    switch ($displayName) {

        "minutes" { return "Minutes" }
        "hours" { return "Hours" }
        default { return "Seconds" }
    }
}

function Set-ThresholdSetting($settings, $value, $unit) {

    $settings.ThresholdValue = [int64]$value
    $settings.ThresholdUnit = $unit
    $settings.ThresholdKBps = ConvertTo-ThresholdKBps $value $unit
}

function Set-CountdownSetting($settings, $value, $unit) {

    $settings.CountdownValue = [int64]$value
    $settings.CountdownUnit = $unit
    $settings.CountdownSeconds = ConvertTo-CountdownSeconds $value $unit
}

function Get-PositiveInputValue($inputControl, $settingName) {

    $value = ConvertTo-PositiveInteger $inputControl.Text

    if ($null -eq $value) {

        throw "$settingName must be a whole number greater than 0."
    }

    return [int64]$value
}

# ==============================
# SETTINGS LOADING
# ==============================

function Load-Settings {

    $script:SettingsLoadWarning = ""
    $script:SettingsReadFailed = $false

    $settings = Get-DefaultSettings
    $defaults = Get-DefaultSettings

    if (-not (Test-Path -LiteralPath $SettingsFile)) {

        return $settings
    }

    try {

        $lines = @(Get-Content -LiteralPath $SettingsFile -ErrorAction Stop)
    }
    catch {

        $script:SettingsReadFailed = $true
        $script:SettingsLoadWarning =
            "Unable to read settings.ini. Monitoring is unavailable until the settings file can be accessed."

        return $settings
    }

    $hasUnknownOrInvalidSettings = $false

    foreach ($line in $lines) {

        $trimmedLine = $line.Trim()

        if (
            [string]::IsNullOrWhiteSpace($trimmedLine) -or
            $trimmedLine.StartsWith("#") -or
            $trimmedLine.StartsWith(";")
        ) {
            continue
        }

        if ($trimmedLine -notmatch "=") {

            $hasUnknownOrInvalidSettings = $true
            continue
        }

        $parts = $trimmedLine.Split("=", 2)

        if ($parts.Count -ne 2) {

            $hasUnknownOrInvalidSettings = $true
            continue
        }

        $key = $parts[0].Trim()
        $rawValue = $parts[1].Trim()

        switch ($key) {

            "ThresholdKBps" {

                $value = ConvertTo-PositiveInteger $rawValue

                if ($null -ne $value) {

                    Set-ThresholdSetting $settings $value "KBps"
                }
                else {

                    $hasUnknownOrInvalidSettings = $true
                }
            }

            "ThresholdValue" {

                $value = ConvertTo-PositiveInteger $rawValue

                if ($null -ne $value) {

                    Set-ThresholdSetting $settings $value $settings.ThresholdUnit
                }
                else {

                    $hasUnknownOrInvalidSettings = $true
                }
            }

            "ThresholdUnit" {

                switch ($rawValue.ToLowerInvariant()) {

                    "kbps" { Set-ThresholdSetting $settings $settings.ThresholdValue "KBps" }
                    "mbps" { Set-ThresholdSetting $settings $settings.ThresholdValue "MBps" }
                    "gbps" { Set-ThresholdSetting $settings $settings.ThresholdValue "GBps" }
                    default { $hasUnknownOrInvalidSettings = $true }
                }
            }

            "CountdownSeconds" {

                $value = ConvertTo-PositiveInteger $rawValue

                if ($null -ne $value) {

                    Set-CountdownSetting $settings $value "Seconds"
                }
                else {

                    $hasUnknownOrInvalidSettings = $true
                }
            }

            "CountdownValue" {

                $value = ConvertTo-PositiveInteger $rawValue

                if ($null -ne $value) {

                    Set-CountdownSetting $settings $value $settings.CountdownUnit
                }
                else {

                    $hasUnknownOrInvalidSettings = $true
                }
            }

            "CountdownUnit" {

                switch ($rawValue.ToLowerInvariant()) {

                    "seconds" { Set-CountdownSetting $settings $settings.CountdownValue "Seconds" }
                    "minutes" { Set-CountdownSetting $settings $settings.CountdownValue "Minutes" }
                    "hours" { Set-CountdownSetting $settings $settings.CountdownValue "Hours" }
                    default { $hasUnknownOrInvalidSettings = $true }
                }
            }

            { $_ -in @("Monitor", "ActivityMode") } {

                switch ($rawValue.ToLowerInvariant()) {

                    "downloads" { $settings.MonitorTraffic = "Downloads" }
                    "download" { $settings.MonitorTraffic = "Downloads" }
                    "uploads" { $settings.MonitorTraffic = "Uploads" }
                    "upload" { $settings.MonitorTraffic = "Uploads" }
                    "both" { $settings.MonitorTraffic = "Both" }
                    default { $hasUnknownOrInvalidSettings = $true }
                }
            }

            "Operation" {

                switch ($rawValue.ToLowerInvariant()) {

                    "shutdown" { $settings.Operation = "Shutdown" }
                    "restart" { $settings.Operation = "Restart" }
                    "sleep" { $settings.Operation = "Sleep" }
                    "lock" { $settings.Operation = "Lock" }
                    default { $hasUnknownOrInvalidSettings = $true }
                }
            }

            "Theme" {

                switch ($rawValue.ToLowerInvariant()) {

                    "dark" { $settings.Theme = "Dark" }
                    "light" { $settings.Theme = "Light" }
                    default { $hasUnknownOrInvalidSettings = $true }
                }
            }

            "MonitorMode" {

                switch ($rawValue.ToLowerInvariant()) {

                    "all" { $settings.MonitorMode = "All" }
                    "wifi" { $settings.MonitorMode = "WiFi" }
                    "ethernet" { $settings.MonitorMode = "Ethernet" }
                    default { $hasUnknownOrInvalidSettings = $true }
                }
            }

            default {

                $hasUnknownOrInvalidSettings = $true
            }
        }
    }

    if ($hasUnknownOrInvalidSettings) {

        $script:SettingsLoadWarning =
            "Some settings.ini entries could not be read and were ignored."
    }

    if (
        -not $hasUnknownOrInvalidSettings -and
        (Test-SettingsMatch $settings $defaults)
    ) {
        try {

            Remove-Item -LiteralPath $SettingsFile -Force -ErrorAction Stop
        }
        catch {

            $script:SettingsLoadWarning =
                "Default settings are active, but settings.ini could not be removed."
        }
    }

    return $settings
}

# ==============================
# ATOMIC SETTINGS SAVING
# ==============================

function Save-Settings($settings) {

    $script:SettingsOperationError = ""

    $defaults = Get-DefaultSettings
    $lines = @()

    if (
        $settings.ThresholdValue -ne $defaults.ThresholdValue -or
        $settings.ThresholdUnit -ne $defaults.ThresholdUnit
    ) {

        $lines += "ThresholdValue=$($settings.ThresholdValue)"
        $lines += "ThresholdUnit=$($settings.ThresholdUnit)"
    }

    if (
        $settings.CountdownValue -ne $defaults.CountdownValue -or
        $settings.CountdownUnit -ne $defaults.CountdownUnit
    ) {

        $lines += "CountdownValue=$($settings.CountdownValue)"
        $lines += "CountdownUnit=$($settings.CountdownUnit)"
    }

    if ($settings.MonitorMode -ne $defaults.MonitorMode) {

        $lines += "MonitorMode=$($settings.MonitorMode)"
    }

    if ($settings.MonitorTraffic -ne $defaults.MonitorTraffic) {

        $lines += "Monitor=$($settings.MonitorTraffic)"
    }

    if ($settings.Operation -ne $defaults.Operation) {

        $lines += "Operation=$($settings.Operation)"
    }

    if ($settings.Theme -ne $defaults.Theme) {

        $lines += "Theme=$($settings.Theme)"
    }

    if ($lines.Count -eq 0) {

        if (-not (Test-Path -LiteralPath $SettingsFile)) {

            return $true
        }

        try {

            Remove-Item -LiteralPath $SettingsFile -Force -ErrorAction Stop
            return $true
        }
        catch {

            $script:SettingsOperationError =
                "Unable to update settings. settings.ini could not be removed."

            return $false
        }
    }

    $identifier = [guid]::NewGuid().ToString("N")
    $temporaryFile = Join-Path $AppDirectory ("settings.{0}.tmp" -f $identifier)
    $backupFile = Join-Path $AppDirectory ("settings.{0}.bak" -f $identifier)
    $settingsFilePreviouslyExisted = Test-Path -LiteralPath $SettingsFile
    $backupCreated = $false

    try {

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        [System.IO.File]::WriteAllLines(
            $temporaryFile,
            [string[]]$lines,
            $utf8NoBom
        )

        $writtenLines = @(Get-Content -LiteralPath $temporaryFile -ErrorAction Stop)

        if (
            ($writtenLines.Count -ne $lines.Count) -or
            (($writtenLines -join "`n") -ne ($lines -join "`n"))
        ) {
            throw "Temporary settings file verification failed."
        }

        if ($settingsFilePreviouslyExisted) {

            Copy-Item `
                -LiteralPath $SettingsFile `
                -Destination $backupFile `
                -Force `
                -ErrorAction Stop

            $backupCreated = $true
        }

        Copy-Item `
            -LiteralPath $temporaryFile `
            -Destination $SettingsFile `
            -Force `
            -ErrorAction Stop

        $finalLines = @(Get-Content -LiteralPath $SettingsFile -ErrorAction Stop)

        if (
            ($finalLines.Count -ne $lines.Count) -or
            (($finalLines -join "`n") -ne ($lines -join "`n"))
        ) {
            throw "Final settings file verification failed."
        }

        Remove-Item `
            -LiteralPath $temporaryFile `
            -Force `
            -ErrorAction SilentlyContinue

        if ($backupCreated) {

            Remove-Item `
                -LiteralPath $backupFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        return $true
    }
    catch {

        $restoreFailed = $false

        if ($backupCreated -and (Test-Path -LiteralPath $backupFile)) {

            try {

                Copy-Item `
                    -LiteralPath $backupFile `
                    -Destination $SettingsFile `
                    -Force `
                    -ErrorAction Stop
            }
            catch {

                $restoreFailed = $true
            }
        }
        elseif (
            -not $settingsFilePreviouslyExisted -and
            (Test-Path -LiteralPath $SettingsFile)
        ) {

            Remove-Item `
                -LiteralPath $SettingsFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        foreach ($cleanupFile in @($temporaryFile, $backupFile)) {

            if (Test-Path -LiteralPath $cleanupFile) {

                Remove-Item `
                    -LiteralPath $cleanupFile `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }

        if ($restoreFailed) {

            $script:SettingsOperationError =
                "Unable to save settings. The previous settings file could not be restored."
        }
        else {

            $script:SettingsOperationError =
                "Unable to save settings. Your previous settings have not been changed."
        }

        return $false
    }
}

function Reset-Settings {

    $script:SettingsOperationError = ""

    if (-not (Test-Path -LiteralPath $SettingsFile)) {

        return $true
    }

    try {

        Remove-Item -LiteralPath $SettingsFile -Force -ErrorAction Stop
        return $true
    }
    catch {

        $script:SettingsOperationError =
            "Unable to reset settings. settings.ini could not be removed. Close any app using the file, delete settings.ini manually, or run this app as administrator if the folder is protected."

        return $false
    }
}

function Save-ThemePreference {

    $settings = Load-Settings
    $settings.Theme = $script:ThemeName

    return Save-Settings $settings
}

# ==============================
# INTERFACE DETECTION
# ==============================

function Test-AdapterMatchesMonitorMode($adapter, $monitorMode) {

    $adapterText = @(
        $adapter.Name
        $adapter.InterfaceDescription
        $adapter.Description
        $adapter.MediaType
        $adapter.PhysicalMediaType
        $adapter.NdisPhysicalMedium
        $adapter.NetworkInterfaceType
    ) -join " "

    $interfaceType = "$($adapter.NetworkInterfaceType)"

    switch ($monitorMode) {

        "WiFi" {

            return (
                $interfaceType -eq "Wireless80211" -or
                $adapterText -match '(?i)wi-?fi|wireless|wlan|802\.11|native\s+802\.11'
            )
        }

        "Ethernet" {

            return (
                $interfaceType -in @(
                    "Ethernet",
                    "GigabitEthernet",
                    "FastEthernetFx",
                    "FastEthernetT"
                ) -or
                $adapterText -match '(?i)ethernet|802\.3|gigabit|gbit|gbe|fast\s+ethernet'
            )
        }

        default {

            return $true
        }
    }
}

function Get-SelectedAdapterResult($monitorMode) {

    try {

        $ignoredTypes = @(
            "Loopback",
            "Tunnel",
            "Unknown"
        )

        $matchingAdapters = @(
            [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object {
                $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
                "$($_.NetworkInterfaceType)" -notin $ignoredTypes -and
                (Test-AdapterMatchesMonitorMode $_ $monitorMode)
            }
        )
    }
    catch {

        return [PSCustomObject]@{
            Status = "AdapterDataUnavailable"
            Adapters = @()
        }
    }

    if ($matchingAdapters.Count -eq 0) {

        return [PSCustomObject]@{
            Status = "NoMatchingInterface"
            Adapters = @()
        }
    }

    return [PSCustomObject]@{
        Status = "OK"
        Adapters = $matchingAdapters
    }
}

# ==============================
# INTERNET CONNECTION CHECK
# ==============================

function Get-InternetConnectionResult($adapterResult) {

    try {

        $networkAvailable =
            [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    }
    catch {

        return [PSCustomObject]@{
            Status = "ConnectionDataUnavailable"
        }
    }

    if (-not $networkAvailable) {

        return [PSCustomObject]@{
            Status = "NoInternet"
        }
    }

    if ($adapterResult.Status -ne "OK") {

        return [PSCustomObject]@{
            Status = $adapterResult.Status
        }
    }

    if ($adapterResult.Adapters.Count -gt 0) {

        return [PSCustomObject]@{
            Status = "Online"
        }
    }

    return [PSCustomObject]@{
        Status = "NoInternet"
    }
}

# ==============================
# NETWORK SPEED MONITORING
# ==============================

function Get-NetworkSpeedResult($monitorTraffic, $adapterResult) {

    try {

        if ($adapterResult.Status -ne "OK") {

            return [PSCustomObject]@{
                Status = $adapterResult.Status
                SpeedKBps = $null
            }
        }

        $now = [DateTime]::UtcNow
        $totalBytes = [int64]0
        $hasUsableStats = $false

        foreach ($adapter in $adapterResult.Adapters) {

            try {

                $stats = $adapter.GetIPv4Statistics()

                switch ($monitorTraffic) {

                    "Uploads" {
                        $totalBytes += [int64]$stats.BytesSent
                    }

                    "Both" {
                        $totalBytes += [int64]$stats.BytesReceived
                        $totalBytes += [int64]$stats.BytesSent
                    }

                    default {
                        $totalBytes += [int64]$stats.BytesReceived
                    }
                }

                $hasUsableStats = $true
            }
            catch {
                # Ignore adapters that cannot expose byte counters.
            }
        }

        if (-not $hasUsableStats) {

            return [PSCustomObject]@{
                Status = "CounterUnavailable"
                SpeedKBps = $null
            }
        }

        if ($null -eq $script:MonitoringState.LastNetworkSnapshot) {

            $script:MonitoringState.LastNetworkSnapshot = @{
                Timestamp = $now
                TotalBytes = $totalBytes
            }

            return [PSCustomObject]@{
                Status = "Sampling"
                SpeedKBps = $null
            }
        }

        $previousSnapshot = $script:MonitoringState.LastNetworkSnapshot
        $elapsedSeconds = ($now - $previousSnapshot.Timestamp).TotalSeconds
        $byteDelta = $totalBytes - [int64]$previousSnapshot.TotalBytes

        $script:MonitoringState.LastNetworkSnapshot = @{
            Timestamp = $now
            TotalBytes = $totalBytes
        }

        if ($elapsedSeconds -le 0 -or $byteDelta -lt 0) {

            return [PSCustomObject]@{
                Status = "Sampling"
                SpeedKBps = $null
            }
        }

        $bytesPerSecond = $byteDelta / $elapsedSeconds

        return [PSCustomObject]@{
            Status = "OK"
            SpeedKBps = [math]::Round(($bytesPerSecond / 1024), 2)
        }
    }
    catch {

        return [PSCustomObject]@{
            Status = "CounterUnavailable"
            SpeedKBps = $null
        }
    }
}

function Format-Speed($speedKB) {

    if ($speedKB -ge 1024) {

        return "{0:N2} MB/s" -f ($speedKB / 1024)
    }

    return "{0:N2} KB/s" -f $speedKB
}

# ==============================
# OPERATION HELPERS
# ==============================

function Invoke-HiddenProcess($fileName, $arguments) {

    try {

        $process =
            Start-Process `
                -FilePath $fileName `
                -ArgumentList $arguments `
                -WindowStyle Hidden `
                -Wait `
                -PassThru `
                -ErrorAction Stop

        if ($null -eq $process.ExitCode) {

            return 0
        }

        return $process.ExitCode
    }
    catch {

        return 1
    }
}

function Invoke-ConfiguredOperation($operation) {

    switch ($operation) {

        "Restart" {

            return Invoke-HiddenProcess `
                "shutdown.exe" `
                '/r /t 0 /c "Low network activity detected."'
        }

        "Sleep" {

            return Invoke-HiddenProcess `
                "rundll32.exe" `
                "powrprof.dll,SetSuspendState 0,1,0"
        }

        "Lock" {

            return Invoke-HiddenProcess `
                "rundll32.exe" `
                "user32.dll,LockWorkStation"
        }

        default {

            return Invoke-HiddenProcess `
                "shutdown.exe" `
                '/s /t 0 /c "Low network activity detected."'
        }
    }
}

function Enable-SleepPrevention {

    if (
        $script:SleepPreventionActive -or
        -not ("AutoShutdownPower" -as [type])
    ) {
        return
    }

    try {

        $flags =
            [uint32](
                [AutoShutdownPower]::ES_CONTINUOUS -bor
                [AutoShutdownPower]::ES_SYSTEM_REQUIRED
            )

        $result = [AutoShutdownPower]::SetThreadExecutionState($flags)

        if ($result -ne 0) {

            $script:SleepPreventionActive = $true
        }
    }
    catch {
        $script:SleepPreventionActive = $false
    }
}

function Disable-SleepPrevention {

    if (
        -not $script:SleepPreventionActive -or
        -not ("AutoShutdownPower" -as [type])
    ) {
        return
    }

    try {

        [void][AutoShutdownPower]::SetThreadExecutionState(
            [AutoShutdownPower]::ES_CONTINUOUS
        )
    }
    catch {
    }

    $script:SleepPreventionActive = $false
}

# ==============================
# WPF HELPERS
# ==============================

function Show-StartupError($message) {

    [void][System.Windows.MessageBox]::Show(
        $message,
        "Auto Shutdown",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
}

function Get-ApplicationIcon {

    $iconFile = Join-Path $AppDirectory "AutoShutdown.ico"

    if (Test-Path -LiteralPath $iconFile) {

        try {

            $stream = [System.IO.File]::OpenRead($iconFile)

            try {

                $icon = [System.Drawing.Icon]::new($stream)
                return $icon.Clone()
            }
            finally {

                $stream.Dispose()
            }
        }
        catch {
        }
    }

    try {

        $commandPath = [Environment]::GetCommandLineArgs()[0]

        if (Test-Path -LiteralPath $commandPath) {

            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($commandPath)

            if ($null -ne $icon) {

                return $icon
            }
        }
    }
    catch {
    }

    return [System.Drawing.SystemIcons]::Application
}

function Convert-IconToImageSource($icon) {

    return [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
        $icon.Handle,
        [System.Windows.Int32Rect]::Empty,
        [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
    )
}

function Dispose-TrayResources {

    if ($null -ne $script:notifyIcon) {

        try {

            $script:notifyIcon.Visible = $false
            $script:notifyIcon.ContextMenuStrip = $null
            $script:notifyIcon.Dispose()
        }
        catch {
        }

        $script:notifyIcon = $null
    }

    if ($null -ne $script:trayMenu) {

        try {

            $script:trayMenu.Dispose()
        }
        catch {
        }

        $script:trayMenu = $null
    }
}

function Enable-Windows11RoundedCorners($targetWindow) {

    try {

        if (
            -not ("AutoShutdownDwm" -as [type]) -or
            [Environment]::OSVersion.Version.Build -lt 22000
        ) {
            return
        }

        $handle =
            [System.Windows.Interop.WindowInteropHelper]::new(
                $targetWindow
            ).Handle

        if ($handle -eq [IntPtr]::Zero) {

            return
        }

        $cornerPreference = [AutoShutdownDwm]::DWMWCP_ROUNDSMALL

        [void][AutoShutdownDwm]::DwmSetWindowAttribute(
            $handle,
            [AutoShutdownDwm]::DWMWA_WINDOW_CORNER_PREFERENCE,
            [ref]$cornerPreference,
            4
        )
    }
    catch {
        # Rounded corners are cosmetic; failure should never block the app.
    }
}

function New-WpfBrush($hexColor) {

    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($hexColor)

    return [System.Windows.Media.SolidColorBrush]::new($color)
}

function Add-GradientStops($brush, [object[]]$hexColors) {

    $brush.GradientStops.Clear()
    $lastIndex = $hexColors.Count - 1

    for ($index = 0; $index -lt $hexColors.Count; $index++) {

        $offset = 0

        if ($lastIndex -gt 0) {

            $offset = $index / $lastIndex
        }

        $color =
            [System.Windows.Media.ColorConverter]::ConvertFromString(
                $hexColors[$index]
            )

        [void]$brush.GradientStops.Add(
            [System.Windows.Media.GradientStop]::new($color, $offset)
        )
    }
}

function New-WpfGradientBrush([object[]]$hexColors) {

    $brush = [System.Windows.Media.LinearGradientBrush]::new()
    $brush.StartPoint = [System.Windows.Point]::new(0, 0)
    $brush.EndPoint = [System.Windows.Point]::new(1, 1)
    Add-GradientStops $brush $hexColors

    return $brush
}

function Get-ResourceObject($key) {

    $resource = $window.Resources.Item($key)

    if ($null -eq $resource) {

        return $null
    }

    return $resource.PSObject.BaseObject
}

function Set-ResourceGradientBrush($key, [object[]]$hexColors) {

    $brush = Get-ResourceObject $key

    if (
        $brush -is [System.Windows.Media.LinearGradientBrush] -and
        -not $brush.IsFrozen
    ) {

        $brush.StartPoint = [System.Windows.Point]::new(0, 0)
        $brush.EndPoint = [System.Windows.Point]::new(1, 1)
        Add-GradientStops $brush $hexColors

        return
    }

    $replacementBrush =
        New-WpfGradientBrush $hexColors

    if ($window.Resources.Contains($key)) {

        $window.Resources.Remove($key)
    }

    $window.Resources.Add($key, $replacementBrush)
}

function Set-ResourceBrush($key, $hexColor) {

    if (
        $hexColor -is [System.Array] -and
        $hexColor.Count -ge 2
    ) {

        Set-ResourceGradientBrush $key ([object[]]$hexColor)
        return
    }

    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($hexColor)
    $brush = Get-ResourceObject $key

    if (
        $brush -is [System.Windows.Media.SolidColorBrush] -and
        -not $brush.IsFrozen
    ) {

        $brush.Color = $color
        return
    }

    $replacementBrush = New-WpfBrush $hexColor

    if ($window.Resources.Contains($key)) {

        $window.Resources.Remove($key)
    }

    $window.Resources.Add($key, $replacementBrush)
}

function Get-ResourceBrush($key) {

    $brush = Get-ResourceObject $key

    if ($brush -isnot [System.Windows.Media.Brush]) {

        throw "Theme resource '$key' is not a WPF brush."
    }

    return [System.Windows.Media.Brush]$brush
}

function Test-ThemeResources {

    foreach ($key in $script:ThemeColors.Keys) {

        $brush = Get-ResourceObject $key

        if ($brush -isnot [System.Windows.Media.Brush]) {

            throw "Theme resource '$key' is '$($brush.GetType().FullName)', not a WPF brush."
        }
    }
}

function Set-ThemePalette($themeName) {

    if ($themeName -eq "Dark") {

        $script:ThemeColors = @{
            PageBackground = @("#08101F", "#1D355C")
            PanelBackground = "#1E293B"
            PanelBorder = "#334155"
            Text = "#E2E8F0"
            MutedText = "#94A3B8"
            SecondaryBackground = "#1E293B"
            SecondaryHover = "#26364E"
            SecondaryBorder = "#475569"
            ButtonText = "#E2E8F0"
            InputBackground = "#1E293B"
            InputText = "#E2E8F0"
            InputBorder = "#CBD5E1"
            AlertText = "#F87171"
            StatusNeutral = "#94A3B8"
            StatusSuccess = "#4ADE80"
            StatusWarning = "#FBBF24"
            StatusDanger = "#F87171"
            DangerBackground = "#B91C1C"
            DangerHover = "#991B1B"
            DangerBorder = "#991B1B"
            TitleButtonHover = "#1E293B"
            CloseButtonHover = "#B91C1C"
            IconForeground = "#E2E8F0"
        }
    }
    else {

        $script:ThemeColors = @{
            PageBackground = @("#BFE3FF", "#FFF3D6")
            PanelBackground = "#FFFFFF"
            PanelBorder = "#E2E8F0"
            Text = "#0F172A"
            MutedText = "#64748B"
            SecondaryBackground = "#FFFFFF"
            SecondaryHover = "#F1F5F9"
            SecondaryBorder = "#CBD5E1"
            ButtonText = "#1E293B"
            InputBackground = "#FFFFFF"
            InputText = "#0F172A"
            InputBorder = "#AAB6C7"
            AlertText = "#B91C1C"
            StatusNeutral = "#475569"
            StatusSuccess = "#228B22"
            StatusWarning = "#B7791F"
            StatusDanger = "#B91C1C"
            DangerBackground = "#B91C1C"
            DangerHover = "#991B1B"
            DangerBorder = "#991B1B"
            TitleButtonHover = "#E2E8F0"
            CloseButtonHover = "#B91C1C"
            IconForeground = "#0F172A"
        }
    }
}

function Apply-Theme($themeName) {

    if ($themeName -ne "Dark") {

        $themeName = "Light"
    }

    $script:ThemeName = $themeName
    Set-ThemePalette $script:ThemeName

    foreach ($key in $script:ThemeColors.Keys) {

        Set-ResourceBrush $key $script:ThemeColors[$key]
    }

    Test-ThemeResources

    if ($script:ThemeName -eq "Dark") {

        $MoonIcon.Visibility = [System.Windows.Visibility]::Visible
        $SunIcon.Visibility = [System.Windows.Visibility]::Collapsed
        $ThemeToggleButton.ToolTip = "Switch to light mode"

        if ($null -ne $StarLayer) {

            $StarLayer.Visibility = [System.Windows.Visibility]::Visible
        }
    }
    else {

        $MoonIcon.Visibility = [System.Windows.Visibility]::Collapsed
        $SunIcon.Visibility = [System.Windows.Visibility]::Visible
        $ThemeToggleButton.ToolTip = "Switch to dark mode"

        if ($null -ne $StarLayer) {

            $StarLayer.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }

    if ($null -ne $StatusValueText) {

        $StatusValueText.Foreground =
            Get-StatusBrushForText $StatusValueText.Text
    }

    Update-Buttons
}

function Get-StatusBrushForText($statusText) {

    if (
        $statusText -match "pending|Shutting down|Restarting|Sleeping|Locking|error|Unable"
    ) {
        return Get-ResourceBrush "StatusDanger"
    }

    if ($statusText -match "Monitoring") {

        return Get-ResourceBrush "StatusSuccess"
    }

    if (
        $statusText -match "Calibrating|Waiting|Unavailable|No active"
    ) {
        return Get-ResourceBrush "StatusWarning"
    }

    return Get-ResourceBrush "StatusNeutral"
}

function Set-ButtonVisual($button, $backgroundKey, $foregroundKey, $borderKey) {

    $button.Background = Get-ResourceBrush $backgroundKey
    $button.Foreground = Get-ResourceBrush $foregroundKey
    $button.BorderBrush = Get-ResourceBrush $borderKey
}

function Set-ComboItems($comboBox, [string[]]$items) {

    $comboBox.Items.Clear()

    foreach ($item in $items) {

        [void]$comboBox.Items.Add($item)
    }
}

function Set-ComboValue($comboBox, $value) {

    if ($comboBox.Items.Contains($value)) {

        $comboBox.SelectedItem = $value
    }
    else {

        $comboBox.SelectedIndex = 0
    }
}

function Get-ComboValue($comboBox) {

    if ($null -ne $comboBox.SelectedItem) {

        return $comboBox.SelectedItem.ToString()
    }

    return $comboBox.Text
}

function Set-InputsEnabled($enabled) {

    foreach ($control in @(
        $ThresholdBox,
        $ThresholdUnitBox,
        $DelayBox,
        $DelayUnitBox,
        $MonitorBox,
        $OperationBox,
        $NetworkBox,
        $SaveButton,
        $ResetButton
    )) {

        $control.IsEnabled = $enabled
    }
}

function Set-AlertMessage($message) {

    $AlertText.Text = $message

    if ([string]::IsNullOrWhiteSpace($message)) {

        $AlertText.Visibility = [System.Windows.Visibility]::Collapsed
    }
    else {

        $AlertText.Visibility = [System.Windows.Visibility]::Visible
    }
}

function Set-StatusMessage($message, $brush) {

    $StatusValueText.Text = $message
    $StatusValueText.Foreground = $brush
}

function Set-IdleStatus {

    $SpeedValueText.Text = "Not monitoring"
    $CountdownValueText.Text = "None"
    Set-StatusMessage "Idle" (Get-ResourceBrush "StatusNeutral")
}

function Set-TemporaryIdleStatus($message) {

    $idleStatusTimer.Stop()
    $SpeedValueText.Text = "Not monitoring"
    $CountdownValueText.Text = "None"
    Set-StatusMessage $message (Get-ResourceBrush "StatusNeutral")
    $idleStatusTimer.Start()
}

function Get-SettingsFromControls {

    $thresholdValue = Get-PositiveInputValue $ThresholdBox "Threshold"
    $thresholdUnit =
        Get-ThresholdUnitFromDisplayName (Get-ComboValue $ThresholdUnitBox)

    $countdownValue = Get-PositiveInputValue $DelayBox "Operation delay"
    $countdownUnit =
        Get-CountdownUnitFromDisplayName (Get-ComboValue $DelayUnitBox)

    return @{
        ThresholdValue = $thresholdValue
        ThresholdUnit = $thresholdUnit
        ThresholdKBps = ConvertTo-ThresholdKBps $thresholdValue $thresholdUnit
        CountdownValue = $countdownValue
        CountdownUnit = $countdownUnit
        CountdownSeconds = ConvertTo-CountdownSeconds $countdownValue $countdownUnit
        MonitorTraffic = Get-MonitorTrafficFromDisplayName (Get-ComboValue $MonitorBox)
        MonitorMode = Get-MonitorModeFromDisplayName (Get-ComboValue $NetworkBox)
        Operation = Get-OperationFromDisplayName (Get-ComboValue $OperationBox)
        Theme = $script:ThemeName
    }
}

function Set-ControlsFromSettings($settings) {

    $ThresholdBox.Text = [string]$settings.ThresholdValue
    Set-ComboValue $ThresholdUnitBox (Get-ThresholdUnitDisplayName $settings.ThresholdUnit)

    $DelayBox.Text = [string]$settings.CountdownValue
    Set-ComboValue $DelayUnitBox (Get-CountdownUnitDisplayName $settings.CountdownUnit)

    Set-ComboValue $MonitorBox (Get-MonitorTrafficDisplayName $settings.MonitorTraffic)
    Set-ComboValue $OperationBox (Get-OperationDisplayName $settings.Operation)
    Set-ComboValue $NetworkBox (Get-MonitorModeDisplayName $settings.MonitorMode)

    $script:ThemeName = $settings.Theme
}

function Update-CurrentSettingsLabel {

    try {

        $settings = Get-SettingsFromControls
    }
    catch {

        $CurrentSettingsText.Text = "Settings need attention"
        return
    }

    $networkName = Get-MonitorModeDisplayName $settings.MonitorMode
    $monitorTrafficName = Get-MonitorTrafficDisplayName $settings.MonitorTraffic
    $thresholdUnitName = Get-ThresholdUnitDisplayName $settings.ThresholdUnit
    $countdownUnitName = Get-CompactCountdownUnitDisplayName $settings.CountdownUnit
    $operationName = Get-OperationDisplayName $settings.Operation

    $CurrentSettingsText.Text =
        "$operationName | $monitorTrafficName | $($settings.ThresholdValue) $thresholdUnitName | $($settings.CountdownValue) $countdownUnitName | $networkName"
}

function Update-Buttons {

    if ($null -eq $StartButton) {

        return
    }

    if ($script:MonitoringState.IsMonitoring) {

        $StartButton.Content = "Stop"
        $StartButton.IsEnabled = $true
        Set-ButtonVisual $StartButton "DangerBackground" "ButtonText" "DangerBorder"

        $SettingsButton.IsEnabled = $false
        $startTrayItem.Text = "Stop Monitoring"
    }
    else {

        $StartButton.Content = "Start Monitoring"
        $StartButton.IsEnabled = (-not $script:SettingsReadFailed)
        Set-ButtonVisual $StartButton "SecondaryBackground" "ButtonText" "SecondaryBorder"

        $SettingsButton.IsEnabled = $true
        $startTrayItem.Text = "Start Monitoring"
    }
}

function Refresh-SettingsDisplay($settings) {

    if ($null -eq $settings) {

        $settings = Load-Settings
    }

    Set-ControlsFromSettings $settings
    Apply-Theme $settings.Theme
    Update-CurrentSettingsLabel

    if ($script:SettingsReadFailed) {

        Set-AlertMessage $script:SettingsLoadWarning
        Set-InputsEnabled $false
        $ResetButton.IsEnabled = $true
    }
    else {

        Set-AlertMessage $script:SettingsLoadWarning
        Set-InputsEnabled (-not $script:MonitoringState.IsMonitoring)
    }

    Update-Buttons
}

function Show-MainView {

    $SettingsView.Visibility = [System.Windows.Visibility]::Collapsed
    $MainView.Visibility = [System.Windows.Visibility]::Visible
    Update-CurrentSettingsLabel
    Update-Buttons
}

function Show-SettingsView {

    Refresh-SettingsDisplay
    $MainView.Visibility = [System.Windows.Visibility]::Collapsed
    $SettingsView.Visibility = [System.Windows.Visibility]::Visible
}

function Show-AppWindow {

    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {

        $window.WindowState = [System.Windows.WindowState]::Normal
    }

    $window.Show()
    $window.Activate()
}

function Get-VisualOrLogicalParent($element) {

    if ($null -eq $element) {

        return $null
    }

    if ($element -is [System.Windows.DependencyObject]) {

        try {

            $visualParent = [System.Windows.Media.VisualTreeHelper]::GetParent($element)

            if ($null -ne $visualParent) {

                return $visualParent
            }
        }
        catch {
        }
    }

    if ($element -is [System.Windows.FrameworkElement]) {

        return $element.Parent
    }

    if ($element -is [System.Windows.FrameworkContentElement]) {

        return $element.Parent
    }

    return $null
}

function Test-IsElementOrDescendantOf($element, $ancestor) {

    $current = $element

    while ($null -ne $current) {

        if ([object]::ReferenceEquals($current, $ancestor)) {

            return $true
        }

        $current = Get-VisualOrLogicalParent $current
    }

    return $false
}

function Test-IsWindowDragBlocked($element) {

    $current = $element

    while ($null -ne $current) {

        if (
            $current -is [System.Windows.Controls.Button] -or
            $current -is [System.Windows.Controls.TextBox] -or
            $current -is [System.Windows.Controls.ComboBox] -or
            [object]::ReferenceEquals($current, $MainStatusPanel) -or
            [object]::ReferenceEquals($current, $SettingsPanel)
        ) {
            return $true
        }

        $current = Get-VisualOrLogicalParent $current
    }

    return $false
}

function Start-BackgroundWindowDrag($eventArgs) {

    if (
        $eventArgs.ChangedButton -ne [System.Windows.Input.MouseButton]::Left
    ) {
        return
    }

    $source = $eventArgs.OriginalSource.PSObject.BaseObject

    if (
        -not (Test-IsElementOrDescendantOf $source $ContentSurface) -or
        (Test-IsWindowDragBlocked $source)
    ) {

        return
    }

    try {

        $eventArgs.Handled = $true
        Suspend-TimersForWindowMove
        $window.DragMove()
    }
    catch {
        # DragMove can throw if the mouse is released during startup of the drag.
    }
    finally {

        Resume-TimersAfterWindowMove
    }
}

function Suspend-TimersForWindowMove {

    if ($script:IsPausedForWindowMove) {

        return
    }

    $script:IsPausedForWindowMove = $true
    $script:MonitorTimerWasRunningBeforeMove =
        ($null -ne $monitorTimer -and $monitorTimer.IsEnabled)
    $script:IdleStatusTimerWasRunningBeforeMove =
        ($null -ne $idleStatusTimer -and $idleStatusTimer.IsEnabled)
    $script:ShootingStarTimerWasRunningBeforeMove =
        ($null -ne $shootingStarTimer -and $shootingStarTimer.IsEnabled)

    if ($script:MonitorTimerWasRunningBeforeMove) {

        $monitorTimer.Stop()
    }

    if ($script:IdleStatusTimerWasRunningBeforeMove) {

        $idleStatusTimer.Stop()
    }

    if ($script:ShootingStarTimerWasRunningBeforeMove) {

        $shootingStarTimer.Stop()
    }
}

function Resume-TimersAfterWindowMove {

    if (
        -not $script:IsPausedForWindowMove -or
        $script:IsClosing
    ) {
        return
    }

    $script:IsPausedForWindowMove = $false

    if (
        $script:MonitorTimerWasRunningBeforeMove -and
        $null -ne $script:MonitoringState -and
        $script:MonitoringState.IsMonitoring
    ) {

        $monitorTimer.Start()
    }

    if ($script:IdleStatusTimerWasRunningBeforeMove) {

        $idleStatusTimer.Start()
    }

    if ($script:ShootingStarTimerWasRunningBeforeMove) {

        $shootingStarTimer.Start()
    }

    $script:MonitorTimerWasRunningBeforeMove = $false
    $script:IdleStatusTimerWasRunningBeforeMove = $false
    $script:ShootingStarTimerWasRunningBeforeMove = $false
}

function Add-WindowMoveMessageHook {

    try {

        if (
            $null -ne $script:WindowMoveMessageSource -and
            $null -ne $script:WindowMoveMessageHook
        ) {
            return
        }

        $helper =
            [System.Windows.Interop.WindowInteropHelper]::new($window)
        $source =
            [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)

        if ($null -eq $source) {

            return
        }

        $script:WindowMoveMessageHook =
            [System.Windows.Interop.HwndSourceHook]{

                param(
                    [IntPtr]$hwnd,
                    [int]$msg,
                    [IntPtr]$wParam,
                    [IntPtr]$lParam,
                    [ref]$handled
                )

                switch ($msg) {

                    0x0231 {
                        Suspend-TimersForWindowMove
                    }

                    0x0232 {
                        Resume-TimersAfterWindowMove
                    }
                }

                return [IntPtr]::Zero
            }

        $source.AddHook($script:WindowMoveMessageHook)
        $script:WindowMoveMessageSource = $source
    }
    catch {
        # If the native hook cannot be attached, dragging still works normally.
    }
}

function Remove-WindowMoveMessageHook {

    try {

        if (
            $null -ne $script:WindowMoveMessageSource -and
            $null -ne $script:WindowMoveMessageHook
        ) {

            $script:WindowMoveMessageSource.RemoveHook(
                $script:WindowMoveMessageHook
            )
        }
    }
    catch {
    }

    $script:WindowMoveMessageSource = $null
    $script:WindowMoveMessageHook = $null
}

function Get-StarOpacity($x, $y, $random, $clusterBoost) {

    $diagonalPosition =
        (($x / 500) + ($y / 424)) / 2

    $opacity =
        0.62 -
        (0.42 * $diagonalPosition) +
        (($random.NextDouble() * 0.12) - 0.03) +
        $clusterBoost

    return [math]::Min(0.74, [math]::Max(0.12, $opacity))
}

function Add-Star($x, $y, $size, $opacity, $starFillBrush) {

    $star = [System.Windows.Shapes.Ellipse]::new()
    $star.Width = $size
    $star.Height = $size
    $star.Fill = $starFillBrush
    $star.Opacity = $opacity
    $star.Tag = [double]$opacity
    $star.IsHitTestVisible = $false

    [System.Windows.Controls.Canvas]::SetLeft(
        $star,
        [math]::Round($x, 1)
    )

    [System.Windows.Controls.Canvas]::SetTop(
        $star,
        [math]::Round($y, 1)
    )

    [void]$StarLayer.Children.Add($star)

    if ($null -ne $script:StaticStars) {

        [void]$script:StaticStars.Add($star)
    }
}

function Add-RandomStar($random, $starFillBrush) {

    $x = $random.NextDouble() * 500
    $y = $random.NextDouble() * 424
    $size = 0.8 + ($random.NextDouble() * 1.1)

    if ($random.NextDouble() -gt 0.88) {

        $size += 0.7
    }

    $opacity = Get-StarOpacity $x $y $random 0
    Add-Star $x $y $size $opacity $starFillBrush
}

function Add-StarCluster($cluster, $random, $starFillBrush) {

    for ($index = 0; $index -lt [int]$cluster["Count"]; $index++) {

        $x =
            $cluster["X"] +
            (($random.NextDouble() * 2) - 1) *
            $cluster["Spread"]

        $y =
            $cluster["Y"] +
            (($random.NextDouble() * 2) - 1) *
            $cluster["Spread"]

        $x = [math]::Min(492, [math]::Max(4, $x))
        $y = [math]::Min(416, [math]::Max(6, $y))

        $size = 0.8 + ($random.NextDouble() * 1.0)
        $opacity = Get-StarOpacity $x $y $random 0.05

        Add-Star $x $y $size $opacity $starFillBrush
    }
}

function Initialize-StarLayer {

    if ($null -eq $StarLayer) {

        return
    }

    $StarLayer.Children.Clear()
    $script:StaticStars = New-Object System.Collections.ArrayList

    $random = [System.Random]::new()
    $starFillBrush = New-WpfBrush "#F8FBFF"
    $clusterDefinitions = @(
        @{
            X = 94
            Y = 86
            Spread = 32
            Count = 7
        },
        @{
            X = 348
            Y = 72
            Spread = 42
            Count = 6
        },
        @{
            X = 214
            Y = 258
            Spread = 36
            Count = 5
        }
    )

    for ($index = 0; $index -lt 25; $index++) {

        Add-RandomStar $random $starFillBrush
    }

    foreach ($cluster in $clusterDefinitions) {

        Add-StarCluster $cluster $random $starFillBrush
    }

    Start-StarTwinkleAnimations $random
}

function Start-StarTwinkleAnimation($star, $random) {

    if (
        $null -eq $star -or
        $null -eq $star.Tag
    ) {
        return
    }

    $baseOpacity = [double]$star.Tag
    $dimFactor = 0.18 + ($random.NextDouble() * 0.32)
    $dimOpacity = [math]::Max(0.04, $baseOpacity * $dimFactor)
    $cycleSeconds = 4.0 + ($random.NextDouble() * 8.0)
    $delaySeconds = $random.NextDouble() * 12.0

    $animation =
        [System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames]::new()
    $animation.Duration =
        [System.Windows.Duration]::new(
            [TimeSpan]::FromSeconds($cycleSeconds)
        )
    $animation.BeginTime = [TimeSpan]::FromSeconds($delaySeconds)
    $animation.RepeatBehavior =
        [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $animation.FillBehavior =
        [System.Windows.Media.Animation.FillBehavior]::HoldEnd

    $ease = [System.Windows.Media.Animation.SineEase]::new()
    $ease.EasingMode =
        [System.Windows.Media.Animation.EasingMode]::EaseInOut

    [void]$animation.KeyFrames.Add(
        [System.Windows.Media.Animation.LinearDoubleKeyFrame]::new(
            [double]$baseOpacity,
            [System.Windows.Media.Animation.KeyTime]::FromTimeSpan(
                [TimeSpan]::Zero
            )
        )
    )

    [void]$animation.KeyFrames.Add(
        [System.Windows.Media.Animation.EasingDoubleKeyFrame]::new(
            [double]$dimOpacity,
            [System.Windows.Media.Animation.KeyTime]::FromTimeSpan(
                [TimeSpan]::FromMilliseconds(500)
            ),
            $ease
        )
    )

    [void]$animation.KeyFrames.Add(
        [System.Windows.Media.Animation.EasingDoubleKeyFrame]::new(
            [double]$baseOpacity,
            [System.Windows.Media.Animation.KeyTime]::FromTimeSpan(
                [TimeSpan]::FromMilliseconds(1000)
            ),
            $ease
        )
    )

    [void]$animation.KeyFrames.Add(
        [System.Windows.Media.Animation.LinearDoubleKeyFrame]::new(
            [double]$baseOpacity,
            [System.Windows.Media.Animation.KeyTime]::FromTimeSpan(
                [TimeSpan]::FromSeconds($cycleSeconds)
            )
        )
    )

    $star.BeginAnimation(
        [System.Windows.UIElement]::OpacityProperty,
        $animation
    )
}

function Start-StarTwinkleAnimations($random) {

    if (
        $null -eq $script:StaticStars -or
        $script:StaticStars.Count -eq 0
    ) {

        return
    }

    foreach ($star in $script:StaticStars) {

        Start-StarTwinkleAnimation $star $random
    }
}

function Get-SkyOpacityMultiplier($x, $y) {

    $diagonalPosition =
        (($x / 500) + ($y / 424)) / 2

    return [math]::Min(
        0.84,
        [math]::Max(0.32, (0.78 - (0.34 * $diagonalPosition)))
    )
}

function New-ShootingStarAnimation($from, $to, $seconds) {

    $animation = [System.Windows.Media.Animation.DoubleAnimation]::new()
    $animation.From = [double]$from
    $animation.To = [double]$to
    $animation.Duration =
        [System.Windows.Duration]::new(
            [TimeSpan]::FromSeconds($seconds)
        )

    return $animation
}

function New-ShootingStarTrailBrush {

    $brush = [System.Windows.Media.LinearGradientBrush]::new()
    $brush.StartPoint = [System.Windows.Point]::new(1, 0)
    $brush.EndPoint = [System.Windows.Point]::new(0, 1)

    foreach ($stop in @(
        @{
            Color = "#00F8FBFF"
            Offset = 0
        },
        @{
            Color = "#55F8FBFF"
            Offset = 0.55
        },
        @{
            Color = "#FFF8FBFF"
            Offset = 1
        }
    )) {

        $color =
            [System.Windows.Media.ColorConverter]::ConvertFromString(
                $stop["Color"]
            )

        [void]$brush.GradientStops.Add(
            [System.Windows.Media.GradientStop]::new(
                $color,
                [double]$stop["Offset"]
            )
        )
    }

    return $brush
}

function Add-ShootingStar {

    if (
        $script:ThemeName -ne "Dark" -or
        $null -eq $StarLayer
    ) {
        return
    }

    $windowWidth = 500.0
    $windowHeight = 424.0
    $pathLength =
        [math]::Sqrt(
            ($windowWidth * $windowWidth) +
            ($windowHeight * $windowHeight)
        )

    $unitX = -$windowWidth / $pathLength
    $unitY = $windowHeight / $pathLength
    $maxTrailLength = 68.0
    $maxHeadSize = 2.6
    $maxStrokeThickness = 1.15
    $exitPadding = $maxTrailLength + 16
    $preEntryDistance =
        32 +
        ($script:ShootingStarRandom.NextDouble() * 78)

    if ($script:ShootingStarRandom.NextDouble() -lt 0.64) {

        $entryX =
            34 +
            ($script:ShootingStarRandom.NextDouble() * 492)
        $entryY = -1
    }
    else {

        $entryX = $windowWidth + 1
        $entryY =
            $script:ShootingStarRandom.NextDouble() * 338
    }

    $startX = $entryX - ($unitX * $preEntryDistance)
    $startY = $entryY - ($unitY * $preEntryDistance)

    $travelToLeft = ($startX + $exitPadding) / (-$unitX)
    $travelToBottom =
        ($windowHeight + $exitPadding - $startY) / $unitY
    $travelDistance = [math]::Min($travelToLeft, $travelToBottom)

    $endX = $startX + ($unitX * $travelDistance)
    $endY = $startY + ($unitY * $travelDistance)

    $durationRatio =
        [math]::Min(
            1,
            [math]::Max(0, ($travelDistance / ($pathLength + $exitPadding)))
        )

    $durationSeconds = 2.6 + (2.2 * $durationRatio)
    $sizeScale = 1.0 - (0.38 * $durationRatio)
    $trailLength = $maxTrailLength * (1.0 - (0.24 * $durationRatio))
    $headSize = $maxHeadSize * $sizeScale
    $trailStrokeThickness =
        $maxStrokeThickness * (1.0 - (0.30 * $durationRatio))

    $tailOffsetX = -$unitX * $trailLength
    $tailOffsetY = -$unitY * $trailLength
    $startTailX = $startX + $tailOffsetX
    $startTailY = $startY + $tailOffsetY
    $endTailX = $endX + $tailOffsetX
    $endTailY = $endY + $tailOffsetY

    $startOpacity =
        Get-SkyOpacityMultiplier `
            (($startX + $startTailX) / 2) `
            (($startY + $startTailY) / 2)

    $endOpacity =
        Get-SkyOpacityMultiplier `
            (($endX + $endTailX) / 2) `
            (($endY + $endTailY) / 2)

    $skyOpacity =
        [math]::Min(
            0.84,
            [math]::Max($startOpacity, $endOpacity) + 0.04
        )

    $shootingStarBrush = New-WpfBrush "#F8FBFF"
    $trailBrush = New-ShootingStarTrailBrush

    $trail = [System.Windows.Shapes.Line]::new()
    $trail.X1 = $startTailX
    $trail.Y1 = $startTailY
    $trail.X2 = $startX
    $trail.Y2 = $startY
    $trail.Stroke = $trailBrush
    $trail.StrokeThickness = $trailStrokeThickness
    $trail.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
    $trail.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
    $trail.Opacity = $skyOpacity
    $trail.IsHitTestVisible = $false

    $head = [System.Windows.Shapes.Ellipse]::new()
    $head.Width = $headSize
    $head.Height = $headSize
    $head.Fill = $shootingStarBrush
    $head.Opacity = $skyOpacity
    $head.IsHitTestVisible = $false

    [System.Windows.Controls.Canvas]::SetLeft(
        $head,
        ($startX - ($headSize / 2))
    )

    [System.Windows.Controls.Canvas]::SetTop(
        $head,
        ($startY - ($headSize / 2))
    )

    [void]$StarLayer.Children.Add($trail)
    [void]$StarLayer.Children.Add($head)

    $trail.BeginAnimation(
        [System.Windows.Shapes.Line]::X1Property,
        (New-ShootingStarAnimation $startTailX $endTailX $durationSeconds)
    )

    $trail.BeginAnimation(
        [System.Windows.Shapes.Line]::Y1Property,
        (New-ShootingStarAnimation $startTailY $endTailY $durationSeconds)
    )

    $trail.BeginAnimation(
        [System.Windows.Shapes.Line]::X2Property,
        (New-ShootingStarAnimation $startX $endX $durationSeconds)
    )

    $trail.BeginAnimation(
        [System.Windows.Shapes.Line]::Y2Property,
        (New-ShootingStarAnimation $startY $endY $durationSeconds)
    )

    $head.BeginAnimation(
        [System.Windows.Controls.Canvas]::TopProperty,
        (New-ShootingStarAnimation `
            ($startY - ($headSize / 2)) `
            ($endY - ($headSize / 2)) `
            $durationSeconds)
    )

    $leftAnimation =
        New-ShootingStarAnimation `
            ($startX - ($headSize / 2)) `
            ($endX - ($headSize / 2)) `
            $durationSeconds

    $leftAnimation.Add_Completed({

        [void]$StarLayer.Children.Remove($trail)
        [void]$StarLayer.Children.Remove($head)
    })

    $head.BeginAnimation(
        [System.Windows.Controls.Canvas]::LeftProperty,
        $leftAnimation
    )
}

function Schedule-NextShootingStar {

    if ($null -eq $shootingStarTimer) {

        return
    }

    $seconds = 2 + $script:ShootingStarRandom.Next(0, 5)
    $shootingStarTimer.Interval = [TimeSpan]::FromSeconds($seconds)
    $shootingStarTimer.Start()
}

function Invoke-ShootingStarTick {

    $shootingStarTimer.Stop()

    if ($script:ThemeName -eq "Dark") {

        Add-ShootingStar
    }

    Schedule-NextShootingStar
}

# ==============================
# MONITORING STATE
# ==============================

function Reset-MonitoringState($settings) {

    $script:MonitoringState = @{
        IsMonitoring = $false
        Settings = $settings
        RequiredSamples = 5
        Samples = @()
        OperationPending = $false
        OperationStopwatch = $null
        OperationErrorMessage = ""
        DataAvailabilityStopwatch = $null
        ConnectionIssueStopwatch = $null
        LastNetworkSnapshot = $null
    }
}

function Clear-PendingOperationCountdown {

    if ($null -ne $script:MonitoringState.OperationStopwatch) {

        $script:MonitoringState.OperationStopwatch.Stop()
    }

    $script:MonitoringState.OperationPending = $false
    $script:MonitoringState.OperationStopwatch = $null
}

function Stop-Monitoring($message) {

    $hadOperationPending = $script:MonitoringState.OperationPending

    Clear-PendingOperationCountdown

    if ($null -ne $script:MonitoringState.ConnectionIssueStopwatch) {

        $script:MonitoringState.ConnectionIssueStopwatch.Stop()
    }

    if ($null -ne $script:MonitoringState.DataAvailabilityStopwatch) {

        $script:MonitoringState.DataAvailabilityStopwatch.Stop()
    }

    $monitorTimer.Stop()
    Disable-SleepPrevention

    $script:MonitoringState.IsMonitoring = $false

    if ($hadOperationPending) {

        Set-TemporaryIdleStatus "Operation stopped"
    }
    elseif ([string]::IsNullOrWhiteSpace($message)) {

        Set-IdleStatus
    }
    else {

        Set-TemporaryIdleStatus $message
    }

    Set-InputsEnabled (-not $script:SettingsReadFailed)
    Update-Buttons
}

function Stop-AllActivityForExit {

    Disable-SleepPrevention
    Remove-WindowMoveMessageHook

    if ($null -ne $monitorTimer) {

        $monitorTimer.Stop()
    }

    if ($null -ne $idleStatusTimer) {

        $idleStatusTimer.Stop()
    }

    if ($null -ne $shootingStarTimer) {

        $shootingStarTimer.Stop()
    }

    if ($null -ne $script:MonitoringState) {

        Clear-PendingOperationCountdown

        if ($null -ne $script:MonitoringState.ConnectionIssueStopwatch) {

            $script:MonitoringState.ConnectionIssueStopwatch.Stop()
        }

        if ($null -ne $script:MonitoringState.DataAvailabilityStopwatch) {

            $script:MonitoringState.DataAvailabilityStopwatch.Stop()
        }

        $script:MonitoringState.IsMonitoring = $false
        $script:MonitoringState.LastNetworkSnapshot = $null
    }
}

function Exit-Application {

    $script:IsClosing = $true
    Stop-AllActivityForExit
    $window.Close()
}

function Start-MonitoringFromGui {

    $idleStatusTimer.Stop()

    try {

        $settings = Get-SettingsFromControls
    }
    catch {

        Set-AlertMessage $_.Exception.Message
        return
    }

    if (-not (Save-Settings $settings)) {

        Set-AlertMessage $script:SettingsOperationError
        return
    }

    Reset-MonitoringState $settings

    $script:MonitoringState.IsMonitoring = $true
    Enable-SleepPrevention
    $script:MonitoringState.DataAvailabilityStopwatch =
        [System.Diagnostics.Stopwatch]::StartNew()

    $SpeedValueText.Text = "Calculating..."
    $CountdownValueText.Text = "None"
    Set-StatusMessage "Calibrating" (Get-ResourceBrush "StatusWarning")
    Set-AlertMessage ""

    Set-InputsEnabled $false
    Show-MainView
    Update-Buttons

    $monitorTimer.Start()
}

function Invoke-MonitoringTick {

    if (-not $script:MonitoringState.IsMonitoring) {

        return
    }

    $settings = $script:MonitoringState.Settings
    $adapterResult = Get-SelectedAdapterResult $settings.MonitorMode
    $connectionResult = Get-InternetConnectionResult $adapterResult

    if ($connectionResult.Status -ne "Online") {

        if ($script:MonitoringState.OperationPending) {

            Clear-PendingOperationCountdown
        }

        $script:MonitoringState.Samples = @()
        $script:MonitoringState.DataAvailabilityStopwatch.Restart()
        $script:MonitoringState.LastNetworkSnapshot = $null

        if ($null -eq $script:MonitoringState.ConnectionIssueStopwatch) {

            $script:MonitoringState.ConnectionIssueStopwatch =
                [System.Diagnostics.Stopwatch]::StartNew()
        }

        $networkName = Get-MonitorModeDisplayName $settings.MonitorMode
        $speedText = "Unavailable"

        switch ($connectionResult.Status) {

            "NoMatchingInterface" {
                $statusText = "No active $networkName interface"
            }

            "AdapterDataUnavailable" {
                $statusText = "Waiting for interface data"
            }

            "ConnectionDataUnavailable" {
                $statusText = "Waiting for network status"
            }

            default {

                if (
                    $script:MonitoringState.ConnectionIssueStopwatch.Elapsed.TotalSeconds `
                    -ge 5
                ) {
                    $statusText = "No internet connection"
                }
                else {
                    $statusText = "Checking network connection"
                }
            }
        }

        $SpeedValueText.Text = $speedText
        $CountdownValueText.Text = "None"
        Set-StatusMessage $statusText (Get-ResourceBrush "StatusWarning")
        Update-Buttons
        return
    }

    if ($null -ne $script:MonitoringState.ConnectionIssueStopwatch) {

        $script:MonitoringState.ConnectionIssueStopwatch.Stop()
        $script:MonitoringState.ConnectionIssueStopwatch = $null
        $script:MonitoringState.Samples = @()
        $script:MonitoringState.DataAvailabilityStopwatch.Restart()
        $script:MonitoringState.LastNetworkSnapshot = $null
    }

    $result =
        Get-NetworkSpeedResult `
            $settings.MonitorTraffic `
            $adapterResult

    if ($result.Status -eq "NoMatchingInterface") {

        if ($script:MonitoringState.OperationPending) {

            Clear-PendingOperationCountdown
        }

        $script:MonitoringState.Samples = @()
        $script:MonitoringState.DataAvailabilityStopwatch.Restart()
        $script:MonitoringState.LastNetworkSnapshot = $null

        $networkName = Get-MonitorModeDisplayName $settings.MonitorMode

        $SpeedValueText.Text = "Unavailable"
        $CountdownValueText.Text = "None"
        Set-StatusMessage "No active $networkName interface" (Get-ResourceBrush "StatusWarning")
        Update-Buttons
        return
    }

    if ($result.Status -eq "Sampling") {

        $SpeedValueText.Text = "Calculating..."
        $CountdownValueText.Text = "None"
        Set-StatusMessage "Calibrating" (Get-ResourceBrush "StatusWarning")
        Update-Buttons
        return
    }

    if ($result.Status -ne "OK") {

        if (
            $script:MonitoringState.DataAvailabilityStopwatch.Elapsed.TotalSeconds `
            -ge 5
        ) {

            if ($script:MonitoringState.OperationPending) {

                Clear-PendingOperationCountdown
            }

            $script:MonitoringState.Samples = @()
            $script:MonitoringState.LastNetworkSnapshot = $null

            $SpeedValueText.Text = "Unavailable"
            $CountdownValueText.Text = "None"
            Set-StatusMessage "Waiting for network data" (Get-ResourceBrush "StatusWarning")
            Update-Buttons
        }

        return
    }

    $script:MonitoringState.DataAvailabilityStopwatch.Restart()
    $script:MonitoringState.Samples += $result.SpeedKBps

    if ($script:MonitoringState.Samples.Count -gt $script:MonitoringState.RequiredSamples) {

        $script:MonitoringState.Samples =
            $script:MonitoringState.Samples[-$script:MonitoringState.RequiredSamples..-1]
    }

    if ($script:MonitoringState.Samples.Count -lt $script:MonitoringState.RequiredSamples) {

        $SpeedValueText.Text =
            "Calculating... ($($script:MonitoringState.Samples.Count)/$($script:MonitoringState.RequiredSamples))"

        $CountdownValueText.Text = "None"
        Set-StatusMessage "Calibrating" (Get-ResourceBrush "StatusWarning")
        Update-Buttons
        return
    }

    $averageSpeed = [math]::Round(
        (($script:MonitoringState.Samples | Measure-Object -Average).Average),
        2
    )

    $displaySpeed = Format-Speed $averageSpeed

    if ($averageSpeed -lt $settings.ThresholdKBps) {

        if (-not $script:MonitoringState.OperationPending) {

            $script:MonitoringState.OperationPending = $true
            $script:MonitoringState.OperationStopwatch =
                [System.Diagnostics.Stopwatch]::StartNew()

            $script:MonitoringState.OperationErrorMessage = ""
        }
    }
    else {

        $script:MonitoringState.OperationErrorMessage = ""

        if ($script:MonitoringState.OperationPending) {

            Clear-PendingOperationCountdown
        }
    }

    $SpeedValueText.Text = $displaySpeed

    if ($script:MonitoringState.OperationPending) {

        $remainingSeconds = [math]::Max(
            0,
            [math]::Ceiling(
                $settings.CountdownSeconds -
                $script:MonitoringState.OperationStopwatch.Elapsed.TotalSeconds
            )
        )

        if ($remainingSeconds -le 0) {

            Disable-SleepPrevention
            $operationExitCode = Invoke-ConfiguredOperation $settings.Operation

            if ($operationExitCode -eq 0) {

                $monitorTimer.Stop()
                Clear-PendingOperationCountdown
                $script:MonitoringState.IsMonitoring = $false
                Set-InputsEnabled (-not $script:SettingsReadFailed)
                Set-StatusMessage `
                    (Get-OperationRunningText $settings.Operation) `
                    (Get-ResourceBrush "StatusDanger")
                $CountdownValueText.Text = "Now"
                Update-Buttons
                return
            }

            Enable-SleepPrevention
            Clear-PendingOperationCountdown

            $script:MonitoringState.OperationErrorMessage =
                "Unable to start $(Get-OperationErrorName $settings.Operation). Windows returned error code $operationExitCode."

            $CountdownValueText.Text = "None"
            Set-StatusMessage "Monitoring" (Get-ResourceBrush "StatusSuccess")
            Set-AlertMessage $script:MonitoringState.OperationErrorMessage
            Update-Buttons
            return
        }

        $CountdownValueText.Text = "$remainingSeconds seconds"
        Set-StatusMessage `
            (Get-OperationPendingText $settings.Operation) `
            (Get-ResourceBrush "StatusDanger")
    }
    else {

        $CountdownValueText.Text = "None"
        Set-StatusMessage "Monitoring" (Get-ResourceBrush "StatusSuccess")
    }

    Set-AlertMessage $script:MonitoringState.OperationErrorMessage
    Update-Buttons
}

# ==============================
# XAML LOADING
# ==============================

if (-not (Test-Path -LiteralPath $XamlFile)) {

    Show-StartupError "NetworkAutoShutdown.xaml could not be found next to the application. Reinstall the application or restore the missing XAML file."
    return
}

$script:InitialSettings = Load-Settings
$script:ThemeName = $script:InitialSettings.Theme

try {

    $xamlContent = Get-Content -LiteralPath $XamlFile -Raw -ErrorAction Stop
    $stringReader = New-Object System.IO.StringReader -ArgumentList $xamlContent
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)
    $xmlReader.Close()
    $stringReader.Close()
}
catch {

    Show-StartupError "The interface could not be loaded from NetworkAutoShutdown.xaml. $($_.Exception.Message)"
    return
}

function Get-XamlControl($name) {

    $control = $window.FindName($name)

    if ($null -eq $control) {

        throw "The XAML file is missing the '$name' control."
    }

    return $control
}

try {

    $AppIconImage = Get-XamlControl "AppIconImage"
    $MinimizeButton = Get-XamlControl "MinimizeButton"
    $CloseButton = Get-XamlControl "CloseButton"
    $ThemeToggleButton = Get-XamlControl "ThemeToggleButton"
    $MoonIcon = Get-XamlControl "MoonIcon"
    $SunIcon = Get-XamlControl "SunIcon"
    $StarLayer = Get-XamlControl "StarLayer"
    $ContentSurface = Get-XamlControl "ContentSurface"
    $MainView = Get-XamlControl "MainView"
    $SettingsView = Get-XamlControl "SettingsView"
    $MainStatusPanel = Get-XamlControl "MainStatusPanel"
    $SettingsPanel = Get-XamlControl "SettingsPanel"
    $SpeedValueText = Get-XamlControl "SpeedValueText"
    $StatusValueText = Get-XamlControl "StatusValueText"
    $CountdownValueText = Get-XamlControl "CountdownValueText"
    $CurrentSettingsText = Get-XamlControl "CurrentSettingsText"
    $StartButton = Get-XamlControl "StartButton"
    $SettingsButton = Get-XamlControl "SettingsButton"
    $ExitButton = Get-XamlControl "ExitButton"
    $ThresholdBox = Get-XamlControl "ThresholdBox"
    $ThresholdUnitBox = Get-XamlControl "ThresholdUnitBox"
    $DelayBox = Get-XamlControl "DelayBox"
    $DelayUnitBox = Get-XamlControl "DelayUnitBox"
    $MonitorBox = Get-XamlControl "MonitorBox"
    $OperationBox = Get-XamlControl "OperationBox"
    $NetworkBox = Get-XamlControl "NetworkBox"
    $SaveButton = Get-XamlControl "SaveButton"
    $ResetButton = Get-XamlControl "ResetButton"
    $BackButton = Get-XamlControl "BackButton"
    $AlertText = Get-XamlControl "AlertText"
}
catch {

    Show-StartupError $_.Exception.Message
    return
}

try {

    $script:AppIcon = Get-ApplicationIcon
    $iconSource = Convert-IconToImageSource $script:AppIcon

    $window.Icon = $iconSource
    $AppIconImage.Source = $iconSource
}
catch {
    # The app can still run if the icon cannot be converted.
}

Initialize-StarLayer

Set-ComboItems $ThresholdUnitBox @("KB/s", "MB/s", "GB/s")
Set-ComboItems $DelayUnitBox @("seconds", "minutes", "hours")
Set-ComboItems $MonitorBox @("Downloads", "Uploads", "Downloads + uploads")
Set-ComboItems $OperationBox @("Shutdown", "Restart", "Sleep", "Lock")
Set-ComboItems $NetworkBox @("All Interfaces", "Wi-Fi", "Ethernet")

foreach ($textBox in @($ThresholdBox, $DelayBox)) {

    $textBox.Add_PreviewTextInput({

        param($sender, $eventArgs)

        if ($eventArgs.Text -notmatch '^[0-9]+$') {

            $eventArgs.Handled = $true
        }
    })
}

$monitorTimer = New-Object System.Windows.Threading.DispatcherTimer
$monitorTimer.Interval = [TimeSpan]::FromSeconds(1)

$idleStatusTimer = New-Object System.Windows.Threading.DispatcherTimer
$idleStatusTimer.Interval = [TimeSpan]::FromMilliseconds(2500)

$script:ShootingStarRandom = [System.Random]::new()
$shootingStarTimer = New-Object System.Windows.Threading.DispatcherTimer

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Text = "Auto Shutdown"

if ($null -ne $script:AppIcon) {

    $notifyIcon.Icon = $script:AppIcon
}
else {

    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
}

$notifyIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showTrayItem = $trayMenu.Items.Add("Show")
$startTrayItem = $trayMenu.Items.Add("Start Monitoring")
[void]$trayMenu.Items.Add("-")
$exitTrayItem = $trayMenu.Items.Add("Exit")
$notifyIcon.ContextMenuStrip = $trayMenu

Reset-MonitoringState $script:InitialSettings

$SaveButton.Add_Click({

    try {

        $settings = Get-SettingsFromControls
    }
    catch {

        Set-AlertMessage $_.Exception.Message
        return
    }

    if (Save-Settings $settings) {

        Update-CurrentSettingsLabel
        Set-AlertMessage "Settings saved."
    }
    else {

        Set-AlertMessage $script:SettingsOperationError
    }
})

$ResetButton.Add_Click({

    $result =
        [System.Windows.MessageBox]::Show(
            $window,
            "Reset all settings to their defaults?",
            "Reset settings",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )

    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {

        if (Reset-Settings) {

            Refresh-SettingsDisplay
            Set-AlertMessage "Settings reset."
        }
        else {

            Set-AlertMessage "Unable to reset settings."

            [void][System.Windows.MessageBox]::Show(
                $window,
                $script:SettingsOperationError,
                "Unable to reset settings",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            )
        }
    }
})

$StartButton.Add_Click({

    if ($script:MonitoringState.IsMonitoring) {

        Stop-Monitoring "Stopped"
    }
    else {

        Start-MonitoringFromGui
    }
})

$SettingsButton.Add_Click({
    Show-SettingsView
})

$BackButton.Add_Click({
    Show-MainView
})

$ExitButton.Add_Click({
    Exit-Application
})

$ThemeToggleButton.Add_Click({

    if ($script:ThemeName -eq "Dark") {

        Apply-Theme "Light"
    }
    else {

        Apply-Theme "Dark"
    }

    if (-not (Save-ThemePreference)) {

        Set-AlertMessage $script:SettingsOperationError
    }
    else {

        Set-AlertMessage ""
    }
})

$MinimizeButton.Add_Click({

    [System.Windows.SystemCommands]::MinimizeWindow($window)
})

$CloseButton.Add_Click({
    Exit-Application
})

$ContentSurface.Add_MouseLeftButtonDown({

    param($sender, $eventArgs)

    Start-BackgroundWindowDrag $eventArgs
})

$monitorTimer.Add_Tick({
    Invoke-MonitoringTick
})

$idleStatusTimer.Add_Tick({

    $idleStatusTimer.Stop()

    if (-not $script:MonitoringState.IsMonitoring) {

        Set-IdleStatus
    }
})

$shootingStarTimer.Add_Tick({
    Invoke-ShootingStarTick
})

$notifyIcon.Add_DoubleClick({
    Show-AppWindow
})

$showTrayItem.Add_Click({
    Show-AppWindow
})

$startTrayItem.Add_Click({

    if ($script:MonitoringState.IsMonitoring) {

        Stop-Monitoring "Stopped"
    }
    else {

        Start-MonitoringFromGui
    }
})

$exitTrayItem.Add_Click({
    Exit-Application
})

$window.Add_SourceInitialized({
    Enable-Windows11RoundedCorners $window
    Add-WindowMoveMessageHook
})

$window.Add_Closing({

    $script:IsClosing = $true
    Stop-AllActivityForExit
    Dispose-TrayResources
})

Refresh-SettingsDisplay $script:InitialSettings
Schedule-NextShootingStar

if ($SmokeTest) {

    $previousTheme = $script:ThemeName
    Apply-Theme "Dark"
    Add-ShootingStar
    Apply-Theme $previousTheme

    if ($null -ne $shootingStarTimer) {

        $shootingStarTimer.Stop()
    }

    Dispose-TrayResources

    "Runtime initialization OK"
    return
}

[void]$window.ShowDialog()

