# Windows x64 preview installer

## Install and launch

Run **Hades2Together-Setup.exe** on Windows 10 or 11 x64 with .NET Framework
4.8 and the Visual C++ x64 runtime normally installed by Steam for Hades II.
The setup window uses Chinese on a Chinese Windows display language and
English elsewhere. It looks in registered Steam libraries for Hades II
(app 1145350). You can also browse to the game folder containing Ship and
Content.

Setup accepts Steam build 25481925 (Hades II v1.143476), with the matching
Ship executable, PDB and SDL2 DLL. It verifies SHA-256 and length for every
file it will copy, including the stock F_Combat02 map. The PDB comes from
the player's local Steam installation. Setup will report an error if Steam
updates or removes a required file, or a mod changes a required file. Extra
files in the Steam folder are ignored.

The preview uses about 10.9 GiB under
`%LOCALAPPDATA%\Hades2Together\Preview`. An upgrade requires space for the
new copy while the current copy remains installed. Setup uses regular copies
of the needed Steam files, so the Steam installation and preview have
independent files. It needs neither elevation nor developer tools.

Open **Hades2Together Preview** in the Start menu with Steam signed in.
The shortcut starts the project's loopback host preview in the stock
F_Combat02 room. It uses a separate preview profile and disables saving and
loading. This build is for the preview host workflow. Internet guest play
requires additional setup beyond this installer.

Rerun Setup to install an update. The active preview changes only after
the new generation is verified and ready. Keep the preview closed while
installing or uninstalling. To remove it, go to Windows **Installed apps**
and choose **Hades2Together Preview**. Removal checks the owned paths and
hashes. It preserves personal additions, modified files and runtime-generated
logs and profile data. If a setup process is interrupted, rerun it to
recover the pending generation. An interrupted uninstall can be retried
from Installed apps or from the setup executable.

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

## Build the release pair

Run from the repository root with Windows PowerShell 5.1, Git and a .NET SDK
with C# 10 support. The compiler uses .NET Framework 4.8 references or the
framework assemblies on the build machine. The Hades2Together plugin comes
from the current committed source tree.

1. Generate the catalog from an unmodified Windows Steam v1.143476 install.
   `New-SteamCatalog.ps1` writes paths, byte counts and SHA-256s. `Build.ps1`
   checks the resulting catalog's fixed hash. This catalog was audited against
   the stock depot manifests `1145352_6846318752230433935` and
   `1145354_6835783259840402797`. It includes the needed Ship files and all
   stock Content files.
2. Obtain the digest-validated custom `d3d12.dll` and the accompanying
   `Hades2Together-Loader-Source.zip`. Follow the companion README to build
   or relink the loader. The packager verifies both SHA-256 pins and checks
   that the companion names the same DLL in `provenance.json`. It copies
   Tolk, GPL/LGPL/NVDA and other embedded dependency notices from the companion.
   The previous F59A2C loader is supported only as a local development fixture
   with `-DevelopmentFixture`, which uses a visibly different artifact name.
3. Supply a directory with `Hell2Modding-GLOBAL` from the Hell2Modding
   1.0.125 plugin stage and `LuaENVY-ENVY` from ENVY 1.2.1. The required
   files are pinned individually. An existing validated plugin stage can
   supply both directories. Upstream sources and licenses are in NOTICE.

```powershell
$scratch = 'C:\path\to\build-scratch'
$game = 'D:\SteamLibrary\steamapps\common\Hades II'
$loaderDir = 'C:\path\to\validated-loader'
$plugins = 'C:\path\to\validated-stage\Ship\ReturnOfModding\plugins'
$loaderHash = '0DCDA10241F337ADA6B41E9EE5E9AD1D30D4F03795386B388A8EBB24D8A6A6FB'
$sourceHash = 'F95C7B3CE2B09C5CCE47F55028C84FB7EEC230A23D1B54DF0025640A8C90EA3E'

.\installer\New-SteamCatalog.ps1 -GameDirectory $game -Output "$scratch\steam-143476.tsv"
.\installer\Build.ps1 -SteamCatalog "$scratch\steam-143476.tsv" -Dependencies $plugins `
    -Loader "$loaderDir\d3d12.dll" -LoaderSha256 $loaderHash `
    -LoaderSourceZip "$loaderDir\Hades2Together-Loader-Source.zip" -LoaderSourceSha256 $sourceHash `
    -OutputDirectory "$scratch\release"
.\installer\tests\Inspect-Package.ps1 -SetupExe "$scratch\release\Hades2Together-Setup.exe" -LoaderSha256 $loaderHash
```

Distribute `Hades2Together-Setup.exe` alongside
`Hades2Together-Loader-Source.zip` so recipients can access the loader's
corresponding source and relinking instructions. The only retail metadata
embedded in Setup is the compatibility catalog. The game, PDB, proprietary
scripts, saves and recordings are absent from the redistributable payload.

## Offline checks

```powershell
.\installer\tests\Run.ps1 -ScratchDirectory "$scratch\fixtures"
.\installer\tests\Run.ps1 -ScratchDirectory "$scratch\full-staging" `
    -SetupExe "$scratch\release\Hades2Together-Setup.exe" -GameDirectory $game
```

The first command exercises the lifecycle with invented data, checks a
terminated install and verifies Windows registration in a disposable HKCU
key and shortcut folder. The optional full staging check reads an
already-registered Steam installation, copies files only to scratch, and
removes the staged installation. Both checks leave the game closed.
