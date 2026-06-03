# ==============================
# AUTO SHUTDOWN v1.0
# ==============================

# Locate the folder containing the script during development
# or the compiled EXE after release.

if ($MyInvocation.MyCommand.CommandType -eq "ExternalScript") {

    $AppDirectory =
        Split-Path `
            -Parent `
            -Path $MyInvocation.MyCommand.Definition
}
else {

    $AppDirectory =
        Split-Path `
            -Parent `
            -Path ([Environment]::GetCommandLineArgs()[0])

    if ([string]::IsNullOrWhiteSpace($AppDirectory)) {

        $AppDirectory = "."
    }
}

$SettingsFile = Join-Path $AppDirectory "settings.ini"

# These variables store user-facing settings warnings.
# They are reset whenever settings are loaded or changed.

$script:SettingsLoadWarning = ""
$script:SettingsReadFailed = $false
$script:SettingsOperationError = ""

# ==============================
# DISPLAY HELPERS
# ==============================

function Write-AppTitle {

    Write-Host ""
    Write-Host "       A U T O  S H U T D O W N  v1.0" -ForegroundColor Cyan
    Write-Host ""
}

function Wait-ForAnyKey {

    Write-Host ""
    Write-Host "Press any key to continue..."

    [void][System.Console]::ReadKey($true)
}

# ==============================
# DEFAULT SETTINGS
# Change defaults here only.
# ==============================

function Get-DefaultSettings {

    return @{
        ThresholdKBps = 100
        CountdownSeconds = 60
        MonitorMode = "All"
    }
}

# ==============================
# SETTINGS HELPERS
# ==============================

function Test-SettingsMatch($firstSettings, $secondSettings) {

    return (
        $firstSettings.ThresholdKBps -eq $secondSettings.ThresholdKBps -and
        $firstSettings.CountdownSeconds -eq $secondSettings.CountdownSeconds -and
        $firstSettings.MonitorMode -eq $secondSettings.MonitorMode
    )
}

function ConvertTo-PositiveInteger($text) {

    $value = 0

    if (
        $null -ne $text -and
        [int]::TryParse($text.Trim(), [ref]$value) -and
        $value -gt 0
    ) {
        return $value
    }

    return $null
}

function Get-MonitorModeDisplayName($monitorMode) {

    switch ($monitorMode) {

        "WiFi" {
            return "Wi-Fi"
        }

        "Ethernet" {
            return "Ethernet"
        }

        default {
            return "All Interfaces"
        }
    }
}

function Write-SettingsWarning {

    if (-not [string]::IsNullOrWhiteSpace($script:SettingsLoadWarning)) {

        Write-Host ""
        Write-Host $script:SettingsLoadWarning -ForegroundColor Red
    }
}

function Write-SettingsOperationError {

    if (-not [string]::IsNullOrWhiteSpace($script:SettingsOperationError)) {

        Write-Host ""
        Write-Host $script:SettingsOperationError -ForegroundColor Red
    }
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

        $lines = @(
            Get-Content -LiteralPath $SettingsFile -ErrorAction Stop
        )
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

        # Ignore blank lines and comments.

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

                    $settings.ThresholdKBps = $value
                }
                else {

                    $hasUnknownOrInvalidSettings = $true
                }
            }

            "CountdownSeconds" {

                $value = ConvertTo-PositiveInteger $rawValue

                if ($null -ne $value) {

                    $settings.CountdownSeconds = $value
                }
                else {

                    $hasUnknownOrInvalidSettings = $true
                }
            }

            "MonitorMode" {

                switch ($rawValue.ToLowerInvariant()) {

                    "all" {
                        $settings.MonitorMode = "All"
                    }

                    "wifi" {
                        $settings.MonitorMode = "WiFi"
                    }

                    "ethernet" {
                        $settings.MonitorMode = "Ethernet"
                    }

                    default {
                        $hasUnknownOrInvalidSettings = $true
                    }
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

    # If the file contains only recognized default values,
    # it is redundant. Try to remove it quietly.

    if (
        -not $hasUnknownOrInvalidSettings -and
        (Test-SettingsMatch $settings $defaults)
    ) {
        try {

            Remove-Item `
                -LiteralPath $SettingsFile `
                -Force `
                -ErrorAction Stop
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

    # Save only settings that differ from the built-in defaults.

    if ($settings.ThresholdKBps -ne $defaults.ThresholdKBps) {

        $lines += "ThresholdKBps=$($settings.ThresholdKBps)"
    }

    if ($settings.CountdownSeconds -ne $defaults.CountdownSeconds) {

        $lines += "CountdownSeconds=$($settings.CountdownSeconds)"
    }

    if ($settings.MonitorMode -ne $defaults.MonitorMode) {

        $lines += "MonitorMode=$($settings.MonitorMode)"
    }

    # If no custom settings remain, remove the optional INI file.

    if ($lines.Count -eq 0) {

        if (-not (Test-Path -LiteralPath $SettingsFile)) {

            return $true
        }

        try {

            Remove-Item `
                -LiteralPath $SettingsFile `
                -Force `
                -ErrorAction Stop

            return $true
        }
        catch {

            $script:SettingsOperationError =
                "Unable to update settings. settings.ini could not be removed."

            return $false
        }
    }

    $identifier = [guid]::NewGuid().ToString("N")

    $temporaryFile = Join-Path `
        $AppDirectory `
        ("settings.{0}.tmp" -f $identifier)

    $backupFile = Join-Path `
        $AppDirectory `
        ("settings.{0}.bak" -f $identifier)

    $settingsFilePreviouslyExisted =
        Test-Path -LiteralPath $SettingsFile

    $backupCreated = $false

    try {

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        # Write new values to a temporary file first.

        [System.IO.File]::WriteAllLines(
            $temporaryFile,
            [string[]]$lines,
            $utf8NoBom
        )

        # Verify the temporary file.

        $writtenLines = @(
            Get-Content -LiteralPath $temporaryFile -ErrorAction Stop
        )

        if (
            ($writtenLines.Count -ne $lines.Count) -or
            (($writtenLines -join "`n") -ne ($lines -join "`n"))
        ) {
            throw "Temporary settings file verification failed."
        }

        # Preserve the previous INI before overwriting it.

        if ($settingsFilePreviouslyExisted) {

            Copy-Item `
                -LiteralPath $SettingsFile `
                -Destination $backupFile `
                -Force `
                -ErrorAction Stop

            $backupCreated = $true
        }

        # Copy the verified temporary file into place.

        Copy-Item `
            -LiteralPath $temporaryFile `
            -Destination $SettingsFile `
            -Force `
            -ErrorAction Stop

        # Verify the final INI file.

        $finalLines = @(
            Get-Content -LiteralPath $SettingsFile -ErrorAction Stop
        )

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

        # Restore the previous INI if one existed.

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
            # Remove a failed first-time save.

            Remove-Item `
                -LiteralPath $SettingsFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $temporaryFile) {

            Remove-Item `
                -LiteralPath $temporaryFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $backupFile) {

            Remove-Item `
                -LiteralPath $backupFile `
                -Force `
                -ErrorAction SilentlyContinue
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

    # No INI file means built-in defaults are already active.

    if (-not (Test-Path -LiteralPath $SettingsFile)) {

        return $true
    }

    try {

        Remove-Item `
            -LiteralPath $SettingsFile `
            -Force `
            -ErrorAction Stop

        return $true
    }
    catch {

        $script:SettingsOperationError =
            "Unable to reset settings. settings.ini could not be removed."

        return $false
    }
}

# ==============================
# INTERFACE DETECTION
# ==============================

function ConvertTo-InterfaceToken($text) {

    if ([string]::IsNullOrWhiteSpace($text)) {

        return ""
    }

    return (($text -replace '[^a-zA-Z0-9]', '').ToLowerInvariant())
}

function Test-AdapterMatchesMonitorMode($adapter, $monitorMode) {

    $adapterText = @(
        $adapter.Name
        $adapter.InterfaceDescription
        $adapter.MediaType
        $adapter.PhysicalMediaType
        $adapter.NdisPhysicalMedium
    ) -join " "

    switch ($monitorMode) {

        "WiFi" {

            return (
                $adapterText -match '(?i)wi-?fi|wireless|wlan|802\.11|native\s+802\.11'
            )
        }

        "Ethernet" {

            return (
                $adapterText -match '(?i)ethernet|802\.3|gigabit|gbit|gbe|fast\s+ethernet'
            )
        }

        default {

            return $true
        }
    }
}

function Get-SelectedAdapterResult($monitorMode) {

    if ($monitorMode -eq "All") {

        return [PSCustomObject]@{
            Status = "OK"
            Adapters = @()
        }
    }

    try {

        $matchingAdapters = @(
            Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object {
                $_.Status -eq "Up" -and
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

function Test-CounterSampleMatchesAdapter($sample, $adapter) {

    $sampleToken = ConvertTo-InterfaceToken $sample.InstanceName

    if ([string]::IsNullOrWhiteSpace($sampleToken)) {

        return $false
    }

    $adapterTokens = @(
        (ConvertTo-InterfaceToken $adapter.Name)
        (ConvertTo-InterfaceToken $adapter.InterfaceDescription)
    ) |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    }

    foreach ($adapterToken in $adapterTokens) {

        if (
            $sampleToken -eq $adapterToken -or
            $sampleToken.Contains($adapterToken) -or
            $adapterToken.Contains($sampleToken)
        ) {
            return $true
        }
    }

    return $false
}

# ==============================
# INTERNET CONNECTION CHECK
# ==============================

function Test-ProfileHasInternet($profile) {

    return (
        "$($profile.IPv4Connectivity)" -eq "Internet" -or
        "$($profile.IPv6Connectivity)" -eq "Internet"
    )
}

function Get-InternetConnectionResult($monitorMode, $adapterResult) {

    try {

        $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
    }
    catch {

        return [PSCustomObject]@{
            Status = "ConnectionDataUnavailable"
        }
    }

    # All Interfaces:
    # consider the computer online if any profile reports internet access.

    if ($monitorMode -eq "All") {

        $internetProfiles = @(
            $profiles |
            Where-Object {
                Test-ProfileHasInternet $_
            }
        )

        if ($internetProfiles.Count -gt 0) {

            return [PSCustomObject]@{
                Status = "Online"
            }
        }

        return [PSCustomObject]@{
            Status = "NoInternet"
        }
    }

    # Wi-Fi or Ethernet:
    # only consider profiles belonging to the selected interface type.

    if ($adapterResult.Status -ne "OK") {

        return [PSCustomObject]@{
            Status = $adapterResult.Status
        }
    }

    $adapterIndexes = @(
        $adapterResult.Adapters |
        ForEach-Object {
            $_.ifIndex
        }
    )

    $matchingProfiles = @(
        $profiles |
        Where-Object {
            $adapterIndexes -contains $_.InterfaceIndex
        }
    )

    $internetProfiles = @(
        $matchingProfiles |
        Where-Object {
            Test-ProfileHasInternet $_
        }
    )

    if ($internetProfiles.Count -gt 0) {

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

function Get-NetworkSpeedResult($monitorMode, $adapterResult) {

    try {

        $counter = Get-Counter '\Network Interface(*)\Bytes Total/sec' -ErrorAction Stop

        $validSamples = @(
            $counter.CounterSamples |
            Where-Object {
                $null -ne $_.CookedValue -and
                $_.CookedValue -ge 0
            }
        )

        if ($validSamples.Count -eq 0) {

            return [PSCustomObject]@{
                Status = "CounterUnavailable"
                SpeedKBps = $null
            }
        }

        # All Interfaces:
        # sum every valid network-interface counter sample.

        if ($monitorMode -eq "All") {

            $totalBytesPerSecond = (
                $validSamples |
                Measure-Object -Property CookedValue -Sum
            ).Sum

            return [PSCustomObject]@{
                Status = "OK"
                SpeedKBps = [math]::Round(($totalBytesPerSecond / 1024), 2)
            }
        }

        # Wi-Fi and Ethernet:
        # monitor only active physical matching adapters.

        if ($adapterResult.Status -ne "OK") {

            return [PSCustomObject]@{
                Status = $adapterResult.Status
                SpeedKBps = $null
            }
        }

        $filteredSamples = @()

        foreach ($sample in $validSamples) {

            foreach ($adapter in $adapterResult.Adapters) {

                if (Test-CounterSampleMatchesAdapter $sample $adapter) {

                    $filteredSamples += $sample
                    break
                }
            }
        }

        if ($filteredSamples.Count -eq 0) {

            return [PSCustomObject]@{
                Status = "CounterUnavailable"
                SpeedKBps = $null
            }
        }

        $totalBytesPerSecond = (
            $filteredSamples |
            Measure-Object -Property CookedValue -Sum
        ).Sum

        return [PSCustomObject]@{
            Status = "OK"
            SpeedKBps = [math]::Round(($totalBytesPerSecond / 1024), 2)
        }
    }
    catch {

        # Windows occasionally returns an invalid performance-counter sample.
        # Ignore it and allow the loop to retry safely.

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

function Wait-ForCancelKey($milliseconds) {

    $elapsedMilliseconds = 0

    while ($elapsedMilliseconds -lt $milliseconds) {

        if ([Console]::KeyAvailable) {

            $key = [Console]::ReadKey($true)

            if ($key.Key -eq "A") {

                return $true
            }
        }

        Start-Sleep -Milliseconds 100
        $elapsedMilliseconds += 100
    }

    return $false
}

# ==============================
# SETTINGS MENU
# ==============================

function Show-Settings {

    $originalSettings = Load-Settings

    if ($script:SettingsReadFailed) {

        Clear-Host

        Write-AppTitle

        Write-Host "Unable to read settings.ini." -ForegroundColor Red
        Write-Host "Settings cannot be edited until the file can be accessed."

        Wait-ForAnyKey

        return
    }

    $settings = @{
        ThresholdKBps = $originalSettings.ThresholdKBps
        CountdownSeconds = $originalSettings.CountdownSeconds
        MonitorMode = $originalSettings.MonitorMode
    }

    Clear-Host

    Write-AppTitle

    Write-SettingsWarning

    Write-Host ""
    Write-Host "Current threshold: $($settings.ThresholdKBps) KB/s"

    $new = Read-Host "Enter a new value or press Enter to keep"
    $newValue = ConvertTo-PositiveInteger $new

    if ($null -ne $newValue) {

        $settings.ThresholdKBps = $newValue
    }

    Write-Host ""
    Write-Host "Current shutdown delay: $($settings.CountdownSeconds) sec"

    $new = Read-Host "Enter a new value or press Enter to keep"
    $newValue = ConvertTo-PositiveInteger $new

    if ($null -ne $newValue) {

        $settings.CountdownSeconds = $newValue
    }

    Write-Host ""
    Write-Host "Network:"
    Write-Host ""
    Write-Host "[1] All Interfaces"
    Write-Host "[2] Wi-Fi"
    Write-Host "[3] Ethernet"
    Write-Host ""

    $currentNetworkName =
        Get-MonitorModeDisplayName $settings.MonitorMode

    Write-Host "Current network: $currentNetworkName"

    $newMonitorMode =
        Read-Host "Enter number or press Enter to keep"

    switch ($newMonitorMode) {

        "" {
            # Keep the current setting.
        }

        "1" {
            $settings.MonitorMode = "All"
        }

        "2" {
            $settings.MonitorMode = "WiFi"
        }

        "3" {
            $settings.MonitorMode = "Ethernet"
        }

        default {

            Write-Host ""
            Write-Host "Invalid network selection. Keeping the current setting." -ForegroundColor Red
        }
    }

    $settingsChanged =
        -not (Test-SettingsMatch $settings $originalSettings)

    if ($settingsChanged) {

        if (Save-Settings $settings) {

            Write-Host ""
            Write-Host "Settings updated."
        }
        else {

            Write-SettingsOperationError
        }
    }

    Wait-ForAnyKey
}

# ==============================
# MONITORING SCREEN
# ==============================

function Show-MonitoringScreen {

    param (
        $settings,
        [string]$speedText,
        [string]$statusText,
        [ConsoleColor]$statusColor,
        [bool]$showCancel,
        [bool]$shutdownPending,
        [int]$remainingSeconds,
        [string]$errorMessage
    )

    Clear-Host

    Write-AppTitle

    $networkName =
        Get-MonitorModeDisplayName $settings.MonitorMode

    Write-Host "Threshold      : $($settings.ThresholdKBps) KB/s"
    Write-Host "Network        : $networkName"
    Write-Host "Speed          : $speedText"

    Write-Host "Status         : " -NoNewline
    Write-Host $statusText -ForegroundColor $statusColor

    Write-Host ""

    if ($shutdownPending) {

        Write-Host "Low network activity detected."
        Write-Host "Windows shutdown in $remainingSeconds seconds."
        Write-Host ""
    }

    if (-not [string]::IsNullOrWhiteSpace($errorMessage)) {

        Write-Host $errorMessage -ForegroundColor Red
        Write-Host ""
    }

    if ($showCancel) {

        Write-Host "Press A to cancel."
    }
}

# ==============================
# MONITORING LOOP
# ==============================

function Start-Monitoring {

    $settings = Load-Settings

    # Do not silently monitor with unexpected defaults
    # if an existing override file cannot be read.

    if ($script:SettingsReadFailed) {

        Clear-Host

        Write-AppTitle

        Write-Host "Unable to read settings.ini." -ForegroundColor Red
        Write-Host "Monitoring cannot start until the file can be accessed."

        Wait-ForAnyKey

        return
    }

    $requiredSamples = 5
    $samples = @()

    $shutdownPending = $false
    $shutdownStopwatch = $null
    $lastShutdownAttemptTime = $null
    $shutdownErrorMessage = ""

    $counterAvailabilityStopwatch =
        [System.Diagnostics.Stopwatch]::StartNew()

    $connectionIssueStopwatch = $null

    Show-MonitoringScreen `
        -settings $settings `
        -speedText "Calculating..." `
        -statusText "Calibrating" `
        -statusColor Yellow `
        -showCancel $false `
        -shutdownPending $false `
        -remainingSeconds 0 `
        -errorMessage ""

    try {

        while ($true) {

            # Query selected adapters only once per monitoring cycle.
            # All connection and speed checks reuse this result.

            $adapterResult =
                Get-SelectedAdapterResult $settings.MonitorMode

            # ==========================================
            # INTERNET CONNECTION CHECK
            # ==========================================

            $connectionResult =
                Get-InternetConnectionResult `
                    $settings.MonitorMode `
                    $adapterResult

            if ($connectionResult.Status -ne "Online") {

                # Never keep a shutdown queued if internet
                # access is unavailable or cannot be verified.

                if ($shutdownPending) {

                    shutdown.exe /a 2>$null | Out-Null

                    $shutdownPending = $false
                    $shutdownStopwatch = $null
                }

                # Discard stale speed samples.
                # Recalibrate when the connection returns.

                $samples = @()

                $counterAvailabilityStopwatch.Restart()

                if ($null -eq $connectionIssueStopwatch) {

                    $connectionIssueStopwatch =
                        [System.Diagnostics.Stopwatch]::StartNew()
                }

                $networkName =
                    Get-MonitorModeDisplayName $settings.MonitorMode

                switch ($connectionResult.Status) {

                    "NoMatchingInterface" {

                        $speedText = "Unavailable"
                        $statusText =
                            "No active $networkName interface"
                    }

                    "AdapterDataUnavailable" {

                        $speedText = "Unavailable"
                        $statusText =
                            "Waiting for interface data"
                    }

                    "ConnectionDataUnavailable" {

                        $speedText = "Unavailable"
                        $statusText =
                            "Waiting for network status"
                    }

                    default {

                        $speedText = "Unavailable"

                        if (
                            $connectionIssueStopwatch.Elapsed.TotalSeconds `
                            -ge 5
                        ) {
                            $statusText =
                                "No internet connection"
                        }
                        else {

                            $statusText =
                                "Checking network connection"
                        }
                    }
                }

                Show-MonitoringScreen `
                    -settings $settings `
                    -speedText $speedText `
                    -statusText $statusText `
                    -statusColor Yellow `
                    -showCancel $true `
                    -shutdownPending $false `
                    -remainingSeconds 0 `
                    -errorMessage ""

                if (Wait-ForCancelKey 1000) {

                    return
                }

                continue
            }

            # Internet access has returned.
            # Recalibrate using fresh speed samples.

            if ($null -ne $connectionIssueStopwatch) {

                $connectionIssueStopwatch.Stop()
                $connectionIssueStopwatch = $null

                $samples = @()
                $counterAvailabilityStopwatch.Restart()
            }

            # ==========================================
            # SPEED COUNTER CHECK
            # ==========================================

            $result =
                Get-NetworkSpeedResult `
                    $settings.MonitorMode `
                    $adapterResult

            if ($result.Status -eq "NoMatchingInterface") {

                if ($shutdownPending) {

                    shutdown.exe /a 2>$null | Out-Null

                    $shutdownPending = $false
                    $shutdownStopwatch = $null
                }

                $samples = @()
                $counterAvailabilityStopwatch.Restart()

                $networkName =
                    Get-MonitorModeDisplayName $settings.MonitorMode

                Show-MonitoringScreen `
                    -settings $settings `
                    -speedText "Unavailable" `
                    -statusText "No active $networkName interface" `
                    -statusColor Yellow `
                    -showCancel $true `
                    -shutdownPending $false `
                    -remainingSeconds 0 `
                    -errorMessage ""

                if (Wait-ForCancelKey 1000) {

                    return
                }

                continue
            }

            if ($result.Status -ne "OK") {

                if (
                    $counterAvailabilityStopwatch.Elapsed.TotalSeconds `
                    -ge 5
                ) {
                    # Fail-safe:
                    # never keep shutdown queued if speed data
                    # has been unavailable for several seconds.

                    if ($shutdownPending) {

                        shutdown.exe /a 2>$null | Out-Null

                        $shutdownPending = $false
                        $shutdownStopwatch = $null
                    }

                    $samples = @()

                    Show-MonitoringScreen `
                        -settings $settings `
                        -speedText "Unavailable" `
                        -statusText "Waiting for network data" `
                        -statusColor Yellow `
                        -showCancel $true `
                        -shutdownPending $false `
                        -remainingSeconds 0 `
                        -errorMessage ""

                    if (Wait-ForCancelKey 250) {

                        return
                    }
                }
                else {

                    Start-Sleep -Milliseconds 250
                }

                continue
            }

            # Valid network-speed reading received.

            $counterAvailabilityStopwatch.Restart()

            $samples += $result.SpeedKBps

            if ($samples.Count -gt $requiredSamples) {

                $samples =
                    $samples[-$requiredSamples..-1]
            }

            # ==========================================
            # CALIBRATION
            # ==========================================

            if ($samples.Count -lt $requiredSamples) {

                Show-MonitoringScreen `
                    -settings $settings `
                    -speedText "Calculating... ($($samples.Count)/$requiredSamples)" `
                    -statusText "Calibrating" `
                    -statusColor Yellow `
                    -showCancel $false `
                    -shutdownPending $false `
                    -remainingSeconds 0 `
                    -errorMessage ""

                Start-Sleep -Seconds 1

                continue
            }

            # ==========================================
            # ROLLING AVERAGE
            # ==========================================

            $averageSpeed = [math]::Round(
                (($samples | Measure-Object -Average).Average),
                2
            )

            $displaySpeed =
                Format-Speed $averageSpeed

            # ==========================================
            # SHUTDOWN LOGIC
            # ==========================================

            if ($averageSpeed -lt $settings.ThresholdKBps) {

                if (-not $shutdownPending) {

                    $canAttemptShutdown = (
                        $null -eq $lastShutdownAttemptTime -or
                        ((Get-Date) - $lastShutdownAttemptTime).TotalSeconds `
                        -ge 5
                    )

                    if ($canAttemptShutdown) {

                        $lastShutdownAttemptTime = Get-Date

                        shutdown.exe `
                            /s `
                            /t $settings.CountdownSeconds `
                            /c "Low network activity detected." `
                            2>$null |
                            Out-Null

                        $shutdownExitCode = $LASTEXITCODE

                        if ($shutdownExitCode -eq 0) {

                            $shutdownPending = $true

                            $shutdownStopwatch =
                                [System.Diagnostics.Stopwatch]::StartNew()

                            $shutdownErrorMessage = ""
                        }
                        else {

                            $shutdownPending = $false
                            $shutdownStopwatch = $null

                            $shutdownErrorMessage =
                                "Unable to schedule shutdown. Windows returned error code $shutdownExitCode."
                        }
                    }
                }
            }
            else {

                $shutdownErrorMessage = ""

                if ($shutdownPending) {

                    shutdown.exe /a 2>$null | Out-Null

                    $shutdownPending = $false
                    $shutdownStopwatch = $null
                }
            }

            # ==========================================
            # DISPLAY LIVE STATUS
            # ==========================================

            if ($shutdownPending) {

                $remainingSeconds = [math]::Max(
                    0,
                    [math]::Ceiling(
                        $settings.CountdownSeconds -
                        $shutdownStopwatch.Elapsed.TotalSeconds
                    )
                )

                Show-MonitoringScreen `
                    -settings $settings `
                    -speedText $displaySpeed `
                    -statusText "Shutdown pending" `
                    -statusColor Red `
                    -showCancel $true `
                    -shutdownPending $true `
                    -remainingSeconds $remainingSeconds `
                    -errorMessage $shutdownErrorMessage
            }
            else {

                Show-MonitoringScreen `
                    -settings $settings `
                    -speedText $displaySpeed `
                    -statusText "Monitoring" `
                    -statusColor Green `
                    -showCancel $true `
                    -shutdownPending $false `
                    -remainingSeconds 0 `
                    -errorMessage $shutdownErrorMessage
            }

            if (Wait-ForCancelKey 1000) {

                return
            }
        }
    }
    finally {

        # Safety net:
        # cancel a queued shutdown if monitoring exits unexpectedly.

        if ($shutdownPending) {

            shutdown.exe /a 2>$null | Out-Null
        }

        if ($null -ne $shutdownStopwatch) {

            $shutdownStopwatch.Stop()
        }

        if ($null -ne $connectionIssueStopwatch) {

            $connectionIssueStopwatch.Stop()
        }
    }
}

# ==============================
# MAIN MENU
# ==============================

while ($true) {

    $settings = Load-Settings

    Clear-Host

    Write-AppTitle

    if ($script:SettingsReadFailed) {

        Write-Host "Threshold      : Unavailable"
        Write-Host "Shutdown delay : Unavailable"
        Write-Host "Network        : Unavailable"
    }
    else {

        $networkName =
            Get-MonitorModeDisplayName $settings.MonitorMode

        Write-Host "Threshold      : $($settings.ThresholdKBps) KB/s"
        Write-Host "Shutdown delay : $($settings.CountdownSeconds) sec"
        Write-Host "Network        : $networkName"
    }

    Write-SettingsWarning

    Write-Host ""
    Write-Host "[1] Start Monitoring"
    Write-Host "[2] Settings"
    Write-Host "[3] Reset Settings"
    Write-Host "[4] Exit"
    Write-Host ""

    $choice = Read-Host "Enter number"

    switch ($choice) {

        "1" {

            Start-Monitoring
        }

        "2" {

            Show-Settings
        }

        "3" {

            $confirm =
                Read-Host "Reset all settings to defaults? (Y/N)"

            if ($confirm -match '^[Yy]$') {

                if (-not (Reset-Settings)) {

                    Write-SettingsOperationError

                    Wait-ForAnyKey
                }
            }
        }

        "4" {

            exit
        }

        default {

            Write-Host ""
            Write-Host "Invalid selection. Please enter 1, 2, 3 or 4." -ForegroundColor Red

            Wait-ForAnyKey
        }
    }
}