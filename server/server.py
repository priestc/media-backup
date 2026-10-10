from __future__ import annotations
from flask import Flask, request, jsonify, abort
from pathlib import Path
from datetime import datetime
import hmac
import logging
import os
import secrets
import tempfile

app = Flask(__name__)
log = logging.getLogger("media-backup")
_upload_dir: Path = Path.home() / "media-backup-files"
_api_key_file: Path = Path.home() / ".config" / "media-backup" / "api_key"



def load_api_key(path: Path) -> str | None:
    try:
        return path.read_text().strip() or None
    except OSError:
        return None


def create_api_key(path: Path) -> str:
    """Write a new random API key to `path`, readable only by the owner."""
    key = secrets.token_urlsafe(32)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(key + "\n")
    os.chmod(path, 0o600)
    return key


def _auth():
    """Requests carry the API key that `media-backup pair` shows as a QR code.
    The file is read each time, so pairing doesn't need a restart."""
    header = request.headers.get("Authorization", "")
    key = load_api_key(_api_key_file)
    if key is None or not header.startswith("Bearer ") or \
            not hmac.compare_digest(header[7:].strip().encode(), key.encode()):
        log.warning("refused %s %s: %s", request.method, request.path,
                    "no API key on server" if key is None else "wrong or missing API key")
        abort(401)


def _safe_segment(name: str) -> str:
    name = name.strip()
    if not name or name in (".", "..") or "/" in name or "\\" in name:
        abort(400)
    return name


def _size(path: Path) -> str:
    return f"{path.stat().st_size / 1_048_576:.1f} MB"


@app.post("/upload")
def upload():
    _auth()
    if "file" not in request.files:
        return jsonify({"error": "no file field"}), 400

    f = request.files["file"]
    filename = (request.form.get("filename") or f.filename or "unknown").strip()
    taken_at = request.form.get("taken_at", "")
    device   = request.form.get("device_name", "unknown")

    try:
        dt = datetime.fromisoformat(taken_at)
    except (ValueError, TypeError):
        dt = datetime.now()

    # Organise by device / date
    dest_dir = _upload_dir / device / dt.strftime("%Y/%m/%d")
    dest_dir.mkdir(parents=True, exist_ok=True)

    dest = dest_dir / filename
    if dest.exists():
        stem, suffix = Path(filename).stem, Path(filename).suffix
        i = 1
        while dest.exists():
            dest = dest_dir / f"{stem}_{i}{suffix}"
            i += 1

    f.save(dest)
    rel = str(dest.relative_to(_upload_dir))
    log.info("stored %s (%s)", rel, _size(dest))
    return jsonify({"ok": True, "path": rel})


@app.put("/files/<device>/<filename>")
def put_file(device: str, filename: str):
    """Raw-body upload used by the iOS background upload extension.
    Stores at <upload-dir>/<device>/<filename> — the same layout as SFTP uploads,
    so a file already uploaded either way is skipped."""
    _auth()
    dest_dir = _upload_dir / _safe_segment(device)
    dest = dest_dir / _safe_segment(filename)
    if dest.exists():
        log.info("skipped %s/%s (already stored)", device, filename)
        return jsonify({"ok": True, "skipped": True}), 200

    dest_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dest_dir, prefix=".upload-")
    try:
        with os.fdopen(fd, "wb") as out:
            while chunk := request.stream.read(1 << 20):
                out.write(chunk)
        os.replace(tmp, dest)
    except BaseException:
        os.unlink(tmp)
        log.warning("upload of %s/%s failed partway", device, filename)
        raise
    log.info("stored %s/%s (%s)", device, filename, _size(dest))
    return jsonify({"ok": True, "path": str(dest.relative_to(_upload_dir))}), 201


@app.delete("/files/<device>/<filename>")
def delete_file(device: str, filename: str):
    """Delete a file the device removed from its photo library. Missing files are fine."""
    _auth()
    dest = _upload_dir / _safe_segment(device) / _safe_segment(filename)
    try:
        dest.unlink()
    except FileNotFoundError:
        log.info("delete %s/%s: not on server", device, filename)
        return jsonify({"ok": True, "missing": True}), 200
    log.info("deleted %s/%s", device, filename)
    return jsonify({"ok": True}), 200


@app.post("/files/<device>")
def files_present(device: str):
    """Which of the given filenames (JSON body {"filenames": [...]}) are stored for this device."""
    _auth()
    dest_dir = _upload_dir / _safe_segment(device)
    names = (request.get_json(silent=True) or {}).get("filenames") or []
    present = [n for n in names
               if isinstance(n, str) and n and "/" not in n and "\\" not in n
               and n not in (".", "..") and (dest_dir / n).is_file()]
    return jsonify({"present": present})


@app.get("/check")
def check():
    """Check whether a filename already exists under any date directory."""
    _auth()
    filename = request.args.get("filename", "").strip()
    if not filename:
        return jsonify({"exists": False})
    device = request.args.get("device_name", "").strip()
    search_root = _upload_dir / device if device else _upload_dir
    exists = any(True for _ in search_root.rglob(filename))
    return jsonify({"exists": exists})


@app.get("/status")
def status():
    _auth()
    files = list(_upload_dir.rglob("*"))
    file_count = sum(1 for f in files if f.is_file())
    size_mb = sum(f.stat().st_size for f in files if f.is_file()) / 1_048_576
    return jsonify({"files": file_count, "size_mb": round(size_mb, 1), "upload_dir": str(_upload_dir)})


def run(upload_dir: str, api_key_file: str, host: str = "0.0.0.0", port: int = 8765,
        cert: str | None = None, key: str | None = None) -> None:
    global _upload_dir, _api_key_file
    # stderr is unbuffered, so lines reach journalctl immediately
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    _upload_dir = Path(upload_dir)
    _upload_dir.mkdir(parents=True, exist_ok=True)
    _api_key_file = Path(api_key_file)
    app.run(host=host, port=port, ssl_context=(cert, key) if cert else None, threaded=True)
