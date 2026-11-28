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
if (@(Compare-Object @('payload.zip', 'steam.tsv') $assembly.GetManifestResourceNames()).Count) {
    throw 'Unexpected embedded resources.'
}
$catalog = $assembly.GetManifestResourceStream('steam.tsv')
try {
    if ((Get-FileHash -InputStream $catalog).Hash -ne '0AFCBF4D3A8E99EF27281FA3A299AF36DC53FC2D50F0E620096A107427939E35') {
        throw 'Unexpected embedded Steam catalog.'
    }
} finally { $catalog.Dispose() }
$zip = [IO.Compression.ZipArchive]::new($assembly.GetManifestResourceStream('payload.zip'))
try {
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName
        $allowed = $name -cin @('Preview.exe', 'PreviewApp.exe', 'Ship/d3d12.dll',
            'Ship/ReturnOfModding/config/Hell2Modding-Hell2Modding-GUI.cfg') -or
            $name -cmatch '^Notices/[^:]+$' -or
            $name -cmatch '^Ship/ReturnOfModding/plugins/(MuGdxy-Hades2Together|LuaENVY-ENVY|Hell2Modding-GLOBAL)/([A-Za-z0-9/_-]+\.lua|manifest\.json|LICENSE|hack/H2TGuest\.bin)$'
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
    "PASS: Windows x64 PE, $($zip.Entries.Count) allow-listed payload entries, matching loader and catalog, LGPL/GPL/NVDA notices"
} finally { $zip.Dispose() }
