"""Helper programs die with this one, however it ends (the Linux counterpart of KillOnClose.cs)."""
import ctypes
import queue
import signal
import subprocess
import threading

_libc = ctypes.CDLL("libc.so.6", use_errno=True)


def _die_with_parent():
    """Everything started from here dies with this program, however it ends (Linux's KillOnClose.cs)."""
    _libc.prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG


class _Spawner:
    """Starts every helper program from one thread that lives as long as this program.

    Linux sends PR_SET_PDEATHSIG when the *thread* that started a process ends, not the whole program, so
    processes started from short-lived worker threads would be stopped as soon as that thread finished.
    """

    def __init__(self):
        self.jobs = queue.Queue()
        threading.Thread(target=self._work, daemon=True, name="spawner").start()

    def _work(self):
        while True:
            args, kw, box, done = self.jobs.get()
            try:
                box["proc"] = subprocess.Popen(args, preexec_fn=_die_with_parent, **kw)
            except Exception as e:
                box["error"] = e
            done.set()

    def popen(self, args, **kw):
        box, done = {}, threading.Event()
        self.jobs.put((args, kw, box, done))
        done.wait()
        if "error" in box:
            raise box["error"]
        return box["proc"]


_spawner = _Spawner()


def popen(args, **kw):
    return _spawner.popen(args, **kw)
