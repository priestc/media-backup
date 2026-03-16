from __future__ import annotations
from flask import Flask, request, jsonify, abort
from pathlib import Path
from datetime import datetime

app = Flask(__name__)
_upload_dir: Path = Path.home() / "media-backup-files"
_api_key: str = ""


def _auth():
    key = request.headers.get("Authorization", "")
    if not key.startswith("Bearer ") or key[7:] != _api_key:
        abort(401)


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


def run(upload_dir: str, api_key: str, host: str = "0.0.0.0", port: int = 8765) -> None:
    global _upload_dir, _api_key
    _upload_dir = Path(upload_dir)
    _upload_dir.mkdir(parents=True, exist_ok=True)
    _api_key = api_key
    app.run(host=host, port=port)
