from __future__ import annotations
from pathlib import Path
import sys
import click

CONFIG_DIR = Path.home() / ".config" / "media-backup"
CONFIG_FILE = CONFIG_DIR / "config.json"
DEFAULT_API_KEY_FILE = str(CONFIG_DIR / "api_key")


def load_config() -> dict:
    import json
    try:
        return json.loads(CONFIG_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_config(config: dict) -> None:
    import json
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(config, indent=2) + "\n")


@click.group()
def main():
    """Media backup server — receives photos and videos from iOS/Android."""


@main.command()
@click.option("--upload-dir", help="Where uploaded photos and videos are stored. Asked for if "
                                   "not given. Point Android's SFTP Remote Path here too.")
def setup(upload_dir):
    """Run once after installing: choose where uploads are stored and create the API key."""
    from server.server import create_api_key, load_api_key
    config = load_config()
    if upload_dir is None:
        upload_dir = click.prompt("Where should uploaded photos and videos be stored?",
                                  default=config.get("upload_dir", str(Path.home() / "media-backup-files")))
    path = Path(upload_dir).expanduser().resolve()
    if not path.is_dir():
        if not click.confirm(f"{path} doesn't exist. Create it?", default=True):
            raise click.Abort()
        path.mkdir(parents=True)
    import os
    if not os.access(path, os.W_OK):
        raise click.ClickException(f"{path} isn't writable by this user.")

    config["upload_dir"] = str(path)
    save_config(config)
    click.echo(f"Uploads will be stored in {path}  (saved to {CONFIG_FILE})")
    if load_api_key(Path(DEFAULT_API_KEY_FILE)) is None:
        create_api_key(Path(DEFAULT_API_KEY_FILE))
        click.echo(f"Created an API key in {DEFAULT_API_KEY_FILE}")
    click.echo("Next: start `media-backup serve`, then run `media-backup pair` and scan the code "
               "in the app.")


@main.command()
@click.option("--upload-dir", help="Override the upload directory chosen in `media-backup setup`.")
@click.option("--api-key-file", default=DEFAULT_API_KEY_FILE, show_default=True,
              help="API key apps must send; created by `media-backup setup`.")
@click.option("--host", default="0.0.0.0", show_default=True)
@click.option("--port", default=8765, show_default=True)
@click.option("--cert", type=click.Path(exists=True, dir_okay=False), help="TLS certificate (enables HTTPS).")
@click.option("--key", type=click.Path(exists=True, dir_okay=False), help="TLS private key.")
def serve(upload_dir, api_key_file, host, port, cert, key):
    """Start the upload server."""
    if bool(cert) != bool(key):
        raise click.UsageError("--cert and --key must be given together.")
    from server.server import run, load_api_key
    upload_dir = upload_dir or load_config().get("upload_dir")
    if not upload_dir:
        raise click.UsageError("No upload directory configured. Run `media-backup setup` first.")
    scheme = "https" if cert else "http"
    click.echo(f"Serving on {scheme}://{host}:{port}  →  {upload_dir}")
    if load_api_key(Path(api_key_file)) is None:
        click.echo(f"No API key at {api_key_file}; all requests are refused until you run "
                   "`media-backup pair`.", err=True)
    run(upload_dir=upload_dir, api_key_file=api_key_file, host=host, port=port, cert=cert, key=key)


@main.command()
@click.option("--api-key-file", default=DEFAULT_API_KEY_FILE, show_default=True,
              help="Where the API key is stored (must match `serve`).")
@click.option("--new", "rotate", is_flag=True,
              help="Replace the existing key. Every phone must then scan the new code.")
def pair(api_key_file, rotate):
    """Show the API key as a QR code to scan in the app (Settings → Scan Pairing QR Code).
    Creates the key on first run."""
    from urllib.parse import urlencode
    import qrcode
    from server.server import create_api_key, load_api_key
    path = Path(api_key_file)
    key = None if rotate else load_api_key(path)
    if key is None:
        key = create_api_key(path)
        click.echo(f"Created a new API key in {path}")

    qr = qrcode.QRCode(border=2)
    qr.add_data("media-backup://pair?" + urlencode({"key": key}))
    qr.make(fit=True)
    if sys.stdout.isatty():
        qr.print_ascii(tty=True)   # forces black-on-white whatever the terminal theme
    else:
        qr.print_ascii(invert=True)
    click.echo("In the iOS app: Settings → Scan Pairing QR Code.")


if __name__ == "__main__":
    main()
