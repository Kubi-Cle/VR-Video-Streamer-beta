"""VR Video Streamer for Linux.

  python3 -m vvs                      the window
  python3 -m vvs --cli FILE [--loop]  stream a file without the window
  python3 -m vvs --cli --url URL      stream an online video
  python3 -m vvs --cli --screen       stream a screen or window (the desktop asks which)
  add --local to skip the Cloudflare link, --sound KEY to add sound (see --list-sound)
"""
import argparse
import signal
import sys


def main():
    p = argparse.ArgumentParser(prog="vr-video-streamer", description="Stream to VR video players.")
    p.add_argument("--cli", action="store_true", help="run without the window")
    p.add_argument("file", nargs="?", help="a video or music file to stream")
    p.add_argument("--url", help="an online video (YouTube and others) to stream")
    p.add_argument("--screen", action="store_true", help="stream a screen or window")
    p.add_argument("--window", action="store_true", help="with --screen: pick a window instead of a monitor")
    p.add_argument("--loop", action="store_true")
    p.add_argument("--local", action="store_true", help="no public link (for testing)")
    p.add_argument("--height", type=int, default=1080)
    p.add_argument("--fps", type=int, default=30)
    p.add_argument("--bitrate", default="4M")
    p.add_argument("--encoder", choices=["nvenc", "vaapi", "cpu"])
    p.add_argument("--sound", action="append", default=[], help="sound source key (see --list-sound); repeatable")
    p.add_argument("--list-sound", action="store_true")
    p.add_argument("--seconds", type=float, default=0, help="stop after this long (for testing)")
    a = p.parse_args()

    if a.list_sound:
        from . import audio
        for s in audio.list_sources():
            print(f"{s.kind:7} {s.key!r:60} {s.label}")
        return

    if not a.cli and not (a.file or a.url or a.screen):
        from .ui import run
        sys.exit(run(sys.argv[:1]))

    import gi
    gi.require_version("Gst", "1.0")
    from gi.repository import GLib
    from . import audio, engine, portal

    settings = engine.Settings(height=a.height, fps=a.fps, bitrate=a.bitrate, loop=a.loop, public=not a.local)
    if a.encoder:
        settings.encoder = a.encoder
    if a.url:
        settings.source, settings.url = "url", a.url
    elif a.file:
        settings.source, settings.file = "file", a.file
    else:
        settings.source = "screen"
    if a.sound:
        known = {s.key: s for s in audio.list_sources()}
        settings.sounds = [known.get(k) or audio.Source("app", k, k) for k in a.sound]

    loop = GLib.MainLoop()
    result = {"code": 0}

    def on_event(kind, value):
        if kind == "log":
            print(f"  {value}", file=sys.stderr)
        elif kind == "link" and value:
            print(f"\nVIDEO PLAYER LINK:  {value}\n", flush=True)
        elif kind == "stopped":
            if value:
                print(f"Stopped: {value}", file=sys.stderr)
                result["code"] = 1
            GLib.idle_add(loop.quit)
        else:
            print(f"[{kind}] {value}", flush=True)

    sc = None
    streamer = None

    def go():
        nonlocal streamer
        streamer = engine.Streamer(settings, sc, lambda k, v: GLib.idle_add(on_event, k, v))
        streamer.start()
        if a.seconds:
            GLib.timeout_add(int(a.seconds * 1000), lambda: streamer.stop() or False)

    if settings.source == "screen":
        sc = portal.ScreenCast()

        def picked(err):
            if err:
                print(f"Screen sharing: {err}", file=sys.stderr)
                result["code"] = 1
                loop.quit()
            else:
                print(f"Sharing {sc.size[0]}x{sc.size[1]} (PipeWire node {sc.node_id})")
                go()

        sc.pick(portal.WINDOW if a.window else portal.MONITOR, picked)
    else:
        go()

    signal.signal(signal.SIGINT, lambda *_: GLib.idle_add(lambda: (streamer.stop() if streamer else loop.quit()) and False))
    loop.run()
    if sc:
        sc.close()
    sys.exit(result["code"])


if __name__ == "__main__":
    main()
