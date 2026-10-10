# media-backup

Automatic photo and video backup from iOS and Android to your NAS or home server.

- Photos and videos are uploaded over your local network (or Tailscale when away)
- Files are organized in one folder per device: `DeviceName/filename`
- Duplicate uploads are skipped automatically
- Android backs up new photos and videos automatically as soon as they are taken (plus an hourly catch-up)
- iOS (27+) backs up new photos and videos automatically soon after they are taken, via Apple's Photos background upload extension; **Start Backup** in the app catches up on older photos

---

## Server Setup (NAS / Linux machine)

### Requirements

- Python 3.9+
- `pipx`

### Install

```bash
pipx install git+https://github.com/priestc/media-backup.git
```

### Authentication

The HTTP(S) API uses an API key. Create it and show it as a QR code in the terminal with:

```bash
media-backup pair
```

Then in the iOS app tap the **gear icon** → **Scan Pairing QR Code**. Running `pair` again
shows the same key (to pair another phone); `media-backup pair --new` replaces it, after which
every phone must scan the new code. The key is stored in `~/.config/media-backup/api_key`
(mode 600); point both commands elsewhere with `--api-key-file`. The server re-reads the file
on every request, so no restart is needed after pairing.

SFTP (the apps' **Start Backup** / **Backup Now**) is separate: each phone shows an SSH public
key in its settings; add it to `~/.ssh/authorized_keys` on the server.

### Start the server

```bash
media-backup serve
```

By default this listens on `0.0.0.0:8765` and stores files in `~/media-backup-files/`.

Options:

```bash
media-backup serve --upload-dir /mnt/nas/photos --port 8765
```

Set `--upload-dir` to the same path as the app's SFTP **Remote Path**, so a file uploaded over
either SFTP or HTTPS lands in the same `<device>/<filename>` place and is never uploaded twice.

### HTTPS (required for iOS automatic upload)

iOS only performs background uploads over HTTPS with a trusted certificate. The easiest way is
Tailscale, which gives the server a real certificate (the phone must have Tailscale on):

```bash
sudo tailscale serve --bg 8765
```

The server is then reachable at `https://<server-name>.<tailnet>.ts.net`. Alternatively pass your
own certificate with `media-backup serve --cert cert.pem --key key.pem`.

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

1. In Xcode, select the **MediaBackup** project → **Build Settings** → set
   `BACKGROUND_UPLOAD_URL_BASE` to your server's HTTPS URL (e.g. `https://nas.tail1234.ts.net`).
   iOS refuses background uploads to anywhere outside this URL, so it is fixed at build time.
2. Build and run on your iPhone (the app group `group.io.github.priestc.MediaBackup` is
   registered automatically with automatic signing)
3. Tap the **gear icon** → enter Local IP, Tailscale IP, username and Remote Path; add the
   shown public key to `~/.ssh/authorized_keys` on the server → tap **Test Connection**
4. Run `media-backup pair` on the server and tap **Scan Pairing QR Code** in the app's settings
5. Tap **Start Backup** and allow **Full Access** to photos — this uploads everything not yet
   backed up over SFTP, and switches on automatic upload
6. From then on, iOS uploads each new photo and video in the background (iOS decides exactly
   when, based on battery and network). Settings → **Automatic Upload** shows the status.

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
2. Tap the **gear icon** → enter Local IP, Tailscale IP, username and Remote Path, and add the
   shown public key to `~/.ssh/authorized_keys` on the server
3. Tap **Backup Now** to run an immediate backup
4. From then on, each new photo or video is uploaded automatically within about 30 seconds of
   being taken (even with the app closed), with an hourly catch-up run as a safety net

---

## File Organization

Uploaded files are stored under the upload directory like this:

```
~/media-backup-files/
  iPhone/
    IMG_1234.HEIC
    IMG_1235.MOV
  Pixel 9/
    PXL_20260316_123456.jpg
```

---

## API

The server exposes a simple HTTP API on port 8765:

| Endpoint | Method | Description |
|---|---|---|
| `/files/<device>/<filename>` | PUT | Upload a file as the raw request body (skipped if it already exists) |
| `/files/<device>/<filename>` | DELETE | Delete a file (succeeds if already gone) |
| `/files/<device>` | POST | JSON `{"filenames": [...]}` → `{"present": [...]}`, the ones stored |
| `/upload` | POST | Upload a file (multipart form) |
| `/status` | GET | File count and total size |
| `/check?filename=X` | GET | Check if a filename already exists |

All endpoints require `Authorization: Bearer <api key>`, the key from `media-backup pair`.

---

## Upgrading

```bash
pipx install git+https://github.com/priestc/media-backup.git --force
```
