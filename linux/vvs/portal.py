"""Screen and window capture on Wayland, through the desktop's ScreenCast portal.

GNOME (and KDE) don't let programs read the screen directly. Instead the desktop shows its own "share your
screen" dialog, and hands back a PipeWire stream of what the person picked. That stream is what GStreamer's
pipewiresrc reads (see engine.py). The session has to stay open for as long as the stream is used.
"""
import itertools
import os

from gi.repository import Gio, GLib

BUS_NAME = "org.freedesktop.portal.Desktop"
OBJECT_PATH = "/org/freedesktop/portal/desktop"
SCREENCAST = "org.freedesktop.portal.ScreenCast"
REQUEST = "org.freedesktop.portal.Request"

MONITOR, WINDOW = 1, 2
CURSOR_EMBEDDED = 2
PERSIST_UNTIL_REVOKED = 2

_tokens = itertools.count()


class PortalError(Exception):
    pass


class ScreenCast:
    """One capture session. pick() shows the desktop's dialog; after it succeeds, node_id, fd and size are set."""

    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.session = None
        self.node_id = None
        self.fd = None
        self.size = None
        self.source_type = None
        self.restore_token = None
        self._sender = self.bus.get_unique_name()[1:].replace(".", "_")

    # --- The portal answers each call later, with a Response signal on a Request object ---
    def _request(self, method, args_before_options, options, done):
        token = f"vvs{os.getpid()}_{next(_tokens)}"
        options = dict(options)
        options["handle_token"] = GLib.Variant("s", token)
        path = f"/org/freedesktop/portal/desktop/request/{self._sender}/{token}"
        sub = None

        def on_response(_bus, _sender, _path, _iface, _signal, params):
            self.bus.signal_unsubscribe(sub)
            code, results = params.unpack()
            done(code, results)

        sub = self.bus.signal_subscribe(BUS_NAME, REQUEST, "Response", path, None,
                                        Gio.DBusSignalFlags.NO_MATCH_RULE, on_response)
        params = GLib.Variant(f"({''.join(t for t, _ in args_before_options)}a{{sv}})",
                              tuple(v for _, v in args_before_options) + (options,))

        def on_called(bus, res):
            try:
                bus.call_finish(res)
            except GLib.Error as e:
                self.bus.signal_unsubscribe(sub)
                done(-1, {"error": str(e.message)})

        self.bus.call(BUS_NAME, OBJECT_PATH, SCREENCAST, method, params, None, Gio.DBusCallFlags.NONE, -1, None,
                      on_called)

    def available_types(self):
        """Bitmask of what the portal can capture (1 = monitors, 2 = windows), or 0 when there's no portal."""
        try:
            v = self.bus.call_sync(BUS_NAME, OBJECT_PATH, "org.freedesktop.DBus.Properties", "Get",
                                   GLib.Variant("(ss)", (SCREENCAST, "AvailableSourceTypes")), None,
                                   Gio.DBusCallFlags.NONE, 3000, None)
            return v.unpack()[0]
        except GLib.Error:
            return 0

    def pick(self, source_type, on_done, restore_token=None):
        """Asks the person what to share. on_done(error_text_or_None) runs on the main loop."""
        self.close()
        fail = lambda text: on_done(text)

        def after_create(code, results):
            if code != 0:
                return fail(results.get("error") or "The desktop refused to start screen sharing.")
            self.session = results["session_handle"]
            opts = {
                "types": GLib.Variant("u", source_type),
                "multiple": GLib.Variant("b", False),
                "cursor_mode": GLib.Variant("u", CURSOR_EMBEDDED),
                "persist_mode": GLib.Variant("u", PERSIST_UNTIL_REVOKED),
            }
            if restore_token:
                opts["restore_token"] = GLib.Variant("s", restore_token)
            self._request("SelectSources", [("o", self.session)], opts, after_select)

        def after_select(code, results):
            if code != 0:
                return fail(results.get("error") or "Screen sharing was cancelled.")
            self._request("Start", [("o", self.session), ("s", "")], {}, after_start)

        def after_start(code, results):
            if code == 1:
                self.close()
                return fail("cancelled")
            if code != 0:
                self.close()
                return fail(results.get("error") or "Screen sharing didn't start.")
            streams = results.get("streams") or []
            if not streams:
                self.close()
                return fail("Nothing was picked to share.")
            node_id, props = streams[0]
            self.node_id = node_id
            self.size = tuple(props.get("size") or (1920, 1080))
            self.source_type = props.get("source_type", source_type)
            self.restore_token = results.get("restore_token")
            try:
                self.fd = self._open_pipewire_remote()
            except GLib.Error as e:
                self.close()
                return fail(f"Couldn't connect to the shared screen: {e.message}")
            on_done(None)

        session_token = f"vvs_session{os.getpid()}_{next(_tokens)}"
        self._request("CreateSession", [], {"session_handle_token": GLib.Variant("s", session_token)},
                      after_create)

    def _open_pipewire_remote(self):
        result, fd_list = self.bus.call_with_unix_fd_list_sync(
            BUS_NAME, OBJECT_PATH, SCREENCAST, "OpenPipeWireRemote",
            GLib.Variant("(oa{sv})", (self.session, {})), GLib.VariantType("(h)"),
            Gio.DBusCallFlags.NONE, -1, None, None)
        return fd_list.get(result.unpack()[0])

    @property
    def active(self):
        return self.session is not None and self.fd is not None

    def close(self):
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None
        if self.session:
            try:
                self.bus.call_sync(BUS_NAME, self.session, "org.freedesktop.portal.Session", "Close", None, None,
                                   Gio.DBusCallFlags.NONE, 2000, None)
            except GLib.Error:
                pass
            self.session = None
        self.node_id = None
