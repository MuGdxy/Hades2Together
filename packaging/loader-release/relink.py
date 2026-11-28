"""Build the Windows x64 companion from an extracted source archive."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(os.path.abspath(__file__)).parent


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def checkout(entry, destination):
    destination.mkdir(parents=True, exist_ok=True)
    git = ("git", "-C", str(destination), "-c", "core.longpaths=true",
           "-c", "core.autocrlf=false")
    run(*git, "init", "--quiet")
    run(*git, "fetch", "--quiet", "--depth=1", entry["url"], entry["commit"])
    if entry["name"] == "capstone":
        # Its disabled test suite contains paths too long for some Windows tools.
        run(*git, "sparse-checkout", "init", "--no-cone")
        run(*git, "sparse-checkout", "set", "--no-cone", "/*", "!/tests/")
    run(*git, "checkout", "--quiet", "--detach", entry["commit"])
    for child in entry.get("submodules", []):
        checkout(child, destination / child["path"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="Fresh build directory")
    parser.add_argument("--tolk-source", type=Path, default=ROOT / "tolk",
                        help="Source tree defining the compatible static Tolk target")
    parser.add_argument("--jobs", default=6, type=int)
    args = parser.parse_args()
    if not (args.tolk_source / "CMakeLists.txt").is_file():
        parser.error("Tolk source must contain CMakeLists.txt")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    out = Path(os.path.abspath(args.out))
    out.mkdir(parents=True)
    env = os.environ.copy()
    env.setdefault("RUSTUP_TOOLCHAIN", "nightly-2026-11-25-x86_64-pc-windows-msvc")
    pins = json.loads((ROOT / "dependencies.json").read_text(encoding="utf-8"))
    deps = out / "deps"
    with ThreadPoolExecutor(max_workers=min(args.jobs, 6)) as pool:
        futures = [pool.submit(checkout, entry, deps / entry["name"])
                   for entry in pins if entry["name"] != "tolk"]
        for future in futures:
            future.result()
    lock = ROOT / "Cargo.lock"
    if lock.is_file() and lock.read_text() != (deps / "lovely_lib/Cargo.lock").read_text():
        raise ValueError("The checked-out Rust dependency has a different Cargo.lock")
    overrides = [
        f"-DFETCHCONTENT_SOURCE_DIR_{entry['name'].upper()}={deps / entry['name']}"
        for entry in pins if entry["name"] != "tolk"
    ]
    build = out / "build"
    run("cmake", "-S", ROOT / "loader", "-B", build, "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=RelWithDebInfo", "-DFINAL=YES",
        "-DCMAKE_DISABLE_FIND_PACKAGE_Lua=ON",
        "-DFETCHCONTENT_FULLY_DISCONNECTED=ON",
        f"-DFETCHCONTENT_SOURCE_DIR_TOLK={os.path.abspath(args.tolk_source)}",
        *overrides, env=env)
    run("cmake", "--build", build, "--target", "Hell2Modding",
        "--parallel", str(args.jobs), env=env)
    shutil.copyfile(build / "d3d12_.dll", out / "d3d12.dll")
    print(f"Linked {out / 'd3d12.dll'}")


if __name__ == "__main__":
    main()
