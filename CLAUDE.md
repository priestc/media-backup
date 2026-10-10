# media-backup

## Server: tank2

The server side of this project (`server/`, the `media-backup serve` command) runs on **tank2**,
not on this Mac. For tank2 itself (how to reach it over SSH, its LAN address, sudo setup, and how
other projects are deployed there), see the other CLAUDE.md files in `~/Documents/GitHub/`, e.g.
`../radioserver/CLAUDE.md`, `../smart-home/CLAUDE.md` and `../RoadtripApp/CLAUDE.md`.

- Reach it with `ssh tank2`.
- The server runs as the systemd service `media-backup.service` (enabled at boot, as user
  `chris`, `--upload-dir /mnt/md0/Tank2/Pictures`). Logs: `journalctl -u media-backup.service` (one line per
  file stored / skipped / deleted / refused; follow live with `ssh tank2 journalctl -u media-backup.service -f`).
- Deploy server changes by committing and pushing to `master`, then:
  ```
  ssh tank2 "pipx install --force git+https://github.com/priestc/media-backup.git && sudo -n systemctl restart media-backup.service"
  ```
  The restart is allowed without a password via `/etc/sudoers.d/media-backup`.
- HTTPS comes from Tailscale Serve (`sudo tailscale serve --bg 8765`), which proxies
  `https://tank2.tail418e84.ts.net` → `http://127.0.0.1:8765`. That URL is the
  `BACKGROUND_UPLOAD_URL_BASE` build setting in the iOS project; iOS refuses background uploads
  to any other host.
- The upload path is set with `media-backup setup` (saved in tank2's
  `~/.config/media-backup/config.json`). Files land in `<upload path>/<device>/<filename>`; the
  Android app's SFTP Remote Path must be set to the same path.
- HTTPS requests authenticate with an API key in tank2's `~/.config/media-backup/api_key`.
  `media-backup pair` (from here: `ssh tank2 /home/chris/.local/bin/media-backup pair`; non-interactive ssh
  has no `~/.local/bin` on PATH) prints it as
  a QR code that the iOS app scans in Settings. The iOS app uses only HTTPS (no SSH); the Android
  app uses SFTP with its SSH key in `~/.ssh/authorized_keys`.
- tank2 has been logged out of Tailscale before (key expiry); if `tailscale status` says
  "Logged out", run `sudo tailscale up` there.
