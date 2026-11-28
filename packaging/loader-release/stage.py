"""Stage the source companion from the frozen party preview build inputs."""

import argparse
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path
import re
import shutil
import subprocess
from zipfile import ZipFile


HERE = Path(__file__).resolve().parent
BASE = "a80069739d1333591c7ddfb89b606d9101bd31f4"
ORIGINAL = "f59a2c62cad30b1e76be7e8de39ed83376c9792942d6ca707dfe60ad895339f5"
HADES = Path("src/lua_extensions/bindings/hades")
PROXY_URL = "https://github.com/SGG-Modding/Hell2Modding"
PARTY_HEADERS = (
    "active-sample-core.hpp", "active-sample-runtime.hpp", "guest-descriptor.hpp",
    "guest-staff.hpp", "observe-sampler-candidate.hpp", "observe-sampler-core.hpp",
    "observe-sampler-lua.hpp", "observe-sampler-runtime.hpp", "player-slots.hpp",
    "private-player.hpp", "secondary-owner.hpp",
)


def git(source, *args):
    return subprocess.check_output(("git", "-C", str(source), *args))


def archive(source, commit, destination, *paths):
    with ZipFile(BytesIO(git(source, "archive", "--format=zip", commit, *paths))) as zipped:
        zipped.extractall(destination)


def checked_replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Expected exactly one source match for {old[:50]!r}")
    return text.replace(old, new)


def edit(path, transform):
    text = path.read_text(encoding="utf-8")
    updated = transform(text)
    path.write_text(updated, encoding="utf-8", newline="\n")


def hex_array(text):
    return bytes(int(value, 16) for value in re.findall(r"0x([0-9a-fA-F]{2})\b", text))


def escaped_bytes(text):
    return bytes.fromhex(text.replace("\\x", ""))


def change_guards(loader, overlay):
    """Replace the fixed party byte comparisons with SHA-256 equality checks."""
    sites = []

    def guard(rva, old_bytes, size):
        if len(old_bytes) != size:
            raise ValueError("Source slice length disagrees with its comparison")
        digest = sha256(old_bytes).hexdigest()
        sites.append({"rva": int(rva, 16), "length": size, "sha256": digest})
        return f'{size}, "{digest}"'

    constructor = (overlay / "player-constructor-bytes.hpp").read_text(encoding="utf-8")

    def private_player(text):
        unwind = re.search(r"    constexpr std::array<unsigned char, 26> unwind\{([^}]+)\};\n", text)
        text = checked_replace(text, unwind[0], "")
        text = checked_replace(
            text, "read<std::array<unsigned char, 26>>(base + f->UnwindData) != unwind",
            f"!h2t_release::matches(base + f->UnwindData, {guard('0x51a74c', hex_array(unwind[1]), 26)})")
        for name, rva, size in (
                ("ctorPrefix", "0x1c98d0", 176), ("ctorBoundary", "0x1c9980", 18),
                ("ctorEpilogue", "0x1c9b7a", 32)):
            values = re.search(rf"{name}\{{([^}}]+)\}};", constructor)[1]
            text = checked_replace(text,
                f"read<std::array<unsigned char, {name}.size()>>(base + {rva}) != {name}",
                f"!h2t_release::matches(base + {rva}, {guard(rva, hex_array(values), size)})")
        text = checked_replace(text, '#include "player-constructor-bytes.hpp"\n', "")
        return checked_replace(text, "    using namespace h2t_seat_owner_bytes;\n", "")

    def data(text):
        old = re.search(r"read<std::array<unsigned char,5>>\(base\+(0x[0-9a-f]+)\)"
                        r"!=std::array<unsigned char,5>\{([^}]+)\}", text)
        return checked_replace(text, old[0],
            f"!h2t_release::matches(base + {old[1]}, {guard(old[1], hex_array(old[2]), 5)})")

    def sampler(text):
        old_sites = re.compile(r'Site\{(0x[0-9a-f]+), \{"((?:\\x[0-9a-f]{2})+)", (\d+)\},')
        text, count = old_sites.subn(
            lambda m: f"Site{{{m[1]}, {guard(m[1], escaped_bytes(m[2]), int(m[3]))},", text)
        if count != 26:
            raise ValueError(f"Expected 26 sampler sites, got {count}")
        text = checked_replace(text, "    std::string_view bytes;",
                               "    std::size_t size;\n    std::string_view sha256;")
        start = text.index("            std::array<char,16> actual{};")
        end = text.index("\n        }", start)
        text = text[:start] + (
            "            if (!h2t_release::matches(image_ + site.rva, site.size, site.sha256)) return false;"
        ) + text[end:]
        text = checked_replace(text, "site.bytes.size()", "site.size")
        return checked_replace(text, '#include "observe-sampler-core.hpp"',
            '#include "observe-sampler-core.hpp"\n#include "release-guard.hpp"')

    def owner(text):
        start = text.index("        const auto matches=[](Addr rva,std::string_view bytes) {")
        end = text.index("        if (!matches(", start)
        text = text[:start] + text[end:]
        old = re.compile(r'matches\((0x[0-9a-f]+),"((?:\\x[0-9a-f]{2})+)"sv\)')
        def replace(match):
            values = escaped_bytes(match[2])
            return f"h2t_release::matches(game_base + {match[1]}, {guard(match[1], values, len(values))})"
        text, count = old.subn(replace, text)
        if count != 4:
            raise ValueError(f"Expected four owner sites, got {count}")
        return text

    for name, transform in (
            ("private-player.hpp", private_player), ("data.cpp", data),
            ("observe-sampler-candidate.hpp", sampler), ("secondary-owner.hpp", owner)):
        edit(loader / HADES / name, transform)
    shutil.copyfile(HERE / "release-guard.hpp", loader / HADES / "release-guard.hpp")
    return sites


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True, help="Original active-runtime-source directory")
    parser.add_argument("--party", type=Path, required=True, help="Original party-team-build directory")
    parser.add_argument("--out", type=Path, required=True, help="Fresh source staging directory")
    args = parser.parse_args()
    base, party, out = args.base.resolve(), args.party.resolve(), args.out.resolve()
    original_hash = sha256((party / "d3d12.dll").read_bytes()).hexdigest()
    if original_hash != ORIGINAL:
        raise ValueError(f"Unexpected party-team DLL: {original_hash}")
    if any(root == out or root in out.parents for root in (base, party)):
        raise ValueError("Output must be outside the input trees")
    out.mkdir()
    loader = out / "loader"
    archive(base / "Hell2Modding", BASE, loader, "LICENSE", "CMakeLists.txt", "cmake_scripts", "src")
    overlay = party / "Hell2Modding" / HADES
    for name in (*PARTY_HEADERS, "data.cpp"):
        shutil.copyfile(overlay / name, loader / HADES / name)
    # The final original command compiled the party main outside the loader tree.
    shutil.copyfile(party / "main.cpp", loader / "src/main.cpp")
    edit(loader / "src/main.cpp", lambda text: re.sub(
        r"(?m)^([^\n]*// \[0\] )C:\\Users\\[^\n]+(ltable.cpp:483 luaH_get)$",
        r"\1\2", text))
    shutil.copyfile(base / "Hell2Modding/src/version.cpp", loader / "src/version.cpp")
    edit(loader / "CMakeLists.txt", lambda text: checked_replace(
        text, "include(cmake_scripts/git.cmake)\n", ""))
    (loader / "cmake_scripts/git.cmake").unlink()
    edit(loader / "cmake_scripts/lovely.cmake", lambda text: checked_replace(
        checked_replace(text, '    "C:/Users/Quentin/source/repos/lovely-lib/target/release/lovely_lib.lib"\n', ""),
        "    set(LOVELY_LIB \"lovely_lib\")",
        "    corrosion_set_cargo_flags(lovely_lib --locked)\n    set(LOVELY_LIB \"lovely_lib\")"))

    deps = json.loads((HERE / "dependencies.json").read_text(encoding="utf-8"))
    tolk = next(entry["commit"] for entry in deps if entry["name"] == "tolk")
    archive(base / "build-msvc/_deps/tolk-src", tolk, out / "tolk",
            "CMakeLists.txt", "LICENSE.txt", "LICENSE-NVDA.txt", "src", "docs/README.md")
    for filename in ("relink.py", "dependencies.json"):
        shutil.copyfile(HERE / filename, out / filename)

    provenance = {
        "upstream": PROXY_URL, "upstreamCommit": BASE,
        "originalPartyDllSha256": original_hash,
        "originalInputSha256": {
            name: sha256((party / name).read_bytes()).hexdigest()
            for name in ("build.cmd", "build.log", "main.cpp", "main.obj", "data.obj")
        },
        "originalPartyOverlaySha256": {
            name: sha256((overlay / name).read_bytes()).hexdigest()
            for name in (*PARTY_HEADERS, "data.cpp", "player-constructor-bytes.hpp")
        },
        "releaseGuards": change_guards(loader, overlay),
    }
    (out / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
