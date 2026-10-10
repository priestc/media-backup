from __future__ import annotations
from pathlib import Path
import sys
import click

DEFAULT_API_KEY_FILE = str(Path.home() / ".config" / "media-backup" / "api_key")


@click.group()
def main():
    """Media backup server — receives photos and videos from iOS/Android."""


@main.command()
@click.option("--upload-dir", default=str(Path.home() / "media-backup-files"), show_default=True,
              help="Directory where uploaded files are stored. Use the same path as the "
                   "app's SFTP 'Remote Path' so files uploaded either way are de-duplicated.")
@click.option("--api-key-file", default=DEFAULT_API_KEY_FILE, show_default=True,
              help="API key apps must send; create it with `media-backup pair`.")
@click.option("--host", default="0.0.0.0", show_default=True)
@click.option("--port", default=8765, show_default=True)
@click.option("--cert", type=click.Path(exists=True, dir_okay=False), help="TLS certificate (enables HTTPS).")
@click.option("--key", type=click.Path(exists=True, dir_okay=False), help="TLS private key.")
def serve(upload_dir, api_key_file, host, port, cert, key):
    """Start the upload server."""
    if bool(cert) != bool(key):
        raise click.UsageError("--cert and --key must be given together.")
    from server.server import run, load_api_key
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
    import qrcode
    from server.server import PAIRING_PREFIX, create_api_key, load_api_key
    path = Path(api_key_file)
    key = None if rotate else load_api_key(path)
    if key is None:
        key = create_api_key(path)
        click.echo(f"Created a new API key in {path}")

    qr = qrcode.QRCode(border=2)
    qr.add_data(PAIRING_PREFIX + key)
    qr.make(fit=True)
    if sys.stdout.isatty():
        qr.print_ascii(tty=True)   # forces black-on-white whatever the terminal theme
    else:
        qr.print_ascii(invert=True)
    click.echo("In the iOS app: Settings → Scan Pairing QR Code.")


if __name__ == "__main__":
    main()
