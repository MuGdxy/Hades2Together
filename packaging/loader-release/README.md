# Hades2Together Windows loader source companion

The Windows x64 preview loader statically links Tolk by Davy Kager and contributors.
Tolk is licensed under the GNU Lesser General Public License, version 3. The
companion archive includes the Tolk source and the original LGPLv3 and GPLv3
texts. It also preserves Tolk's LGPLv2.1 notice for the optional NVDA controller
client. The build links the Tolk library and uses Windows libraries for system
interfaces. Optional screen reader client DLLs are obtained from their vendors.

The archive provides the modified loader source, a clean build recipe, and the
notices for statically linked components, headers, and embedded ImGui font.
Keep the archive available alongside the matching installer and point the
installer's notice to it. Recipients may modify and relink Tolk for their own
use, including reverse engineering for debugging those modifications under
the terms of the LGPL.

## Build or relink

Use an **x64 Native Tools Command Prompt for VS 2022** with the C++ build
tools and Windows SDK installed. The release build uses MSVC 14.44.35207,
Windows SDK 10.0.26100.0, CMake 3.31.6, Ninja 1.12.1, Git and Python 3.10 or
newer, and the MSVC Rust nightly toolchain dated 2026-11-25. The Microsoft
toolchain provides MASM, the resource compiler and manifest tool. Put Git,
Python, CMake, Ninja and rustup on PATH. GitHub and crates.io access is needed
on a fresh build. Extract the archive to a short path such as
`C:\h2t\source`.

```bat
rustup toolchain install nightly-2026-11-25-x86_64-pc-windows-msvc --profile minimal
python relink.py --out C:\h2t\build
```

The recipe fetches Git dependencies at the commits in `dependencies.json`
and builds the Rust dependency with the upstream `Cargo.lock` in locked mode.
The included `Cargo.lock` records the exact crate versions and checksums.
The new `d3d12.dll` is written under the output directory. The loader source
build uses Windows SDK headers and libraries. It needs no Hades II executable,
PDB, assets, or screen reader client DLLs.

To substitute Tolk, copy the included `tolk` directory and edit the copy.
Preserve Tolk's headers and the compatible static `Tolk` target in its CMake
project, then point the recipe at that source directory. Use a fresh output
directory for each build.

```bat
python relink.py --out C:\h2t\relinked --tolk-source C:\h2t\my-tolk
```

For your own test installation, close the loader and back up the
`d3d12.dll` in the isolated preview's `Ship` directory before swapping it
with the relinked DLL. Keep the original to restore the installer-managed
payload. The installer checks its own release hash, so launch a locally
relinked copy directly from an equivalent, user-managed preview installation
with the same launch arguments and environment.

## Which loader this accompanies

`provenance.json` gives the release DLL hash and the original party preview
hash. The original recipe used the pinned Hell2Modding base, the final party
`main.cpp` and `data.cpp` objects, the Windows x64 proxy export definition,
and the dependencies identified in `dependencies.json`, including static
`Tolk.lib`. The provenance file records input and build-record hashes. The
loader here carries the final party sources and recompiles the full
application. Debug information, output paths and toolchain state can affect
the DLL hash. Gameplay evidence for the original preview applies to that
original binary.

The release changes the party overlay's constructor, unwind, initialization
call, observation preflight, and secondary-owner installation byte checks to
SHA-256 checks. Each guard checks the original address and length, returns
false on a failed read or hash, and compares to the digest of the original
expected bytes. The checks run during preflight or hook installation. The
frozen retail executable, PDB and SDL2 identity checks and callback code
remain in the loader. Inherited Hell2Modding fixed comparisons and wildcard
patterns for locating game code are retained from the attributed upstream
source.

The archive carries the loader's MIT license, Hades2Together's MIT license,
Tolk's original source licenses and third-party notices. The Rust inventory
covers the Windows x64 build's locked crates and toolchain library notices.
Windows system and compiler runtime components are supplied by the
consumer's Windows and Visual Studio installations or linked by the normal
MSVC toolchain as applicable.
