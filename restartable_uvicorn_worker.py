import os
import signal
import threading
import time
from uvicorn.workers import UvicornWorker


class ReloaderThread(threading.Thread):
    """
    Thread that monitors the worker's alive status and sends SIGINT
    to restart the entire process when the worker dies.
    
    This fixes gunicorn issue #2339 where the file watcher thread
    exits with sys.exit(0) instead of restarting the worker.
    """

    def __init__(self, worker, sleep_interval=1.0):
        super().__init__()
        self.setDaemon(True)
        self._worker = worker
        self._interval = sleep_interval

    def run(self):
        while True:
            if not self._worker.alive:
                # Send SIGINT to restart the entire process instead of
                # just exiting the watcher thread (which is the bug)
                os.kill(os.getpid(), signal.SIGINT)
            time.sleep(self._interval)


class RestartableUvicornWorker(UvicornWorker):
    """
    UvicornWorker that fixes the reload-only-works-once issue.
    
    This addresses GitHub issue benoitc/gunicorn#2339 where the
    file watcher thread dies after the first reload, preventing
    subsequent reloads from working.
    """

    CONFIG_KWARGS = {"loop": "uvloop", "http": "httptools"}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._reloader_thread = ReloaderThread(self)

    def run(self):
        if self.cfg.reload:
            self._reloader_thread.start()
        super().run() 