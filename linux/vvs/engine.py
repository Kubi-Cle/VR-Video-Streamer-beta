"""The stream itself: what Start-DesktopStream.ps1 does on Windows.

  picture + sound -> ffmpeg (H.264 + AAC) -> RTMP -> MediaMTX -> HLS on 127.0.0.1:8888 -> cloudflared -> the
  Video Player Link (https://<random>.trycloudflare.com/desktop/index.m3u8) that VR video players open.

The screen or a window comes from the desktop's ScreenCast portal through GStreamer (portal.py), sound from the
mixer (audio.py), files directly through ffmpeg, and online videos through yt-dlp.
"""
import json
import os
import re
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from . import audio, tools
from .procs import popen as _popen

STREAM_NAME = "desktop"
HLS_PORT = 8888
MEDIA_EXTENSIONS = (".mp4 .mkv .webm .mov .avi .wmv .flv .ts .m4v .mp3 .wav .flac .ogg .m4a .aac .opus").split()

# HLS as plain MPEG-TS: the most compatible format for AVPro on Android/standalone headsets.
# Every port stays on this PC: viewers reach the stream only through the Cloudflare link, so nobody on the
# network can watch without it or replace what's showing.
MEDIAMTX_CONFIG = f"""logLevel: warn
api: yes
apiAddress: 127.0.0.1:9997
metrics: no
pprof: no
playback: no
webrtc: no
srt: no
rtsp: yes
rtspAddress: 127.0.0.1:8554
protocols: [tcp]
rtmp: yes
rtmpAddress: 127.0.0.1:1935
hls: yes
hlsAddress: 127.0.0.1:{HLS_PORT}
hlsAllowOrigin: '*'
hlsAlwaysRemux: yes
hlsVariant: mpegts
hlsSegmentCount: 7
hlsSegmentDuration: 1s
paths:
  all_others:
"""



def has_nvidia():
    return Path("/proc/driver/nvidia/version").exists()


def has_vaapi():
    return Path("/dev/dri/renderD128").exists()


def default_encoder():
    return "nvenc" if has_nvidia() else ("vaapi" if has_vaapi() else "cpu")


# Browsers whose YouTube sign-in yt-dlp can use, and where each keeps its profiles (Firefox moved its folder
# to ~/.config/mozilla in newer versions, and the Flatpak keeps its own).
BROWSERS = {
    "firefox": ("Firefox", ["~/.config/mozilla/firefox", "~/.mozilla/firefox",
                            "~/.var/app/org.mozilla.firefox/config/mozilla/firefox",
                            "~/.var/app/org.mozilla.firefox/.mozilla/firefox"]),
    "chrome": ("Google Chrome", ["~/.config/google-chrome"]),
    "chromium": ("Chromium", ["~/.config/chromium"]),
    "brave": ("Brave", ["~/.config/BraveSoftware/Brave-Browser"]),
    "edge": ("Microsoft Edge", ["~/.config/microsoft-edge"]),
    "vivaldi": ("Vivaldi", ["~/.config/vivaldi"]),
}


def installed_browsers():
    """[(key, name)] of the browsers on this PC with a profile yt-dlp could take a sign-in from."""
    return [(k, name) for k, (name, roots) in BROWSERS.items() if any(Path(r).expanduser().is_dir() for r in roots)]


def browser_cookies_arg(key):
    """yt-dlp's --cookies-from-browser value. Firefox is pointed at its profile folder, since yt-dlp only looks in
    the old place by itself; the others are found by name."""
    if key == "firefox":
        for root in BROWSERS["firefox"][1]:
            if Path(root).expanduser().is_dir():
                return f"firefox:{Path(root).expanduser()}"
    return key


YOUTUBE_BOT_CHECK = "confirm you’re not a bot"


@dataclass
class Settings:
    source: str = "screen"            # screen (monitor or window, through the portal), file, url
    file: str = ""
    url: str = ""
    loop: bool = False
    height: int = 1080
    fps: int = 30
    bitrate: str = "4M"
    audio_bitrate: str = "128k"
    encoder: str = field(default_factory=default_encoder)   # nvenc, vaapi, cpu
    sounds: list = field(default_factory=list)              # audio.Source, for screen capture
    public: bool = True
    tunnel: str = "cloudflare"         # cloudflare (a free quick link) or permanent (your own Cloudflare tunnel)
    permanent_host: str = ""
    tunnel_token: str = ""
    youtube_browser: str = ""          # a BROWSERS key: use that browser's YouTube sign-in; "" = don't

class StreamError(Exception):
    pass


class Streamer:
    """Runs one stream. Events go to on_event(kind, value) from background threads:
    log (text), status (text), link (url or None), live (bool), viewers (int), stopped (error text or None),
    slow (encoding speed while this PC can't encode in real time, e.g. 0.8; None once it's keeping up again).
    """

    def __init__(self, settings, screencast=None, on_event=None):
        self.s = settings
        self.screencast = screencast
        self.emit = on_event or (lambda kind, value: print(f"[{kind}] {value}"))
        self.server = None
        self.ffmpeg = None
        self.pipeline = None
        self.mixer = None
        self.tunnel_proc = None
        self.link = None
        self.running = False
        self._stopping = False
        self._log_lines = []
        self._lock = threading.Lock()

    def log(self, text):
        self._log_lines.append(f"{time.strftime('%H:%M:%S')} {text}")
        del self._log_lines[:-400]
        self.emit("log", text)

    @property
    def recent_log(self):
        return "\n".join(self._log_lines)

    # --- Starting ---
    def start(self):
        """Starts everything; returns at once. Problems arrive as a 'stopped' event with the reason."""
        self.running = True
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        try:
            self._start_all()
        except Exception as e:  # anything at all: tell the window and clean up
            self.log(f"Error: {e}")
            self.stop(str(e))

    def _start_all(self):
        needed = ["mediamtx"] + (["cloudflared"] if self.s.public else []) + \
                 (["yt-dlp", "deno"] if self.s.source == "url" else [])
        tools.ensure(needed, lambda f, t: self.emit("status", t))
        if not self.running:
            return

        tools.STATE_DIR.mkdir(parents=True, exist_ok=True)
        self._stop_leftovers()
        self._start_server()
        if self.s.public:
            threading.Thread(target=self._tunnel_loop, daemon=True).start()
        else:
            self.emit("link", None)
        self._start_stream()
        threading.Thread(target=self._count_viewers, daemon=True).start()

    def _spawn(self, args, **kw):
        kw.setdefault("stdin", subprocess.DEVNULL)
        return _popen(args, **kw)

    def _stop_leftovers(self):
        """An earlier run that didn't close properly would hold the ports."""
        tools_dir = str(tools.TOOLS_DIR)
        for pid in os.listdir("/proc"):
            if not pid.isdigit() or int(pid) == os.getpid():
                continue
            try:
                exe = os.readlink(f"/proc/{pid}/exe")
            except OSError:
                continue
            if exe.startswith(tools_dir) and os.path.basename(exe) in ("mediamtx", "cloudflared"):
                try:
                    os.kill(int(pid), signal.SIGTERM)
                except OSError:
                    pass
        time.sleep(0.2)

    def _start_server(self):
        self.emit("status", "Starting the stream server...")
        config = tools.STATE_DIR / "mediamtx-stream.yml"
        config.write_text(MEDIAMTX_CONFIG)
        self.server = self._spawn([tools.find("mediamtx"), str(config)], cwd=tools.STATE_DIR,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        threading.Thread(target=self._pump, args=(self.server.stdout, "MediaMTX: "), daemon=True).start()
        for _ in range(50):
            time.sleep(0.1)
            if self.server.poll() is not None:
                raise StreamError("The stream server (MediaMTX) closed straight away. Is another copy of this "
                                  "program, or something else, using port 8888, 1935 or 8554?")
            try:
                urllib.request.urlopen("http://127.0.0.1:9997/v3/paths/list", timeout=1).read()
                return
            except OSError:
                continue
        raise StreamError("The stream server (MediaMTX) didn't start.")

    def _pump(self, stream, prefix):
        for line in stream:
            line = line.rstrip()
            if line:
                self.log(prefix + line)

    # --- Picture and sound ---
    def _out_size(self, src_w, src_h):
        """Shrink to the chosen height if bigger, never upscale; both sides even for H.264, at most 3840 wide."""
        out_h = min(self.s.height, src_h)
        out_w = src_w * out_h / src_h
        if out_w > 3840:
            out_w, out_h = 3840, src_h * 3840 / src_w
        out_h = int(out_h) - int(out_h) % 2
        out_w = int(round(out_w / 2)) * 2
        return max(out_w, 2), max(out_h, 2)

    def _video_codec(self):
        s, gop = self.s, self.s.fps
        rate = ["-b:v", s.bitrate, "-maxrate", s.bitrate, "-bufsize", s.bitrate, "-g", str(gop),
                "-keyint_min", str(gop), "-r", str(s.fps)]
        # H.264 main profile, 1 keyframe per second so HLS segments line up
        if s.encoder == "nvenc":
            return ["-c:v", "h264_nvenc", "-preset", "p4", "-tune", "ll", "-profile:v", "main", *rate], ""
        if s.encoder == "vaapi":
            return ["-c:v", "h264_vaapi", "-profile:v", "main", *rate], ",format=nv12,hwupload"
        # x264's sliced threads (from -tune zerolatency) drop capture to ~2 fps when there's sound
        return ["-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-x264-params", "sliced-threads=0",
                "-profile:v", "main", "-pix_fmt", "yuv420p", *rate], ""

    def _probe(self, path):
        """(has picture, has sound). Cover art in music files is a 1-frame 'video' (attached_pic=1); ignored."""
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                              "stream=codec_type:stream_disposition=attached_pic", "-of", "csv=p=0", path],
                             capture_output=True, text=True, timeout=60).stdout.split()
        return any(k.startswith("video,0") for k in out), any(k.startswith("audio") for k in out)

    def _youtube_urls(self):
        """Direct picture and sound addresses for an online video, from yt-dlp."""
        self.emit("status", "Getting the video from the web...")
        h = self.s.height
        fmt = (f"bv*[height<={h}][vcodec^=avc1]+ba[acodec^=mp4a]/bv*[height<={h}]+ba/b[height<={h}]/b")
        env = dict(os.environ, PATH=f"{tools.TOOLS_DIR}:{os.environ.get('PATH', '')}")
        browser = self.s.youtube_browser if self.s.youtube_browser in BROWSERS else ""
        # Only read when you've turned it on, and only by yt-dlp on this PC: it's never saved or sent anywhere else
        cookies = ["--cookies-from-browser", browser_cookies_arg(browser)] if browser else []
        r = subprocess.run([tools.find("yt-dlp"), "--no-playlist", "--no-warnings", *cookies, "-f", fmt,
                            "--print", "title", "-g", self.s.url],
                           capture_output=True, text=True, timeout=120, env=env)
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        if r.returncode != 0 or len(lines) < 2:
            err = (r.stderr.strip().splitlines() or ["no details"])[-1]
            if YOUTUBE_BOT_CHECK in r.stderr.replace("'", "’"):
                if browser:
                    raise StreamError(f"YouTube asked this PC to prove it isn't a bot, even with {BROWSERS[browser][0]}'s "
                                      f"sign-in. Open YouTube in {BROWSERS[browser][0]}, make sure you're signed in, "
                                      "then try again.")
                raise StreamError("YouTube asked this PC to prove it isn't a bot. Turn on \"Use my browser's YouTube "
                                  "sign-in\" on the YouTube tab (you need to be signed in to YouTube in that browser), "
                                  "or try again later.")
            if browser and re.search(r"cookie", err, re.I):
                raise StreamError(f"Couldn't use {BROWSERS[browser][0]}'s YouTube sign-in: {err}")
            raise StreamError(f"Couldn't open that link: {err}")
        return lines[0], lines[1:]

    def _start_stream(self):
        s = self.s
        args = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostats"]
        maps, pass_fds, sound_filter = [], (), ""
        has_sound = False
        stdin = subprocess.DEVNULL
        video_input_size = None

        if s.source == "screen":
            sc = self.screencast
            if not sc or not sc.active:
                raise StreamError("Choose a screen or window to stream first.")
            w, h = self._out_size(*sc.size)
            video_input_size = (w, h)
            what = "your screen" if sc.source_type == 1 else "a window"
            args += ["-thread_queue_size", "64", "-probesize", "32", "-analyzeduration", "0",
                     "-f", "rawvideo", "-pix_fmt", "yuv420p", "-video_size", f"{w}x{h}", "-framerate", str(s.fps),
                     "-i", "pipe:0"]
            maps += ["-map", "0:v"]
            stdin = subprocess.PIPE
            if s.sounds:
                read_fd, write_fd = os.pipe()
                pass_fds = (read_fd,)
                args += ["-thread_queue_size", "1024", "-probesize", "32", "-analyzeduration", "0",
                         "-f", "f32le", "-ar", str(audio.RATE), "-ch_layout", "stereo", "-i", f"pipe:{read_fd}"]
                maps += ["-map", "1:a"]
                has_sound = True
                # The picture reaches ffmpeg a little after the sound (screen capture + conversion), so the
                # sound is held back by about that much
                self.mixer = audio.Mixer(write_fd, s.sounds, hold_ms=80, log=self.log)
                what += " + " + ", ".join(x.label for x in s.sounds)
        elif s.source == "file":
            path = os.path.abspath(os.path.expanduser(s.file))
            if not os.path.isfile(path):
                raise StreamError(f"File not found: {path}")
            has_video, has_sound = self._probe(path)
            loop = ["-stream_loop", "-1"] if s.loop else []
            what = f"'{os.path.basename(path)}'" + (" (looping)" if s.loop else "")
            if has_video:
                args += ["-re", *loop, "-i", path]
                maps += ["-map", "0:v:0"] + (["-map", "0:a:0"] if has_sound else [])
            else:
                # Music only: a black picture so video players have something to show. Only the music gets -re;
                # it paces the whole output (-re on the picture too halves the speed).
                args += ["-f", "lavfi", "-i", f"color=c=black:s=1280x720:r={s.fps}", "-re", *loop, "-i", path]
                maps += ["-map", "0:v", "-map", "1:a:0", "-shortest"]
        elif s.source == "url":
            title, urls = self._youtube_urls()
            what = f"'{title}'"
            net = ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
            for u in urls:
                args += ["-re", *net, "-i", u]
            if len(urls) >= 2:
                maps += ["-map", "0:v:0", "-map", "1:a:0"]
            else:
                maps += ["-map", "0:v:0", "-map", "0:a:0?"]
            has_sound = True
        else:
            raise StreamError(f"Unknown source {s.source}")

        codec, hw_tail = self._video_codec()
        if s.encoder == "vaapi":
            args = args[:1] + ["-vaapi_device", "/dev/dri/renderD128"] + args[1:]
        vf = f"scale=-2:'min({s.height},trunc(ih/2)*2)'" + hw_tail
        if s.encoder != "vaapi":
            vf += ",format=yuv420p"
        sound = (["-c:a", "aac", "-b:a", s.audio_bitrate, "-ar", "48000", "-ac", "2"] if has_sound else ["-an"])
        if has_sound and s.source in ("file", "url"):
            # Gaps or overlaps in a file's or website's sound would otherwise shift all the sound after them: video
            # players play sound continuously, ignoring its timestamps. This fills gaps and trims overlaps.
            sound = ["-af", "aresample=async=1"] + sound
        # Publish over RTMP: its sound and picture share one clock, which keeps the HLS link in sync.
        args += maps + codec + ["-vf", vf] + sound + ["-progress", "pipe:1", "-stats_period", "2",
                                                      "-f", "flv", f"rtmp://127.0.0.1:1935/{STREAM_NAME}"]

        self.log("ffmpeg " + " ".join(a if " " not in a else repr(a) for a in args[1:]))
        self.emit("status", f"Streaming {what}")
        self.ffmpeg = self._spawn(args, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                  pass_fds=pass_fds)
        for fd in pass_fds:
            os.close(fd)
        threading.Thread(target=self._pump, args=(self.ffmpeg.stderr, "ffmpeg: "), daemon=True).start()
        threading.Thread(target=self._watch_speed, args=(self.ffmpeg.stdout,), daemon=True).start()

        if s.source == "screen":
            if self.mixer:
                self.mixer.start()   # records now, mixes from the first picture frame (see _start_capture)
            self._start_capture(*video_input_size)
            if self.mixer:
                # Should the first frame never come, don't leave ffmpeg waiting for sound forever
                fallback = threading.Timer(5, self.mixer.begin)
                fallback.daemon = True
                fallback.start()
        threading.Thread(target=self._wait_ffmpeg, daemon=True).start()
        threading.Thread(target=self._wait_live, daemon=True).start()

    def _start_capture(self, w, h):
        """Screen or window from the portal's PipeWire stream, as steady raw frames into ffmpeg."""
        from gi.repository import Gst
        Gst.init(None)
        sc = self.screencast
        # keepalive-time repeats the last picture while nothing changes (a still window sends nothing), so the
        # stream never stalls; videorate makes it exactly fps; videoscale letterboxes if the window is resized.
        desc = (f"pipewiresrc fd={os.dup(sc.fd)} path={sc.node_id} do-timestamp=true keepalive-time=100 "
                f"always-copy=true ! videoconvert n-threads=4 ! videoscale n-threads=4 add-borders=true ! "
                f"videorate ! video/x-raw,format=I420,width={w},height={h},framerate={self.s.fps}/1,"
                f"pixel-aspect-ratio=1/1 ! fdsink name=out fd={self.ffmpeg.stdin.fileno()} sync=false")
        self.log("gst: " + desc)
        self.pipeline = Gst.parse_launch(desc)

        # ffmpeg times the picture by counting frames and the sound by counting samples, so both have to start
        # counting at the same moment: the mixer begins when the first frame goes to ffmpeg.
        mixer = self.mixer
        if mixer:
            def first_frame(_pad, _info):
                mixer.begin()
                return Gst.PadProbeReturn.REMOVE
            self.pipeline.get_by_name("out").get_static_pad("sink").add_probe(Gst.PadProbeType.BUFFER, first_frame)
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()

        def on_message(_bus, msg):
            if msg.type == Gst.MessageType.ERROR:
                err, dbg = msg.parse_error()
                self.log(f"Capture error: {err.message} ({dbg})")
                if self.running and not self._stopping:
                    threading.Thread(target=self.stop, args=(
                        "The screen capture stopped. If you stopped sharing from the desktop, choose it again.",),
                        daemon=True).start()
            elif msg.type == Gst.MessageType.EOS and self.running and not self._stopping:
                threading.Thread(target=self.stop, args=("The shared screen or window closed.",), daemon=True).start()

        bus.connect("message", on_message)
        if self.pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            raise StreamError("The screen capture couldn't start.")

    def _watch_speed(self, stream):
        """ffmpeg's progress report. A live stream must encode at 1x; slower means the picture falls behind the
        sound (and viewers fall further behind live), which no syncing can fix, so say what would help."""
        # ffmpeg's own "speed" is an average since the start, which a slow start keeps low for minutes; the speed
        # over each report (stream time made / real time passed) shows what's happening now.
        slow, fast, shown, warned_at, last = 0, 0, False, 0.0, None
        for line in stream:
            key, _, value = line.strip().partition("=")
            if key != "out_time_us":
                continue
            try:
                now = (int(value), time.monotonic())
            except ValueError:
                continue
            prev, last = last, now
            if prev is None or now[1] - prev[1] < 1:
                continue
            speed = (now[0] - prev[0]) / 1e6 / (now[1] - prev[1])
            slow, fast = (slow + 1, 0) if speed < 0.95 else (0, fast + 1)
            # The window's warning: shown after ~6 s too slow, gone after ~10 s keeping up, so a brief hiccup
            # (a game loading) doesn't flash it
            if slow >= 3 and not self._stopping:
                shown = True
                self.emit("slow", round(speed, 2))
            elif shown and fast >= 5:
                shown = False
                self.emit("slow", None)
            if slow >= 3 and time.time() - warned_at > 60:   # slow for ~6 s, logged at most once a minute
                warned_at = time.time()
                self.log(f"Warning: encoding at only {speed:.2f}x speed, so picture and sound will drift apart. "
                         "Try 30 fps, a lower quality, or graphics card encoding.")

    def _wait_ffmpeg(self):
        proc = self.ffmpeg
        code = proc.wait()
        if self._stopping or not self.running:
            return
        if self.s.source == "file" and code == 0:
            self.stop(None, finished=True)
        elif self.s.source == "url" and code == 0:
            self.stop(None, finished=True)
        else:
            tail = "\n".join(l for l in self._log_lines[-6:] if "ffmpeg:" in l)
            self.stop(f"ffmpeg stopped (code {code}). {tail}".strip())

    def _wait_live(self):
        """Live once MediaMTX has the stream and its HLS answers."""
        url = f"http://127.0.0.1:{HLS_PORT}/{STREAM_NAME}/index.m3u8"
        for _ in range(60):
            if not self.running:
                return
            try:
                if urllib.request.urlopen(url, timeout=2).status == 200:
                    self.emit("live", True)
                    return
            except OSError:
                pass
            time.sleep(0.5)
        self.log("The stream didn't reach the stream server after 30 s.")

    # --- The Video Player Link ---
    def _tunnel_loop(self):
        """Opens the link, and opens it again if it drops, without stopping the stream. A free link gets a new
        address each time, which the window shows; a permanent link comes back the same."""
        wait = 5
        first = True
        while self.running and not self._stopping:
            url = None
            for attempt in range(1, 4):
                if not self.running or self._stopping:
                    return
                url = self._open_tunnel(attempt)
                if url:
                    break
            if url:
                self.link = f"{url}/{STREAM_NAME}/index.m3u8"
                self.emit("link", self.link)
                if not first:
                    self.log("Reconnected the Video Player Link.")
                first, wait = False, 5
                self.tunnel_proc.wait()
                if self.running and not self._stopping:
                    self.log("The link service disconnected. Reconnecting...")
                    self.emit("status", "Link dropped, reconnecting...")
                    self.emit("link", None)
            else:
                self.emit("link", None)
                self.log(f"Could not open a Video Player Link. Trying again in {wait} s.")
                self.emit("status", "Couldn't open the Video Player Link, retrying...")
                time.sleep(wait)
                wait = min(120, wait * 2)

    def _open_tunnel(self, attempt):
        s = self.s
        self._kill(self.tunnel_proc)
        self.emit("status", "Opening the Video Player Link" + (f" (try {attempt} of 3)" if attempt > 1 else "") + "...")
        env = dict(os.environ)
        if s.tunnel == "permanent":
            env["TUNNEL_TOKEN"] = s.tunnel_token
            args = [tools.find("cloudflared"), "tunnel", "--no-autoupdate", "--retries", "8", "run"]
            fixed = "https://" + s.permanent_host.strip().removeprefix("https://").strip("/")
        else:
            args = [tools.find("cloudflared"), "tunnel", "--no-autoupdate", "--retries", "8", "--url", f"http://127.0.0.1:{HLS_PORT}"]
            fixed = None
        proc = self._spawn(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env)
        self.tunnel_proc = proc
        found = {"url": fixed, "connected": False, "error": ""}
        ready = threading.Event()

        def read():
            for line in proc.stderr:
                if m := re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", line):
                    found["url"] = found["url"] or m.group(0)
                if "Registered tunnel connection" in line:
                    found["connected"] = True
                    ready.set()
                if re.search(r" ERR |denied|refused|timed out|failed|error", line):
                    found["error"] = re.sub(r"^\S+Z\s+", "", line.strip())[:160]
            ready.set()

        threading.Thread(target=read, daemon=True).start()
        ready.wait(30)
        url = found["url"]
        if not url or not found["connected"] or proc.poll() is not None:
            why = found["error"] or ("it closed" if proc.poll() is not None else "no link after 30 s")
            self.log(f"Cloudflare didn't work: {why}")
            self._kill(proc)
            return None

        # A new address doesn't exist in DNS for the first few seconds, and asking this PC's DNS too early makes
        # it remember "doesn't exist" for a while. So wait until Cloudflare's own DNS knows it, then check.
        host = urllib.parse.urlparse(url).hostname
        in_dns = False
        deadline = time.time() + 25
        while time.time() < deadline and proc.poll() is None:
            try:
                req = urllib.request.Request(f"https://cloudflare-dns.com/dns-query?name={host}&type=A",
                                             headers={"Accept": "application/dns-json"})
                if json.load(urllib.request.urlopen(req, timeout=5)).get("Answer"):
                    in_dns = True
                    break
            except (OSError, ValueError):
                pass
            time.sleep(0.5)
        # Any HTTP answer (MediaMTX says 404 before the stream starts) proves the tunnel is through
        last_error = ""
        for _ in range(10 if in_dns else 20):
            if proc.poll() is not None:
                break
            try:
                urllib.request.urlopen(url, timeout=5)
                return url
            except urllib.error.HTTPError:
                return url
            except OSError as e:
                last_error = str(e)
                time.sleep(1)
        if in_dns and proc.poll() is None:
            # Connected and the address exists: viewers use their own DNS, so the link works for them
            self.log(f"Note: the link works, but this PC can't open it yet ({last_error}). Viewers aren't affected.")
            return url
        self.log(f"Cloudflare's link didn't answer: {last_error}")
        self._kill(proc)
        return None

    def _count_viewers(self):
        """Worked out from how much the stream is sending, so it's an estimate (like the Windows version)."""
        bits = _parse_rate(self.s.bitrate) + _parse_rate(self.s.audio_bitrate)
        last = None
        while self.running and not self._stopping:
            time.sleep(5)
            try:
                data = json.load(urllib.request.urlopen("http://127.0.0.1:9997/v3/hlsmuxers/list", timeout=2))
                sent = sum(item.get("bytesSent", 0) for item in data.get("items", []))
            except (OSError, ValueError):
                continue
            if last is not None and bits:
                rate = (sent - last) * 8 / 5
                # The window's own preview counts as one
                self.emit("viewers", max(0, round(rate / bits) - (1 if self.preview_on else 0)))
            last = sent

    preview_on = False

    # --- Stopping ---
    def _kill(self, proc):
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(3)
            except subprocess.TimeoutExpired:
                proc.kill()

    def stop(self, error=None, finished=False):
        with self._lock:
            if self._stopping:
                return
            self._stopping = True
        self.running = False
        if self.pipeline is not None:
            from gi.repository import Gst
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        if self.mixer:
            self.mixer.stop()
        if self.ffmpeg and self.ffmpeg.stdin:
            try:
                self.ffmpeg.stdin.close()
            except OSError:
                pass
        for p in (self.ffmpeg, self.tunnel_proc, self.server):
            self._kill(p)
        self.emit("live", False)
        self.emit("link", None)
        self.emit("stopped", error if not finished else None)
        if finished:
            self.emit("status", "Finished playing.")


def _parse_rate(text):
    m = re.fullmatch(r"\s*([\d.]+)\s*([kKmM]?)\s*", text or "")
    if not m:
        return 0
    return float(m.group(1)) * {"": 1, "k": 1e3, "m": 1e6}[m.group(2).lower()]
