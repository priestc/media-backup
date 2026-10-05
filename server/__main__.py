from __future__ import annotations
from pathlib import Path
import click


@click.group()
def main():
    """Media backup server — receives photos and videos from iOS/Android."""


@main.command()
@click.option("--upload-dir", default=str(Path.home() / "media-backup-files"), show_default=True,
              help="Directory where uploaded files are stored. Use the same path as the "
                   "app's SFTP 'Remote Path' so files uploaded either way are de-duplicated.")
@click.option("--authorized-keys", default=str(Path.home() / ".ssh" / "authorized_keys"), show_default=True,
              help="Devices whose SSH public key is listed here may upload.")
@click.option("--host", default="0.0.0.0", show_default=True)
@click.option("--port", default=8765, show_default=True)
@click.option("--cert", type=click.Path(exists=True, dir_okay=False), help="TLS certificate (enables HTTPS).")
@click.option("--key", type=click.Path(exists=True, dir_okay=False), help="TLS private key.")
def serve(upload_dir, authorized_keys, host, port, cert, key):
    """Start the upload server."""
    if bool(cert) != bool(key):
        raise click.UsageError("--cert and --key must be given together.")
    from server.server import run
    scheme = "https" if cert else "http"
    click.echo(f"Serving on {scheme}://{host}:{port}  →  {upload_dir}")
    click.echo(f"Accepting uploads from keys in {authorized_keys}")
    run(upload_dir=upload_dir, authorized_keys=authorized_keys, host=host, port=port, cert=cert, key=key)


if __name__ == "__main__":
    main()
