"""Sound for the stream: which programs and devices can be heard, and a mixer that combines them.

The Linux counterpart of SoundMixer.cs / ProcessAudio.cs / DeviceAudio.cs. Every source is recorded by its own
pw-record (PipeWire), so programs can be captured on their own without changing what you hear. The mixer keeps a
steady 48 kHz clock and fills gaps with silence: programs stop sending sound when they pause, and the stream must
keep going. Volumes and the list of sources can change while streaming.
"""
import array
import json
import os
import subprocess
import threading
import time

from .procs import popen

RATE = 48000
CHANNELS = 2
TICK = 0.02                         # mix every 20 ms
TICK_FRAMES = int(RATE * TICK)
MAX_BUFFER = int(RATE * 0.25) * CHANNELS   # more queued than this = we fell behind; drop the oldest
# The most sound a recorder may hold between mixes. A recorder's clock (the sound card's) never quite matches the
# mixer's, so its queue slowly grows; trimming it here keeps every source's delay small and steady instead of
# drifting up to MAX_BUFFER and then jumping back.
MAX_LAG = TICK_FRAMES * CHANNELS * 3


class Source:
    """Something that makes sound. kind: 'pc' (everything you hear), 'app' (one program), 'device' (an input)."""

    def __init__(self, kind, key, label, volume=1.0):
        self.kind, self.key, self.label, self.volume = kind, key, label, volume

    def to_json(self):
        return {"kind": self.kind, "key": self.key, "label": self.label, "volume": self.volume}

    @staticmethod
    def from_json(d):
        return Source(d["kind"], d["key"], d["label"], float(d.get("volume", 1.0)))

    def __repr__(self):
        return f"Source({self.kind}, {self.key!r}, {self.volume:.2f})"


def _pw_dump():
    try:
        out = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5).stdout
        return json.loads(out or "[]")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return []


def _default_sink():
    try:
        return subprocess.run(["pactl", "get-default-sink"], capture_output=True, text=True, timeout=3).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def _app_key(props):
    """Programs are matched by name and process, so a program that reopens its sound is picked up again."""
    name = props.get("application.name") or props.get("node.name") or "Unknown program"
    return f"{name}|{props.get('application.process.binary', '')}"


def list_sources():
    """Everything that could be streamed right now: this PC's sound, programs making sound, and inputs."""
    nodes = _pw_dump()
    own_pid = str(os.getpid())
    sources = [Source("pc", "default", "Everything you hear on this PC")]
    seen = set()
    apps, devices = [], []
    for o in nodes:
        if o.get("type") != "PipeWire:Interface:Node":
            continue
        props = o.get("info", {}).get("props", {})
        cls = props.get("media.class")
        if cls == "Stream/Output/Audio":
            if str(props.get("application.process.id")) == own_pid or props.get("node.name", "").startswith("vvs-"):
                continue
            key = _app_key(props)
            if key in seen:
                continue
            seen.add(key)
            apps.append(Source("app", key, props.get("application.name") or props.get("node.name") or "Program"))
        elif cls == "Audio/Source":
            devices.append(Source("device", props.get("node.name"),
                                  props.get("node.description") or props.get("node.nick") or props.get("node.name")))
    apps.sort(key=lambda s: s.label.lower())
    return sources + apps + devices


def _targets(source, nodes):
    """pw-record arguments for each stream that belongs to a source right now."""
    if source.kind == "pc":
        sink = _default_sink()
        return [("pc", ["--target", sink, "-P", "{ stream.capture.sink=true }"])] if sink else []
    if source.kind == "device":
        return [(source.key, ["--target", source.key])]
    result = []
    for o in nodes:
        props = o.get("info", {}).get("props", {})
        if props.get("media.class") == "Stream/Output/Audio" and _app_key(props) == source.key:
            serial = str(props.get("object.serial", o.get("id")))
            result.append((serial, ["--target", serial]))
    return result


class _Recorder:
    """One pw-record, feeding a buffer the mixer takes from."""

    def __init__(self, target_args, log):
        self.buffer = array.array("f")
        self.lock = threading.Lock()
        self.proc = popen(
            ["pw-record", "--raw", "--format", "f32", "--rate", str(RATE), "--channels", str(CHANNELS),
             "--latency", "20ms", "-P", "{ node.name=vvs-capture node.dont-reconnect=true }", *target_args, "-"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.log = log
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        frame_bytes = 4 * CHANNELS
        leftover = b""
        while True:
            chunk = self.proc.stdout.read1(16384) if hasattr(self.proc.stdout, "read1") else self.proc.stdout.read(4096)
            if not chunk:
                break
            chunk = leftover + chunk
            usable = len(chunk) - len(chunk) % frame_bytes
            leftover = chunk[usable:]
            samples = array.array("f")
            samples.frombytes(chunk[:usable])
            with self.lock:
                self.buffer.extend(samples)
                if len(self.buffer) > MAX_BUFFER:
                    del self.buffer[:len(self.buffer) - MAX_BUFFER // 2]

    def take(self, count):
        with self.lock:
            got = self.buffer[:count]
            del self.buffer[:count]
            extra = len(self.buffer) - MAX_LAG
            if extra > 0:
                del self.buffer[:extra - extra % CHANNELS]
        return got

    @property
    def alive(self):
        return self.proc.poll() is None

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(2)
            except subprocess.TimeoutExpired:
                self.proc.kill()


class Mixer:
    """Mixes the chosen sources into a file descriptor (ffmpeg's sound input) at a steady 48 kHz.

    hold_ms holds the sound back a little so it lines up with the picture, which reaches the stream later.
    """

    def __init__(self, out_fd, sources, hold_ms=0, log=print):
        self.out_fd = out_fd
        self.sources = list(sources)
        self.hold_ms = hold_ms
        self.log = log
        self.recorders = {}      # (source key, stream id) -> _Recorder
        self.lock = threading.Lock()
        self.running = False
        self._began = False

    def set_sources(self, sources):
        """Change what's mixed while streaming (new volumes, sources added or removed)."""
        with self.lock:
            self.sources = list(sources)
        self._refresh()

    def set_volume(self, key, volume):
        with self.lock:
            for s in self.sources:
                if s.key == key:
                    s.volume = volume

    def start(self):
        """Starts recording, but not mixing: call begin() when the first picture frame reaches ffmpeg, so sound
        and picture both start counting from the same moment."""
        self.running = True
        self._began = False
        self._refresh()
        threading.Thread(target=self._watch, daemon=True).start()

    def begin(self):
        with self.lock:
            if self._began or not self.running:
                return
            self._began = True
        threading.Thread(target=self._mix, daemon=True).start()

    def stop(self):
        self.running = False
        with self.lock:
            recs = list(self.recorders.values())
            self.recorders.clear()
        for r in recs:
            r.stop()
        try:
            os.close(self.out_fd)
        except OSError:
            pass

    def _refresh(self):
        """Start recorders for streams that appeared, stop ones no longer wanted or that ended."""
        nodes = _pw_dump()
        with self.lock:
            sources = list(self.sources)
        wanted = {}
        for s in sources:
            for stream_id, args in _targets(s, nodes):
                wanted[(s.key, stream_id)] = args
        # Starting and stopping pw-record can take a while (stop waits up to 2 s), so it happens outside the lock:
        # the mixer takes that lock every 20 ms and must never wait for it.
        with self.lock:
            old = [self.recorders.pop(k) for k in list(self.recorders)
                   if k not in wanted or not self.recorders[k].alive]
            new = {k: args for k, args in wanted.items() if k not in self.recorders}
        for r in old:
            r.stop()
        for k, args in new.items():
            if not self.running:
                break
            rec = _Recorder(args, self.log)
            with self.lock:
                if self.running and k not in self.recorders:
                    self.recorders[k] = rec
                    rec = None
            if rec:
                rec.stop()

    def _watch(self):
        while self.running:
            time.sleep(2)
            if self.running:
                try:
                    self._refresh()
                except Exception as e:  # keep mixing whatever else happens
                    self.log(f"Sound: couldn't refresh the sources: {e}")

    def _mix(self):
        n = TICK_FRAMES * CHANNELS
        silence = array.array("f", bytes(4 * n))
        # The hold: silence first, so everything after it is that much later
        try:
            for _ in range(int(self.hold_ms / 1000 / TICK)):
                os.write(self.out_fd, silence.tobytes())
        except OSError:
            return
        next_tick = time.monotonic()
        peak_hold = 1.0
        behind_logged = False
        while self.running:
            next_tick += TICK
            with self.lock:
                parts = [(rec, next((s.volume for s in self.sources if s.key == key[0]), 0.0))
                         for key, rec in self.recorders.items()]
            mixed = array.array("f", silence)
            for rec, vol in parts:
                got = rec.take(n)
                if vol <= 0 or not got:
                    continue
                if vol == 1.0:
                    for i, v in enumerate(got):
                        mixed[i] += v
                else:
                    for i, v in enumerate(got):
                        mixed[i] += v * vol
            # Soft limit: several loud sources together would clip, so turn the whole mix down smoothly instead
            loudest = max(max(mixed), -min(mixed))
            target = 0.95 / loudest if loudest > 0.95 else 1.0
            peak_hold = min(target, peak_hold + 0.01)
            if peak_hold < 1.0:
                for i in range(n):
                    mixed[i] *= peak_hold
            try:
                os.write(self.out_fd, mixed.tobytes())
            except OSError:
                break  # ffmpeg closed
            # ffmpeg times the sound by counting samples, so every 20 ms of real time must become 20 ms of sound.
            # After a hold-up this loop doesn't sleep until it has caught up (the recorders' queues are short,
            # so that's mostly silence); skipping ahead instead would leave the sound early for good.
            delay = next_tick - time.monotonic()
            if delay > 0:
                time.sleep(delay)
                behind_logged = False
            elif delay < -0.25 and not behind_logged:
                behind_logged = True
                self.log(f"Sound: the mixer was held up {-delay:.1f} s; filling the gap to stay in sync.")
