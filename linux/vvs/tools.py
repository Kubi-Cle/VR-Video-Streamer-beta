"""Finds the helper programs, and downloads the ones Fedora doesn't package into this user's data folder.

FFmpeg and GStreamer come from Fedora itself (dnf). MediaMTX, cloudflared, yt-dlp and Deno are downloaded from
their official GitHub releases the first time they're needed, like the Windows version does.
"""
import os
import shutil
import stat
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

DATA_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "vr-video-streamer"
TOOLS_DIR = DATA_DIR / "tools"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "vr-video-streamer"

MEDIAMTX_VERSION = "v1.9.3"

# name -> (download URL, how it's packed, file inside the archive)
DOWNLOADS = {
    "mediamtx": (f"https://github.com/bluenviron/mediamtx/releases/download/{MEDIAMTX_VERSION}/"
                 f"mediamtx_{MEDIAMTX_VERSION}_linux_amd64.tar.gz", "tar", "mediamtx"),
    "cloudflared": ("https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
                    "bin", None),
    "yt-dlp": ("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux", "bin", None),
    # yt-dlp needs a JavaScript runtime to read YouTube's pages
    "deno": ("https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip",
             "zip", "deno"),
}

DESCRIPTIONS = {
    "mediamtx": "MediaMTX (the stream server)",
    "cloudflared": "cloudflared (makes the Video Player Link)",
    "yt-dlp": "yt-dlp (plays YouTube and other online videos)",
    "deno": "Deno (yt-dlp needs it for YouTube)",
}


def find(name):
    """Path of a tool: our downloaded copy first (a known version), then one installed on the system."""
    ours = TOOLS_DIR / name
    if ours.is_file() and os.access(ours, os.X_OK):
        return str(ours)
    return shutil.which(name)


def missing(names):
    return [n for n in names if not find(n)]


def download(name, progress=None):
    """Downloads one tool into TOOLS_DIR. progress(fraction or None, text) is called along the way."""
    url, kind, inner = DOWNLOADS[name]
    TOOLS_DIR.mkdir(parents=True, exist_ok=True)
    say = progress or (lambda f, t: None)
    say(0.0, f"Downloading {DESCRIPTIONS[name]}...")
    with tempfile.TemporaryDirectory(dir=TOOLS_DIR) as tmp:
        tmp_file = Path(tmp) / "download"
        req = urllib.request.Request(url, headers={"User-Agent": "vr-video-streamer"})
        with urllib.request.urlopen(req, timeout=60) as resp, open(tmp_file, "wb") as out:
            total = int(resp.headers.get("Content-Length") or 0)
            done = 0
            while chunk := resp.read(256 * 1024):
                out.write(chunk)
                done += len(chunk)
                say(done / total if total else None, f"Downloading {DESCRIPTIONS[name]}... {done // 1048576} MB")
        target = TOOLS_DIR / name
        if kind == "bin":
            shutil.move(tmp_file, target)
        elif kind == "tar":
            with tarfile.open(tmp_file) as tar:
                member = tar.getmember(inner)
                member.name = name
                tar.extract(member, tmp, filter="data")
                shutil.move(Path(tmp) / name, target)
            # Licence goes next to it, like the Windows version's tools/licenses
            with tarfile.open(tmp_file) as tar:
                if "LICENSE" in tar.getnames():
                    lic = tar.getmember("LICENSE")
                    lic.name = f"{name}-LICENSE.txt"
                    tar.extract(lic, TOOLS_DIR, filter="data")
        elif kind == "zip":
            with zipfile.ZipFile(tmp_file) as z:
                z.extract(inner, tmp)
                shutil.move(Path(tmp) / inner, target)
        target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    say(1.0, f"Downloaded {DESCRIPTIONS[name]}.")
    return str(target)


def ensure(names, progress=None):
    for name in missing(names):
        download(name, progress)
