"""Record the built DLL hash and write the companion ZIP beside the DLL."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit", required=True, type=Path)
    parser.add_argument("--dll", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    kit, out = args.kit.resolve(), args.out.resolve()
    if out == kit or kit in out.parents:
        parser.error("The archive must be written outside the source staging directory")

    expected = ("README.md", "NOTICE.txt", "relink.py", "dependencies.json", "Cargo.lock",
                "licenses/tolk/GPL-3.0.txt", "licenses/rust-crates.json",
                "tolk/src/Tolk.cpp", "loader/src/main.cpp")
    for name in expected:
        if not (kit / name).is_file():
            raise ValueError(f"Incomplete kit, missing {name}")
    manifest = kit / "provenance.json"
    record = json.loads(manifest.read_text(encoding="utf-8"))
    release = args.dll.read_bytes()
    record["releaseDllSha256"] = sha256(release).hexdigest()
    record["releaseDllBytes"] = len(release)
    if record["releaseDllSha256"] == record["originalPartyDllSha256"]:
        raise ValueError("Use the release rebuild with the digest guards")
    manifest.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

    files = sorted(path for path in kit.rglob("*") if path.is_file())
    blocked = {".dll", ".exe", ".pdb", ".obj", ".lib", ".gpk", ".pkg", ".thing_bin", ".pyc"}
    for path in files:
        if path.is_symlink() or path.suffix.lower() in blocked or ".git" in path.relative_to(kit).parts:
            raise ValueError(f"Unexpected archive member {path}")
    with ZipFile(out, "x", compression=ZIP_DEFLATED) as archive:
        for path in files:
            entry = ZipInfo(path.relative_to(kit).as_posix(), (2026, 11, 28, 0, 0, 0))
            archive.writestr(entry, path.read_bytes(), compress_type=ZIP_DEFLATED)
    print(f"{sha256(out.read_bytes()).hexdigest().upper()}  {out}")


if __name__ == "__main__":
    main()
