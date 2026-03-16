# media-backup

Automatic photo and video backup from iOS and Android to your NAS or home server.

- Photos and videos are uploaded over your local network (or Tailscale when away)
- Files are organized by device name and date: `DeviceName/YYYY/MM/DD/filename`
- Duplicate uploads are skipped automatically
- Android backs up automatically every hour in the background
- iOS backs up when you open the app and tap Start

---

## Server Setup (NAS / Linux machine)

### Requirements

- Python 3.9+
- `pipx`

### Install

```bash
pipx install git+https://github.com/priestc/media-backup.git
```

### Generate an API key

```bash
media-backup setup
```

This prints an API key and saves it to `~/.config/media-backup/config.json`. Copy the key — you'll enter it in the app.

### Start the server

```bash
media-backup serve
```

By default this listens on `0.0.0.0:8765` and stores files in `~/media-backup-files/`.

Options:

```bash
media-backup serve --upload-dir /mnt/nas/photos --port 8765
```

### Run as a systemd service

Create `/etc/systemd/system/media-backup.service`:

```ini
[Unit]
Description=Media Backup Server
After=network.target

[Service]
User=chris
ExecStart=/home/chris/.local/bin/media-backup serve --upload-dir /mnt/nas/photos
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Then enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now media-backup.service
```

### Find your IP addresses

**Local IP:**
```bash
ip addr show | grep "inet " | grep -v 127
```

**Tailscale IP** (if using Tailscale):
```bash
ip addr show tailscale0 | grep "inet "
```

---

## iOS App Setup

### Requirements

- Xcode
- Apple Developer account
- iPhone (push notifications and photo library access don't work on simulator)

### Create the Xcode project

1. Open Xcode → **Create New Project** → **iOS → App**
2. Set:
   - Product Name: `MediaBackup`
   - Bundle Identifier: `com.yourname.mediabackup`
   - Interface: SwiftUI
   - Language: Swift
3. Save to `ios/` inside this repo
4. Replace the generated `ContentView.swift` and app entry point with the files from `ios/MediaBackup/`
5. Add `AppDelegate.swift`, `PhotoUploader.swift`, and `SettingsView.swift` via **File → Add Files**

### Add capabilities

In Xcode, select the project → target → **Signing & Capabilities**:

- Add **Photos Library** (should be automatic from Info.plist)

### Add to Info.plist

Add this key (right-click Info.plist → Open As → Source Code):

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Used to back up your photos and videos to your home server.</string>
```

### Configure and use

1. Build and run on your iPhone
2. Tap the **gear icon** → enter Local IP, Tailscale IP, and API key → tap **Test Connection**
3. Tap **Start Backup** — all photos and videos not yet backed up will upload
4. Progress is shown in real time; you can stop and resume at any time

---

## Android App Setup

### Requirements

- Android Studio
- Android phone (API 26+)

### Open the project

1. Open Android Studio → **Open** → select `android/MediaBackup/`
2. Let Gradle sync

### Configure and use

1. Build and run on your Android phone
2. Tap the **gear icon** → enter Local IP, Tailscale IP, and API key
3. Tap **Backup Now** to run an immediate backup
4. The app also schedules an **automatic hourly backup** in the background whenever the phone has a network connection — no further action needed

---

## File Organization

Uploaded files are stored under the upload directory like this:

```
~/media-backup-files/
  Chris's iPhone/
    2026/
      03/
        15/
          IMG_1234.HEIC
          IMG_1235.MOV
  Pixel 9/
    2026/
      03/
        16/
          PXL_20260316_123456.jpg
```

---

## API

The server exposes a simple HTTP API on port 8765:

| Endpoint | Method | Description |
|---|---|---|
| `/upload` | POST | Upload a file (multipart form) |
| `/status` | GET | File count and total size |
| `/check?filename=X` | GET | Check if a filename already exists |

All endpoints require `Authorization: Bearer <api_key>`.

---

## Upgrading

```bash
pipx install git+https://github.com/priestc/media-backup.git --force
```
