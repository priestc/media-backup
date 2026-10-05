from __future__ import annotations
from flask import Flask, request, jsonify, abort
from pathlib import Path
from datetime import datetime
import os
import tempfile

app = Flask(__name__)
_upload_dir: Path = Path.home() / "media-backup-files"
_authorized_keys: Path = Path.home() / ".ssh" / "authorized_keys"


def _key_id(line: str) -> tuple[str, str] | None:
    """(type, base64 blob) of an OpenSSH public key, ignoring options and comment."""
    parts = line.split()
    for i, part in enumerate(parts[:-1]):
        if part.startswith(("ssh-", "ecdsa-", "sk-")):
            return part, parts[i + 1]
    return None


def _auth():
    """The bearer token is the device's SSH public key, which must be in authorized_keys
    — the same key that grants SFTP access also grants HTTP upload access."""
    header = request.headers.get("Authorization", "")
    token = _key_id(header[7:]) if header.startswith("Bearer ") else None
    if token is None:
        abort(401)
    try:
        lines = _authorized_keys.read_text().splitlines()
    except OSError:
        abort(401)
    if not any(_key_id(line) == token for line in lines if not line.lstrip().startswith("#")):
        abort(401)


def _safe_segment(name: str) -> str:
    name = name.strip()
    if not name or name in (".", "..") or "/" in name or "\\" in name:
        abort(400)
    return name


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
        raise
    return jsonify({"ok": True, "path": str(dest.relative_to(_upload_dir))}), 201


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


def run(upload_dir: str, authorized_keys: str, host: str = "0.0.0.0", port: int = 8765,
        cert: str | None = None, key: str | None = None) -> None:
    global _upload_dir, _authorized_keys
    _upload_dir = Path(upload_dir)
    _upload_dir.mkdir(parents=True, exist_ok=True)
    _authorized_keys = Path(authorized_keys)
    app.run(host=host, port=port, ssl_context=(cert, key) if cert else None, threaded=True)
