from __future__ import annotations
import json
import secrets
from pathlib import Path
import click

_CONFIG_FILE = Path.home() / ".config" / "media-backup" / "config.json"


def _load_config() -> dict:
    if _CONFIG_FILE.exists():
        try:
            with open(_CONFIG_FILE) as f:
                return json.load(f)
        except (json.JSONDecodeError, ValueError):
            pass
    return {}


def _save_config(cfg: dict) -> None:
    _CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(_CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)


@click.group()
def main():
    """Media backup server — receives photos and videos from iOS/Android."""


@main.command()
def setup():
    """Generate an API key and print setup instructions."""
    api_key = secrets.token_hex(16)
    _save_config({"api_key": api_key})
    click.echo(f"\nAPI key generated: {api_key}")
    click.echo(f"Saved to {_CONFIG_FILE}")
    click.echo("\nEnter this key in the iOS/Android app settings.")
    click.echo("Then run:  media-backup serve")


@main.command()
@click.option("--upload-dir", default=str(Path.home() / "media-backup-files"), show_default=True,
              help="Directory where uploaded files are stored.")
@click.option("--host", default="0.0.0.0", show_default=True)
@click.option("--port", default=8765, show_default=True)
def serve(upload_dir, host, port):
    """Start the upload server."""
    cfg = _load_config()
    if not cfg.get("api_key"):
        click.echo("No API key found. Run 'media-backup setup' first.")
        return
    from server.server import run
    click.echo(f"Serving on http://{host}:{port}  →  {upload_dir}")
    run(upload_dir=upload_dir, api_key=cfg["api_key"], host=host, port=port)


@main.command()
def show_key():
    """Print the current API key."""
    cfg = _load_config()
    key = cfg.get("api_key")
    if key:
        click.echo(key)
    else:
        click.echo("No key configured. Run 'media-backup setup'.")


if __name__ == "__main__":
    main()
