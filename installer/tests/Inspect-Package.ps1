param(
    [Parameter(Mandatory)][string]$SetupExe,
    [Parameter(Mandatory)][string]$LoaderSha256
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
$bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $SetupExe).Path)
$pe = [BitConverter]::ToInt32($bytes, 60)
if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0x8664) {
    throw 'Expected a Windows x64 PE file.'
}
$assembly = [Reflection.Assembly]::Load($bytes)
$resources = $assembly.GetManifestResourceNames()
if ($resources.Count -ne 1 -or $resources[0] -cne 'payload.zip') {
    throw 'Unexpected embedded resources.'
}
$zip = [IO.Compression.ZipArchive]::new($assembly.GetManifestResourceStream('payload.zip'))
try {
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName
        $allowed = $name -cin @('Preview.exe', 'PreviewApp.exe', 'Ship/d3d12.dll',
            'ReturnOfModding/config/Hell2Modding-Hell2Modding-GUI.cfg') -or
            $name -cmatch '^Notices/[^:]+$' -or
            $name -cmatch '^ReturnOfModding/plugins/(MuGdxy-Hades2Together|LuaENVY-ENVY|Hell2Modding-GLOBAL)/([A-Za-z0-9/_-]+\.lua|manifest\.json|LICENSE|hack/H2TGuest\.bin)$'
        if (!$allowed -or $name -match '(?:^|/)\.\.?(?:/|$)|\\|\.(pdb|sav|mp4|zip)$') {
            throw "Unexpected embedded payload file: $name"
        }
    }
    $loader = $zip.GetEntry('Ship/d3d12.dll').Open()
    try {
        if ((Get-FileHash -InputStream $loader).Hash -ne $LoaderSha256) { throw 'Unexpected embedded loader.' }
    } finally { $loader.Dispose() }
    foreach ($file in @('NOTICE.txt','licenses/tolk/LICENSE.txt','licenses/tolk/GPL-3.0.txt','licenses/tolk/LICENSE-NVDA.txt')) {
        if (!$zip.GetEntry("Notices/Loader/$file")) { throw "Missing loader notice: $file" }
    }
    "PASS: Windows x64 PE, $($zip.Entries.Count) allow-listed mod-only payload entries, matching loader and LGPL/GPL/NVDA notices"
} finally { $zip.Dispose() }
