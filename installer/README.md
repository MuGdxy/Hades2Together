# Windows x64 preview installer

## Install and launch

Run **Hades2Together-Setup.exe** on Windows 10 or 11 x64 with .NET Framework
4.8 and the Visual C++ x64 runtime normally installed by Steam for Hades II.
The setup window uses Chinese on a Chinese Windows display language and
English elsewhere. It looks in registered Steam libraries for Hades II
(app 1145350). You can also browse to the game folder containing Ship and
Content.

Setup accepts Steam build 25481925 (Hades II v1.143476). It reads and verifies
the Ship executable, PDB, SDL2, Main.lua and the stock F_Combat02 map. A Steam
update or local edit to a pinned file can make the preview incompatible.

Setup installs the mod profile under `%LOCALAPPDATA%\Hades2Together\Preview`.
If the Steam game has a vacant loader slot, Setup installs the custom
`Ship\d3d12.dll` and supplies Hell2Modding's supported explicit-enable marker
before making that DLL visible. The shortcut uses the existing Steam files
directly. The Steam library can be on a different drive. Setup needs no
developer tools or elevation. If the game is in a library your account cannot
write to, use Steam to move it to a writable library, then rerun Setup.

Normal Steam launches without explicit mod-loader settings retain their
previous behavior, including before the first preview launch. Setup reuses a
matching, already initialized loader and leaves its existing settings in
place. If the loader has never started, launch the game normally once to
initialize its settings before running Setup. A conflicting loader or
incompatible first-launch settings require a compatible game folder.

Open **Hades2Together Preview** in the Start menu with Steam signed in.
The shortcut starts the project's loopback host preview in the stock
F_Combat02 room. It uses a separate preview profile and disables saving and
loading. This build is for the preview host workflow. Internet guest play
requires additional setup beyond this installer.

Rerun Setup to install an update or select the game's new location after a
Steam library move. The active preview changes once its verified mod profile
and loader are ready. Keep the preview closed during setup or removal.
To remove it, go to Windows **Installed apps** and choose **Hades2Together
Preview**. Removal verifies matching file identities for owned Steam
artifacts. Borrowed or replaced files, copied artifacts whose ownership
cannot be established, personal additions and runtime-generated logs and
profile data are preserved. Rerun Setup after an interrupted install or
retry removal after an interrupted uninstall.

## Command line

The same operations are available to orchestration tools. Pass the whole
Hades II folder as one argument. Use a process API that waits for Windows
GUI executables and reads their exit code.

```powershell
.\Hades2Together-Setup.exe --check 'D:\SteamLibrary\steamapps\common\Hades II'
.\Hades2Together-Setup.exe --install 'D:\SteamLibrary\steamapps\common\Hades II'
.\Hades2Together-Setup.exe --launch
.\Hades2Together-Setup.exe --uninstall
```

Exit codes are 0 for success, 1 for an operation error and 2 for invalid
arguments. The setup CLI writes errors to standard error. Launch waits until
the preview process exits. The shortcut displays errors in a Windows dialog.

`--check` reports `download_bytes` for the Setup EXE, `profile_payload_bytes`
for a fresh install's shipped files in LocalAppData, and `steam_payload_bytes`
for files Setup would add to the chosen game's Ship folder. These are logical
bytes. Installed profile bookkeeping, the Start menu shortcut and runtime
data are excluded. The separately distributed loader source ZIP is outside
the Setup EXE's download size.

## Build the release pair

Run from the repository root with Windows PowerShell 5.1, Git and a .NET SDK
with C# 10 support. The compiler uses .NET Framework 4.8 references or the
framework assemblies on the build machine. The Hades2Together plugin comes
from the current committed source tree.

1. Obtain the digest-validated custom `d3d12.dll` and the accompanying
   `Hades2Together-Loader-Source.zip`. Follow the companion README to build
   or relink the loader. The packager verifies both SHA-256 pins and checks
   that the companion names the same DLL in `provenance.json`. It copies
   Tolk, GPL/LGPL/NVDA and other embedded dependency notices from the companion.
   The previous F59A2C loader is supported only as a local development fixture
   with `-DevelopmentFixture`, which uses a visibly different artifact name.
2. Supply a directory with `Hell2Modding-GLOBAL` from the Hell2Modding
   1.0.125 plugin stage and `LuaENVY-ENVY` from ENVY 1.2.1. The required
   files are pinned individually. An existing validated plugin stage can
   supply both directories. Upstream sources and licenses are in NOTICE.

```powershell
$scratch = 'C:\path\to\build-scratch'
$loaderDir = 'C:\path\to\validated-loader'
$plugins = 'C:\path\to\validated-stage\Ship\ReturnOfModding\plugins'
$loaderHash = '0DCDA10241F337ADA6B41E9EE5E9AD1D30D4F03795386B388A8EBB24D8A6A6FB'
$sourceHash = 'F95C7B3CE2B09C5CCE47F55028C84FB7EEC230A23D1B54DF0025640A8C90EA3E'

.\installer\Build.ps1 -Dependencies $plugins `
    -Loader "$loaderDir\d3d12.dll" -LoaderSha256 $loaderHash `
    -LoaderSourceZip "$loaderDir\Hades2Together-Loader-Source.zip" -LoaderSourceSha256 $sourceHash `
    -OutputDirectory "$scratch\release"
.\installer\tests\Inspect-Package.ps1 -SetupExe "$scratch\release\Hades2Together-Setup.exe" -LoaderSha256 $loaderHash
```

Distribute `Hades2Together-Setup.exe` alongside
`Hades2Together-Loader-Source.zip` so recipients can access the loader's
corresponding source and relinking instructions. The installer source
contains narrow compatibility pins for v1.143476. The game, PDB, proprietary
scripts, saves and recordings are absent from the redistributable payload.

The loader in the source companion calls `rom::is_rom_enabled()` before
initializing the modding runtime. Upstream gives regular launches an opt-out
when `Ship\ReturnOfModdingFirstEnabledReason.txt` records an explicit first
enable. Setup supplies reason 2 for a vacant slot. The preview explicitly
enables the runtime and selects the active local profile for its own process.
[Enable behavior](https://github.com/xiaoxiao921/ReturnOfModdingBase/blob/693360501a0b5309e302956fca1c5aaf528da441/src/rom/rom.cpp)
and [profile location](https://github.com/xiaoxiao921/ReturnOfModdingBase/blob/693360501a0b5309e302956fca1c5aaf528da441/src/paths/paths.cpp).

## Offline checks

```powershell
.\installer\tests\Run.ps1 -ScratchDirectory "$scratch\fixtures"
.\installer\tests\Run.ps1 -ScratchDirectory "$scratch\packaged-mod" `
    -SetupExe "$scratch\release\Hades2Together-Setup.exe"
```

The first command exercises the lifecycle with invented data, checks a
terminated install and verifies Windows registration in a disposable HKCU
key and shortcut folder. The optional packaged-mod check installs the
embedded payload into a synthetic Steam tree and profile in scratch, verifies
the original fixture files, measures ownership by location and uninstalls.
