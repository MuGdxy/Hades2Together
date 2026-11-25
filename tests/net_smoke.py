"""Launch one localhost authority and four independent Lua client processes."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def wait_for_file(path, processes):
    deadline = time.monotonic() + 10
    while not path.exists():
        for name, process in processes.items():
            if process.poll() is not None:
                raise RuntimeError(f"{name} exited before {path.name} was ready")
        if time.monotonic() >= deadline:
            raise TimeoutError(f"waiting for {path.name}")
        time.sleep(0.01)
    return path.read_text().strip()


def smoke(lua, directory):
    processes = {}
    output = {}

    def start(name, role, *args):
        process = subprocess.Popen(
            [lua, "tests/net_smoke.lua", role, str(directory), *map(str, args)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        print(f"{name} pid={process.pid}", flush=True)
        processes[name] = process

    try:
        start("authority", "serve")
        port = int(wait_for_file(directory / "port", processes))
        for seat, state in enumerate(((1, 0, 1), (0, 1, 2), (-1, 0, 4), (0, -1, 8)), 1):
            name = f"Player{seat}"
            start(name, "play", port, seat, *state)
            if int(wait_for_file(directory / name, processes)) != seat:
                raise RuntimeError(f"{name} received an unexpected seat")
        deadline = time.monotonic() + 20
        for name, process in processes.items():
            output[name], _ = process.communicate(timeout=max(1, deadline - time.monotonic()))
            if process.returncode:
                raise RuntimeError(f"{name} exited with code {process.returncode}")
        pattern = r"result tick=(\d+) enemy=(\d+) hp=(\d+) loot=(\d+)"
        results = {name: re.findall(pattern, log) for name, log in output.items()}
        server_result = results["authority"]
        if len(server_result) != 1 or any(result != server_result for result in results.values()):
            raise RuntimeError(f"processes disagreed on the authoritative result: {results}")
    finally:
        for name, process in processes.items():
            if process.poll() is None:
                process.kill()
            if name not in output:
                output[name], _ = process.communicate()
            if output[name]:
                print(f"{name} output\n{output[name].rstrip()}")
    print("All four client processes observed the same authoritative result")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="lua", help="Lua executable with require('socket') available")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="h2t-tcp-", dir=os.environ.get("AGENT_SERVER_TMP")) as scratch:
        smoke(options.lua, Path(scratch))
