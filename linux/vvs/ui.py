"""The window: pick what to stream and its sound, press Start, and share the Video Player Link."""
import json
import os
import platform
import subprocess
import sys
from urllib.parse import urlparse

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Gst", "1.0")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

from . import VERSION, audio, engine, portal, qr, tools  # noqa: E402

APP_ID = "io.github.kubicle.VRVideoStreamer"
SETTINGS_FILE = tools.STATE_DIR / "settings.json"
LOCAL_HLS = f"http://127.0.0.1:{engine.HLS_PORT}/{engine.STREAM_NAME}/index.m3u8"

CSS = b"""
.live-pill { background: #d62d20; color: white; border-radius: 999px; padding: 2px 10px; font-weight: bold; }
.preview-frame { background: black; border-radius: 12px; }
.preview-hint { color: alpha(white, 0.6); }
.link-entry { font-family: monospace; }
.tip { opacity: 0.7; font-size: smaller; }
.slow-warning { background: #5a1f1f; color: #ffe1e1; border: 1px solid #f09595; border-radius: 10px; padding: 10px 14px; }
.slow-warning .heading { color: white; }
"""


def load_settings():
    try:
        return json.loads(SETTINGS_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_settings(data):
    tools.STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = SETTINGS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.chmod(0o600)   # holds the permanent link's token, if there is one
    tmp.replace(SETTINGS_FILE)


class SoundRow(Adw.ActionRow):
    def __init__(self, source, chosen, on_change):
        super().__init__(title=GLib.markup_escape_text(source.label))
        self.source = source
        self.check = Gtk.CheckButton(active=chosen, valign=Gtk.Align.CENTER)
        self.add_prefix(self.check)
        self.set_activatable_widget(self.check)
        subtitle = {"pc": "Everything you hear, from every program", "app": "Program",
                    "device": "Microphone or input"}[source.kind]
        self.set_subtitle(subtitle)
        self.scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 150, 5)
        self.scale.set_value(source.volume * 100)
        self.scale.set_size_request(140, -1)
        self.scale.set_valign(Gtk.Align.CENTER)
        self.scale.set_draw_value(False)
        self.scale.set_tooltip_text("Volume for viewers. Doesn't change what you hear.")
        self.pct = Gtk.Label(label=f"{int(source.volume * 100)}%", width_chars=5, xalign=1)
        self.pct.add_css_class("dim-label")
        self.add_suffix(self.scale)
        self.add_suffix(self.pct)

        def changed(*_):
            self.source.volume = self.scale.get_value() / 100
            self.pct.set_label(f"{int(self.scale.get_value())}%")
            on_change()

        self.scale.connect("value-changed", changed)
        self.check.connect("toggled", lambda *_: on_change())


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="VR Video Streamer", default_width=980, default_height=760)
        self.cfg = load_settings()
        self.screencast = portal.ScreenCast()
        self.streamer = None
        self.link = None
        self.sound_rows = []
        self._preview_retry = None

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        self.live_pill = Gtk.Label(label="Live", visible=False)
        self.live_pill.add_css_class("live-pill")
        header.pack_start(self.live_pill)
        menu = Gio.Menu()
        menu.append("Copy problem report", "win.report")
        menu.append("Open the tools folder", "win.tools")
        menu.append(f"About (version {VERSION})", "win.about")
        header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu))
        toolbar.add_top_bar(header)
        self.toasts = Adw.ToastOverlay()
        toolbar.set_content(self.toasts)
        self.set_content(toolbar)

        for name, fn in [("report", self.copy_report), ("tools", self.open_tools), ("about", self.show_about)]:
            act = Gio.SimpleAction.new(name, None)
            act.connect("activate", lambda *_a, f=fn: f())
            self.add_action(act)

        scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.toasts.set_child(scroller)
        clamp = Adw.Clamp(maximum_size=1100, margin_top=12, margin_bottom=18, margin_start=16, margin_end=16)
        scroller.set_child(clamp)
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        clamp.set_child(page)

        # --- Top: status, start/stop ---
        top = Gtk.Box(spacing=12)
        status_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True, valign=Gtk.Align.CENTER)
        self.status = Gtk.Label(label="Ready", xalign=0, wrap=True)
        self.status.add_css_class("title-3")
        self.viewers = Gtk.Label(label="", xalign=0)
        self.viewers.add_css_class("dim-label")
        self.viewers.set_tooltip_text("Worked out from how much the stream is sending, so it's an estimate")
        status_box.append(self.status)
        status_box.append(self.viewers)
        top.append(status_box)
        self.progress = Gtk.ProgressBar(visible=False, valign=Gtk.Align.CENTER, hexpand=False)
        self.progress.set_size_request(160, -1)
        top.append(self.progress)
        self.start_btn = Gtk.Button(label="Start streaming", valign=Gtk.Align.CENTER)
        self.start_btn.add_css_class("suggested-action")
        self.start_btn.add_css_class("pill")
        self.start_btn.connect("clicked", lambda *_: self.start())
        self.stop_btn = Gtk.Button(label="Stop stream", valign=Gtk.Align.CENTER, visible=False)
        self.stop_btn.add_css_class("destructive-action")
        self.stop_btn.add_css_class("pill")
        self.stop_btn.connect("clicked", lambda *_: self.stop())
        top.append(self.start_btn)
        top.append(self.stop_btn)
        page.append(top)

        # --- Red warning, only while this PC can't encode the stream in real time ---
        self.slow_box = Gtk.Box(spacing=12, visible=False)
        self.slow_box.add_css_class("slow-warning")
        self.slow_box.append(Gtk.Image(icon_name="dialog-warning-symbolic", pixel_size=24, valign=Gtk.Align.START))
        slow_text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        self.slow_title = Gtk.Label(xalign=0, wrap=True)
        self.slow_title.add_css_class("heading")
        self.slow_detail = Gtk.Label(xalign=0, wrap=True)
        slow_text.append(self.slow_title)
        slow_text.append(self.slow_detail)
        self.slow_box.append(slow_text)
        page.append(self.slow_box)

        # --- Middle: what to stream (left), preview (right) ---
        middle = Gtk.Box(spacing=18, homogeneous=True)
        page.append(middle)
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        middle.append(left)

        self.source_stack = Adw.ViewStack()
        switcher = Adw.ViewSwitcher(stack=self.source_stack, policy=Adw.ViewSwitcherPolicy.WIDE)
        left.append(switcher)
        left.append(self.source_stack)

        # Screen or window
        screen_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        group = Adw.PreferencesGroup(description="Your desktop asks what to share. You can share a whole "
                                                 "monitor or one program's window.")
        self.screen_row = Adw.ActionRow(title="Nothing chosen yet", subtitle="Pick something to share")
        btns = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        b1 = Gtk.Button(label="Monitor")
        b1.connect("clicked", lambda *_: self.pick_screen(portal.MONITOR))
        b2 = Gtk.Button(label="Window")
        b2.connect("clicked", lambda *_: self.pick_screen(portal.WINDOW))
        btns.append(b1)
        btns.append(b2)
        self.screen_row.add_suffix(btns)
        group.add(self.screen_row)
        screen_page.append(group)
        self.source_stack.add_titled_with_icon(screen_page, "screen", "Screen", "video-display-symbolic")

        # File
        file_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        group = Adw.PreferencesGroup(description="A video or music file. You can also drop one on this window.")
        self.file_row = Adw.EntryRow(title="Video or music file", text=self.cfg.get("file", ""))
        browse = Gtk.Button(label="Browse", valign=Gtk.Align.CENTER)
        browse.connect("clicked", lambda *_: self.browse())
        self.file_row.add_suffix(browse)
        group.add(self.file_row)
        self.loop_row = Adw.SwitchRow(title="Loop", subtitle="Play it again from the start when it ends",
                                      active=self.cfg.get("loop", False))
        group.add(self.loop_row)
        file_page.append(group)
        self.source_stack.add_titled_with_icon(file_page, "file", "File", "folder-videos-symbolic")

        # Online video
        url_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        group = Adw.PreferencesGroup(description="A YouTube link, or a link from most video sites (uses yt-dlp, "
                                                 "downloaded the first time).")
        self.url_row = Adw.EntryRow(title="Video link", text=self.cfg.get("url", ""))
        paste = Gtk.Button(icon_name="edit-paste-symbolic", valign=Gtk.Align.CENTER, tooltip_text="Paste")
        paste.connect("clicked", lambda *_: self.paste_url())
        self.url_row.add_suffix(paste)
        group.add(self.url_row)
        url_page.append(group)
        self.source_stack.add_titled_with_icon(url_page, "url", "YouTube", "web-browser-symbolic")
        self.source_stack.set_visible_child_name(self.cfg.get("source", "screen"))
        self.source_stack.connect("notify::visible-child-name", lambda *_: self.update_sound_visibility())

        # Sound (for screen sharing; files and online videos bring their own)
        self.sound_group = Adw.PreferencesGroup(title="Sound",
                                                description="What viewers hear. Programs only appear while they "
                                                            "have sound open.")
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", valign=Gtk.Align.CENTER, tooltip_text="Refresh")
        refresh.add_css_class("flat")
        refresh.connect("clicked", lambda *_: self.refresh_sounds())
        self.sound_group.set_header_suffix(refresh)
        left.append(self.sound_group)

        # Preview
        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        middle.append(right)
        frame = Gtk.Overlay()
        frame.add_css_class("preview-frame")
        frame.set_overflow(Gtk.Overflow.HIDDEN)
        holder = Gtk.Box()
        holder.set_size_request(-1, 260)
        self.video = Gtk.Video(autoplay=True, loop=False, hexpand=True, visible=False)
        holder.append(self.video)
        frame.set_child(holder)
        self.preview_hint = Gtk.Label(label="A preview of what viewers see appears here", wrap=True,
                                      justify=Gtk.Justification.CENTER)
        self.preview_hint.add_css_class("preview-hint")
        frame.add_overlay(self.preview_hint)
        right.append(frame)
        self.preview_switch = Gtk.CheckButton(label="Preview", active=self.cfg.get("preview", True))
        self.preview_switch.set_tooltip_text("Turning this off saves CPU. Viewers aren't affected.")
        self.preview_switch.connect("toggled", lambda *_: self.update_preview())
        right.append(self.preview_switch)

        # --- The Video Player Link ---
        link_group = Adw.PreferencesGroup(title="Video Player Link",
                                          description="Paste this into a video player in your VR game. "
                                                      "Anyone with it can watch until you stop.")
        self.link_row = Adw.ActionRow(title="Press Start streaming to get a link")
        self.link_row.add_css_class("property")
        self.link_row.set_subtitle_selectable(True)
        self.copy_btn = Gtk.Button(label="Copy", valign=Gtk.Align.CENTER, sensitive=False)
        self.copy_btn.connect("clicked", lambda *_: self.copy_link())
        self.qr_btn = Gtk.Button(label="QR", valign=Gtk.Align.CENTER, sensitive=False,
                                 tooltip_text="Show this link as a QR code, for phones")
        self.qr_btn.connect("clicked", lambda *_: self.show_qr())
        self.link_row.add_suffix(self.copy_btn)
        self.link_row.add_suffix(self.qr_btn)
        link_group.add(self.link_row)
        page.insert_child_after(link_group, self.slow_box)

        # --- Options ---
        opts = Adw.PreferencesGroup(title="Options")
        self.quality = Adw.ComboRow(title="Picture size", subtitle="Keep 1080p or lower for standalone headsets",
                                    model=Gtk.StringList.new(["720p", "1080p", "1440p"]))
        self.quality.set_selected({720: 0, 1080: 1, 1440: 2}.get(self.cfg.get("height", 1080), 1))
        self.fps = Adw.ComboRow(title="Frames per second", model=Gtk.StringList.new(["30", "60"]))
        self.fps.set_selected(1 if self.cfg.get("fps", 30) == 60 else 0)
        self.bitrate = Adw.ComboRow(title="Quality", subtitle="Each viewer uses about this much of your upload",
                                    model=Gtk.StringList.new(["2 Mbit/s", "4 Mbit/s", "6 Mbit/s", "8 Mbit/s"]))
        self.bitrate.set_selected(["2M", "4M", "6M", "8M"].index(self.cfg.get("bitrate", "4M"))
                                  if self.cfg.get("bitrate", "4M") in ["2M", "4M", "6M", "8M"] else 1)
        enc_names = [("nvenc", "NVIDIA graphics card"), ("vaapi", "AMD or Intel graphics (VA-API)"),
                     ("cpu", "Processor (x264)")]
        self.enc_keys = [k for k, _ in enc_names]
        self.encoder = Adw.ComboRow(title="Video encoding", subtitle="The graphics card uses much less CPU",
                                    model=Gtk.StringList.new([n for _, n in enc_names]))
        self.encoder.set_selected(self.enc_keys.index(self.cfg.get("encoder", engine.default_encoder())))
        self.tunnel = Adw.ComboRow(title="Link type", model=Gtk.StringList.new(
            ["Free Cloudflare link (new address each time)", "Your permanent Cloudflare link"]))
        self.tunnel.set_selected(1 if self.cfg.get("tunnel") == "permanent" else 0)
        self.perm_host = Adw.EntryRow(title="Permanent address, e.g. stream.example.com",
                                      text=self.cfg.get("permanent_host", ""))
        self.perm_token = Adw.PasswordEntryRow(title="Tunnel token", text=self.cfg.get("tunnel_token", ""))
        self.tunnel.connect("notify::selected", lambda *_: self.update_tunnel_rows())
        self.public = Adw.SwitchRow(title="Make a Video Player Link",
                                    subtitle="Off: stream only on this PC, for testing",
                                    active=self.cfg.get("public", True))
        for row in (self.quality, self.fps, self.bitrate, self.encoder, self.public, self.tunnel, self.perm_host,
                    self.perm_token):
            opts.add(row)
        page.append(opts)
        tip = Gtk.Label(label="Don't start and stop streams too many times too quickly, or Cloudflare may rate "
                              "limit you and you'll have to wait before you can get a new Video Player Link.",
                        wrap=True, xalign=0)
        tip.add_css_class("tip")
        page.append(tip)
        legal = Gtk.Label(label="Only stream what you have the right to share. Viewers see everything on the screen "
                                "or window you share, including notifications.", wrap=True, xalign=0)
        legal.add_css_class("tip")
        page.append(legal)

        # Drop a file on the window
        drop = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)
        drop.connect("drop", self.on_drop)
        self.add_controller(drop)
        self.connect("close-request", self.on_close)

        self.update_tunnel_rows()
        self.refresh_sounds()
        self.update_sound_visibility()
        if not self.screencast.available_types():
            self.screen_row.set_title("Screen sharing isn't available")
            self.screen_row.set_subtitle("Install xdg-desktop-portal and your desktop's portal (e.g. "
                                         "xdg-desktop-portal-gnome)")

    # --- Choosing what to stream ---
    def pick_screen(self, kind):
        if self.streamer:
            return self.toast("Stop the stream first to share something else.")
        self.screen_row.set_title("Waiting for you to choose in the desktop's dialog...")

        def done(err):
            if err:
                self.screen_row.set_title("Nothing chosen yet")
                self.screen_row.set_subtitle("Pick something to share")
                if err != "cancelled":
                    self.toast(err)
                return
            w, h = self.screencast.size
            what = "Monitor" if self.screencast.source_type == portal.MONITOR else "Window"
            self.screen_row.set_title(f"{what} chosen")
            self.screen_row.set_subtitle(f"{w} × {h}. Keep it open while streaming.")

        self.screencast.pick(kind, done)

    def browse(self):
        dialog = Gtk.FileDialog(title="Pick a video or music file to stream")
        filt = Gtk.FileFilter(name="Video and music")
        for ext in engine.MEDIA_EXTENSIONS:
            filt.add_suffix(ext.lstrip("."))
        filters = Gio.ListStore.new(Gtk.FileFilter)
        filters.append(filt)
        dialog.set_filters(filters)

        def done(d, res):
            try:
                f = d.open_finish(res)
            except GLib.Error:
                return
            if f and f.get_path():
                self.file_row.set_text(f.get_path())

        dialog.open(self, None, done)

    def on_drop(self, _target, value, _x, _y):
        files = value.get_files()
        if files and files[0].get_path():
            self.file_row.set_text(files[0].get_path())
            self.source_stack.set_visible_child_name("file")
            return True
        return False

    def paste_url(self):
        def done(cb, res):
            try:
                text = cb.read_text_finish(res)
            except GLib.Error:
                return
            if text:
                self.url_row.set_text(text.strip())

        self.get_clipboard().read_text_async(None, done)

    # --- Sound ---
    def refresh_sounds(self):
        chosen = {d["key"]: d for d in self.cfg.get("sounds", [{"kind": "pc", "key": "default",
                                                                  "label": "", "volume": 1.0}])}
        # Keep what's ticked now, including programs that stopped making sound for a moment
        for row in self.sound_rows:
            if row.check.get_active():
                chosen[row.source.key] = row.source.to_json()
            else:
                chosen.pop(row.source.key, None)
            self.sound_group.remove(row)
        self.sound_rows = []
        sources = audio.list_sources()
        keys = {s.key for s in sources}
        for d in chosen.values():
            if d["key"] not in keys and d.get("kind") == "app":
                sources.append(audio.Source.from_json(d))
        for s in sources:
            if s.key in chosen:
                s.volume = float(chosen[s.key].get("volume", 1.0))
            row = SoundRow(s, s.key in chosen, self.sounds_changed)
            self.sound_group.add(row)
            self.sound_rows.append(row)

    def chosen_sounds(self):
        return [r.source for r in self.sound_rows if r.check.get_active()]

    def sounds_changed(self):
        if self.streamer and self.streamer.mixer:
            self.streamer.mixer.set_sources(self.chosen_sounds())

    def update_sound_visibility(self):
        self.sound_group.set_visible(self.source_stack.get_visible_child_name() == "screen")

    def update_tunnel_rows(self):
        perm = self.tunnel.get_selected() == 1
        self.perm_host.set_visible(perm)
        self.perm_token.set_visible(perm)

    # --- Streaming ---
    def gather(self):
        s = engine.Settings()
        s.source = self.source_stack.get_visible_child_name()
        s.file = self.file_row.get_text().strip()
        s.url = self.url_row.get_text().strip()
        s.loop = self.loop_row.get_active()
        s.height = [720, 1080, 1440][self.quality.get_selected()]
        s.fps = [30, 60][self.fps.get_selected()]
        s.bitrate = ["2M", "4M", "6M", "8M"][self.bitrate.get_selected()]
        s.encoder = self.enc_keys[self.encoder.get_selected()]
        s.public = self.public.get_active()
        s.tunnel = "permanent" if self.tunnel.get_selected() == 1 else "cloudflare"
        s.permanent_host = self.perm_host.get_text().strip()
        s.tunnel_token = self.perm_token.get_text().strip()
        s.sounds = self.chosen_sounds()
        return s

    def remember(self, s):
        self.cfg.update({
            "source": s.source, "file": s.file, "url": s.url, "loop": s.loop, "height": s.height, "fps": s.fps,
            "bitrate": s.bitrate, "encoder": s.encoder, "public": s.public, "tunnel": s.tunnel,
            "permanent_host": s.permanent_host, "tunnel_token": s.tunnel_token,
            "sounds": [x.to_json() for x in s.sounds], "preview": self.preview_switch.get_active(),
        })
        save_settings(self.cfg)

    def start(self):
        s = self.gather()
        if s.source == "screen" and not self.screencast.active:
            return self.toast("Choose a monitor or window to share first.")
        if s.source == "file" and not os.path.isfile(os.path.expanduser(s.file)):
            return self.toast("Choose a video or music file first.")
        if s.source == "url" and not urlparse(s.url).scheme.startswith("http"):
            return self.toast("Paste a video link first (it starts with https://).")
        if s.public and s.tunnel == "permanent" and not (s.permanent_host and s.tunnel_token):
            return self.toast("Fill in your permanent address and tunnel token, or use a free link.")
        self.remember(s)
        self.start_btn.set_visible(False)
        self.stop_btn.set_visible(True)
        self.set_status("Starting...")
        self.streamer = engine.Streamer(s, self.screencast, lambda k, v: GLib.idle_add(self.on_event, k, v))
        self.streamer.preview_on = self.preview_switch.get_active()
        self.streamer.start()

    def stop(self):
        if self.streamer:
            st = self.streamer
            self.set_status("Stopping...")
            GLib.Thread.new(None, lambda: st.stop())

    def on_event(self, kind, value):
        st = self.streamer
        if kind == "status":
            if value.startswith("Downloading") and "..." in value:
                self.progress.set_visible(True)
                self.progress.pulse()
            elif value.startswith("Downloaded"):
                self.progress.set_visible(False)
            self.set_status(value)
        elif kind == "link":
            self.set_link(value)
        elif kind == "live":
            self.live_pill.set_visible(bool(value))
            self.update_preview()
        elif kind == "viewers":
            self.viewers.set_label(f"About {value} viewer{'s' if value != 1 else ''}" if value else "No viewers yet")
        elif kind == "slow":
            self.show_slow_warning(value if st else None)
        elif kind == "stopped":
            self.show_slow_warning(None)
            self.progress.set_visible(False)
            self.start_btn.set_visible(True)
            self.stop_btn.set_visible(False)
            self.viewers.set_label("")
            self.live_pill.set_visible(False)
            if value:
                self.set_status("Stopped: " + value.splitlines()[0])
                self.toast(value.splitlines()[0])
            elif not self.status.get_label().startswith("Finished"):
                self.set_status("Stopped")
            self.last_streamer = st
            self.streamer = None
            self.update_preview()
            self.update_sound_visibility()
        return False

    def show_slow_warning(self, speed):
        """The red box: shown while the stream encodes slower than real time, with what would fix it for the
        settings this stream was started with. speed None hides it."""
        if speed is None or not self.streamer:
            self.slow_box.set_visible(False)
            return
        s = self.streamer.s
        fixes = []
        if s.encoder == "cpu" and engine.has_nvidia():
            fixes.append("set Video encoding to NVIDIA graphics card")
        elif s.encoder == "cpu" and engine.has_vaapi():
            fixes.append("set Video encoding to AMD or Intel graphics")
        if s.fps == 60:
            fixes.append("set Frames per second to 30")
        if s.height > 720:
            fixes.append("pick a smaller Picture size")
        if fixes:
            how = (", ".join(fixes[:-1]) + " or " + fixes[-1]) if len(fixes) > 1 else fixes[0]
            detail = f"To fix it, {how}, then stop and start the stream again."
        else:
            detail = "Your settings are already as light as they go, so close other demanding programs to free up the PC."
        self.slow_title.set_label(f"Your PC can't encode the stream fast enough (only {speed:.0%} speed)")
        self.slow_detail.set_label("The picture is falling behind the sound, so viewers see them out of sync. " + detail)
        self.slow_box.set_visible(True)

    def set_status(self, text):
        self.status.set_label(text)

    def set_link(self, url):
        self.link = url
        if url:
            self.link_row.set_title(url)
            self.link_row.set_subtitle("Works for everyone, PC and Quest/Steam Frame")
            self.copy_link(quiet=True)
            self.toast("Video Player Link copied. Paste it into the video player with Ctrl+V.")
        else:
            streaming = self.streamer is not None
            self.link_row.set_title("Opening the link..." if streaming and self.gather().public else
                                    "Press Start streaming to get a link")
            self.link_row.set_subtitle("" if self.gather().public else "Turned off in Options")
        self.copy_btn.set_sensitive(bool(url))
        self.qr_btn.set_sensitive(bool(url))

    def copy_link(self, quiet=False):
        if self.link:
            self.get_clipboard().set(self.link)
            if not quiet:
                self.toast("Copied.")

    def show_qr(self):
        if not self.link:
            return
        modules = qr.encode(self.link)
        n, border, scale = len(modules), 4, 8
        size = (n + border * 2) * scale
        pixels = bytearray(b"\xff" * size * size * 3)
        for y in range(n):
            for x in range(n):
                if modules[y][x]:
                    for dy in range(scale):
                        row = ((y + border) * scale + dy) * size
                        start = (row + (x + border) * scale) * 3
                        pixels[start:start + scale * 3] = b"\x00" * (scale * 3)
        texture = Gdk.MemoryTexture.new(size, size, Gdk.MemoryFormat.R8G8B8, GLib.Bytes.new(bytes(pixels)), size * 3)
        pic = Gtk.Picture.new_for_paintable(texture)
        pic.set_size_request(360, 360)
        pic.set_can_shrink(True)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin_top=12, margin_bottom=12,
                      margin_start=12, margin_end=12)
        box.append(pic)
        lbl = Gtk.Label(label=self.link, wrap=True, selectable=True)
        lbl.add_css_class("dim-label")
        box.append(lbl)
        dialog = Adw.Dialog(title="Video Player Link", content_width=420)
        tv = Adw.ToolbarView()
        tv.add_top_bar(Adw.HeaderBar())
        tv.set_content(box)
        dialog.set_child(tv)
        dialog.present(self)

    # --- Preview: plays the local stream, so it shows exactly what viewers get ---
    def update_preview(self):
        want = bool(self.streamer and self.live_pill.get_visible() and self.preview_switch.get_active())
        if self.streamer:
            self.streamer.preview_on = want
        current = self.video.get_media_stream()
        if want and current is None:
            media = Gtk.MediaFile.new_for_file(Gio.File.new_for_uri(LOCAL_HLS))
            media.set_muted(True)   # it would be heard again by "Everything you hear on this PC"
            media.connect("notify::error", self.on_preview_error)
            self.video.set_media_stream(media)
            self.video.set_visible(True)
            media.play()
            self.preview_hint.set_visible(False)
        elif not want and current is not None:
            current.pause()
            self.video.set_media_stream(None)
            self.video.set_visible(False)
            self.preview_hint.set_visible(True)
            self.preview_hint.set_label("Preview is off" if self.streamer else
                                        "A preview of what viewers see appears here")

    def on_preview_error(self, media, _pspec):
        if media.get_error() and self.video.get_media_stream() is media:
            self.video.set_media_stream(None)
            if self._preview_retry is None:
                def retry():
                    self._preview_retry = None
                    self.update_preview()
                    return False
                self._preview_retry = GLib.timeout_add_seconds(2, retry)

    # --- Menu ---
    def copy_report(self):
        st = self.streamer or getattr(self, "last_streamer", None)
        s = self.gather()
        lines = [
            f"VR Video Streamer for Linux {VERSION}",
            f"{platform.freedesktop_os_release().get('PRETTY_NAME', 'Linux')} | kernel {platform.release()} | "
            f"{os.environ.get('XDG_CURRENT_DESKTOP', '?')} on {os.environ.get('XDG_SESSION_TYPE', '?')}",
            f"Python {platform.python_version()}",
            f"Source: {s.source} | {s.height}p {s.fps} fps {s.bitrate} | encoder {s.encoder} | "
            f"link {'on (' + s.tunnel + ')' if s.public else 'off'}",
            f"Sound: {', '.join(f'{x.kind}:{x.label} {int(x.volume * 100)}%' for x in s.sounds) or 'none'}",
            f"Tools: " + ", ".join(f"{n}={'yes' if tools.find(n) else 'no'}" for n in tools.DOWNLOADS),
            "", "Recent log:", st.recent_log if st else "(nothing streamed yet)",
        ]
        self.get_clipboard().set("\n".join(lines))
        self.toast("Problem report copied. Paste it into a new issue on GitHub.")

    def open_tools(self):
        tools.TOOLS_DIR.mkdir(parents=True, exist_ok=True)
        Gtk.FileLauncher.new(Gio.File.new_for_path(str(tools.TOOLS_DIR))).launch(self, None, None)

    def show_about(self):
        about = Adw.AboutDialog(application_name="VR Video Streamer", version=VERSION,
                                comments="Stream your screen, windows, video files and online videos to VR video "
                                         "players.",
                                website="https://github.com/Kubi-Cle/VR-Video-Streamer",
                                license_type=Gtk.License.CUSTOM,
                                license="Free for noncommercial use under the PolyForm Noncommercial License 1.0.0. "
                                        "Downloaded tools (MediaMTX, cloudflared, yt-dlp, Deno) keep their own "
                                        "licences.")
        about.present(self)

    def toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=GLib.markup_escape_text(text), timeout=4))

    def on_close(self, *_):
        if self.streamer:
            self.streamer.stop()
        self.screencast.close()
        return False


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_activate(self):
        win = self.get_active_window() or Window(self)
        win.present()


def run(argv):
    from gi.repository import Gst
    Gst.init(None)
    return App().run(argv)
