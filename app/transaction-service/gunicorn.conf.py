import os
import shutil

# Multiprocess prometheus_client requires this directory to exist and be
# empty on startup — stale .db files left over from a previous process
# (e.g. a container that crashed and restarted in place) get counted
# twice otherwise.
def on_starting(server):
    multiproc_dir = os.environ.get("PROMETHEUS_MULTIPROC_DIR")
    if not multiproc_dir:
        return
    shutil.rmtree(multiproc_dir, ignore_errors=True)
    os.makedirs(multiproc_dir, exist_ok=True)


# Without this, a worker's per-process metric files are left behind after
# it exits (graceful reload, --max-requests recycling, crash) and
# MultiProcessCollector keeps reporting its last values forever.
def child_exit(server, worker):
    from prometheus_client import multiprocess
    multiprocess.mark_process_dead(worker.pid)
