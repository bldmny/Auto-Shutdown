# Auto Shutdown

Auto Shutdown is a lightweight Windows utility that monitors network activity and performs an action when your download or upload appears to have finished.

It is designed for leaving your PC running while files download or upload. When network activity stays below your chosen threshold, Auto Shutdown starts an operation delay. If network activity rises again during that delay, the pending action is cancelled automatically.

![Auto Shutdown interface](screenshot.png)

## Features

* Clickable Windows GUI with light and dark themes
* Monitors downloads, uploads, or both
* Supports all interfaces, Wi-Fi, or Ethernet
* Shows current network speed and live status
* Starts a visible operation delay when activity drops below your threshold
* Cancels the pending operation automatically if activity resumes
* Supports shutdown, restart, sleep, and lock
* Keeps Windows awake while monitoring is active
* Saves settings automatically in `settings.ini`
* Includes safeguards for unreadable settings, connection issues, and unavailable network data
* Uses a per-user installer location by default, so settings can be saved without administrator access

## Installation

Download the latest installer from the **Releases** section and run:

```text
AutoShutdownSetup-v1.1.exe
```

The installer defaults to:

```text
%LOCALAPPDATA%\Programs\Auto Shutdown
```

You can choose a different install location during setup.

## Usage

1. Open Auto Shutdown.
2. Click **Start Monitoring**.
3. Leave the utility running while your download or upload continues.
4. If you want to cancel monitoring or stop a pending operation, click **Stop**.

When network activity remains below your configured threshold, Auto Shutdown begins the operation delay. If activity rises again before the delay finishes, the pending operation is cancelled and monitoring continues.

## Settings

Open **Settings** to configure:

* **Threshold** - how low network activity must fall before the operation delay begins
* **Operation delay** - how long Auto Shutdown waits before performing the selected operation
* **Monitor** - downloads, uploads, or both
* **Operation** - shutdown, restart, sleep, or lock
* **Network** - all interfaces, Wi-Fi, or Ethernet

Threshold units support `KB/s`, `MB/s`, and `GB/s`.

Operation delay units support seconds, minutes, and hours.

## Note

Auto Shutdown monitors network activity rather than detecting individual downloads or uploads directly. Other background internet activity may affect when the operation delay begins or cancels.

## License

This project is licensed under the MIT License.
