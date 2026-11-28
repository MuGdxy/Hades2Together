"""Collect the original license texts for a completed Windows x64 source build."""

import argparse
import json
from pathlib import Path
import shutil
import tomllib
from urllib.request import urlopen


HERE = Path(__file__).resolve().parent
PROGGY_COMMIT = "139ec08a38096161291792313ef5803fc4f0e37b"
LICENSE_FILES = {
    "asynclogger": ("LICENSE",),
    "capstone": ("LICENSES/LICENSE.TXT", "LICENSES/LICENSE_BSD_3_CLAUSE.txt",
                 "LICENSES/LICENSE_LLVM.TXT"),
    "corrosion": ("LICENSE",),
    "cpp-semver": ("LICENSE",),
    "eastl": ("LICENSE", "3RDPARTYLICENSES.TXT", "test/packages/EABase/LICENSE"),
    "hashmap": ("LICENSE",),
    "imgui": ("LICENSE.txt",),
    "json": ("LICENSE.MIT",),
    "lovely_lib": ("LICENSE.md",),
    "luasocket": ("LICENSE",),
    "magic_enum": ("LICENSE",),
    "polyhook": ("LICENSE", "asmjit/LICENSE.md", "asmtk/LICENSE.md", "zydis/LICENSE",
                 "zydis/dependencies/zycore/LICENSE"),
    "pugixml": ("LICENSE.md",),
    "raw_pdb": ("LICENSE",),
    "rom": ("LICENSE",),
    "safetyhook": ("LICENSE",),
    "sol2": ("LICENSE.txt",),
    "toml++": ("LICENSE",),
}


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit", required=True, type=Path)
    parser.add_argument("--deps", required=True, type=Path)
    parser.add_argument("--cargo-home", required=True, type=Path)
    parser.add_argument("--rust-doc", required=True, type=Path)
    args = parser.parse_args()

    kit, deps = args.kit, args.deps
    licenses = kit / "licenses"
    for name, paths in LICENSE_FILES.items():
        for path in paths:
            copy(deps / name / path, licenses / name / path)
    copy(HERE.parent.parent / "LICENSE", licenses / "Hades2Together/LICENSE")
    copy(kit / "loader/LICENSE", licenses / "Hell2Modding/LICENSE")
    for filename in ("LICENSE.txt", "LICENSE-NVDA.txt"):
        copy(kit / "tolk" / filename, licenses / "tolk" / filename)
    copy(deps / "json/LICENSES/GPL-3.0-only.txt", licenses / "tolk/GPL-3.0.txt")

    lpeg = (deps / "lpeg/lpeg.html").read_bytes()
    lpeg_notice = lpeg.split(b'<h2><a name="license">License</a></h2>', 1)[1].split(b"</div>", 1)[0]
    (licenses / "lpeg").mkdir(exist_ok=True)
    (licenses / "lpeg/LICENSE.html").write_bytes(lpeg_notice.strip() + b"\n")
    lua = (deps / "lua_static/lua.h").read_bytes()
    (licenses / "lua_static").mkdir(exist_ok=True)
    start = lua.index(b"* Copyright (C) 1994-2013 Lua.org")
    end = lua.index(b"*/", start)
    (licenses / "lua_static/COPYRIGHT.txt").write_bytes(lua[start:end].rstrip(b"*\r\n") + b"\n")

    for file in ("imstb_rectpack.h", "imstb_textedit.h", "imstb_truetype.h"):
        source = (deps / "imgui" / file).read_bytes()
        start = source.rindex(b"This software is available under 2 licenses")
        (licenses / "imgui" / f"{file}.LICENSE.txt").write_bytes(source[start:])
    with urlopen(f"https://raw.githubusercontent.com/bluescan/proggyfonts/{PROGGY_COMMIT}/LICENSE",
                 timeout=20) as response:
        (licenses / "imgui/ProggyClean-LICENSE.txt").write_bytes(response.read())

    for file in (args.rust_doc / "licenses").glob("*.txt"):
        copy(file, licenses / "rust-library/licenses" / file.name)
    copy(args.rust_doc / "COPYRIGHT-library.html", licenses / "rust-library/COPYRIGHT-library.html")
    copy(deps / "lovely_lib/Cargo.lock", kit / "Cargo.lock")
    locked = {
        (item["name"], item["version"]): item
        for item in tomllib.loads((kit / "Cargo.lock").read_text(encoding="utf-8"))["package"]
        if "checksum" in item
    }
    crates = []
    for root in sorted((args.cargo_home / "registry/src").glob("*/*/Cargo.toml")):
        manifest = tomllib.loads(root.read_text(encoding="utf-8"))["package"]
        name, version = manifest["name"], manifest["version"]
        if (name, version) not in locked:
            raise ValueError(f"Unexpected crate in clean registry: {name} {version}")
        texts = [
            path for path in root.parent.iterdir()
            if path.is_file() and path.name.upper().startswith(
                ("LICENSE", "COPYING", "COPYRIGHT", "UNLICENSE", "NOTICE"))
        ]
        if not texts:
            raise ValueError(f"No license text for {name} {version}")
        for text in texts:
            copy(text, licenses / "rust-crates" / root.parent.name / text.name)
        crates.append({"name": name, "version": version, "license": manifest.get("license"),
                       "checksum": locked[name, version]["checksum"]})
    if not crates:
        raise ValueError("The clean Cargo registry did not contain any locked crates")
    (licenses / "rust-crates.json").write_text(json.dumps(crates, indent=2) + "\n",
                                               encoding="utf-8")
    shutil.copyfile(HERE / "README.md", kit / "README.md")
    shutil.copyfile(HERE / "NOTICE.txt", kit / "NOTICE.txt")


if __name__ == "__main__":
    main()
