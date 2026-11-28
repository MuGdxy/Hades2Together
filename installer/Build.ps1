param(
    [Parameter(Mandatory)][string]$Loader,
    [Parameter(Mandatory)][string]$Dependencies,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$LoaderNotices,
    [string]$LoaderSha256,
    [string]$LoaderSourceZip,
    [string]$LoaderSourceSha256,
    [switch]$DevelopmentFixture
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Compiler.ps1"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = (Get-Item -LiteralPath "$PSScriptRoot/..").FullName
$developmentHash = 'F59A2C62CAD30B1E76BE7E8DE39ED83376C9792942D6CA707DFE60AD895339F5'

function Assert-Pin([string]$path, [string]$hash) {
    if ($hash -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $path).Hash -ne $hash) {
        throw "SHA-256 mismatch or no pin supplied: $path"
    }
}
if ($DevelopmentFixture) {
    Assert-Pin $Loader $developmentHash
    $LoaderSha256 = $developmentHash
    if (!$LoaderNotices) { throw 'Supply local notices for the development fixture.' }
    $artifactName = 'Hades2Together-Setup-Development.exe'
} else {
    if ($LoaderNotices) { throw 'Release notices are read from the matching source companion.' }
    if ($LoaderSha256 -eq $developmentHash) { throw 'The historical loader is a development fixture.' }
    Assert-Pin $Loader $LoaderSha256
    if (!$LoaderSourceZip -or [IO.Path]::GetFileName($LoaderSourceZip) -cne 'Hades2Together-Loader-Source.zip') {
        throw 'Provide the matching Hades2Together-Loader-Source.zip.'
    }
    Assert-Pin $LoaderSourceZip $LoaderSourceSha256
    $sourceArchive = [IO.Compression.ZipFile]::OpenRead($LoaderSourceZip)
    try {
        $reader = New-Object IO.StreamReader($sourceArchive.GetEntry('provenance.json').Open())
        try { $sourceInfo = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        if ($sourceInfo.releaseDllSha256 -ne $LoaderSha256) { throw 'The source companion describes a different loader.' }
        foreach ($required in @('NOTICE.txt', 'licenses/tolk/LICENSE.txt', 'licenses/tolk/GPL-3.0.txt', 'licenses/tolk/LICENSE-NVDA.txt')) {
            if (!$sourceArchive.GetEntry($required)) { throw "Missing loader notice: $required" }
        }
    } finally { $sourceArchive.Dispose() }
    $artifactName = 'Hades2Together-Setup.exe'
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Choose a fresh output directory.' }

$dependencyPins = @{
    'Hell2Modding-GLOBAL/main.lua' = 'FFA625F9E301BDED2619003E6A2160E2ABD0EC6502579786BC872845FE2610FC'
    'Hell2Modding-GLOBAL/manifest.json' = 'C683A02DC06342CEB96693CFAA478C48852475002CBC11142996BE6EA977664B'
    'LuaENVY-ENVY/main.lua' = 'D4196999A1DD2F5280C2534F4DF5628092C3EA51138A30014768F81307E45349'
    'LuaENVY-ENVY/manifest.json' = '7337C14D6BAA5E1194C591120C2188F432373EE0760D00060B0444220B4152F2'
    'LuaENVY-ENVY/def.lua' = '74F931597A7935C25D98A945E8BA20D7EEBC46A6F6532FBE538F1FF581F1FF75'
    'LuaENVY-ENVY/def_auto.lua' = '6829B7D2B97FCD6CEADDCFF0CE7268AECDE699FF7A26EC56EB86F2AA0AD7164E'
    'LuaENVY-ENVY/LICENSE' = '4D1135DED5C9894EDD02A5BD640D5431C371B256CF2477021013D4A471579592'
}
foreach ($entry in $dependencyPins.GetEnumerator()) { Assert-Pin "$Dependencies/$($entry.Key)" $entry.Value }
& git -C $repo diff --quiet HEAD -- src LICENSE
if ($LASTEXITCODE) { throw 'Commit Hades2Together source changes before packaging.' }
$commit = & git -C $repo rev-parse HEAD
if ($LASTEXITCODE) { throw 'Unable to determine the source commit.' }
$pluginFiles = & git -C $repo ls-files -- src
if ($LASTEXITCODE -or !$pluginFiles) { throw 'Unable to enumerate the tracked plugin files.' }
$out = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$version = "0.0.1-preview.$($commit.Substring(0,12))"
$versionSource = "$out/version.cs"
[IO.File]::WriteAllText($versionSource, @"
[assembly: System.Reflection.AssemblyInformationalVersion("$version")]
[assembly: System.Reflection.AssemblyVersion("0.0.1.0")]
[assembly: System.Reflection.AssemblyFileVersion("0.0.1.0")]
[assembly: System.Reflection.AssemblyProduct("Hades2Together Preview")]
"@)
$sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.cs' -File | ForEach-Object FullName) + $versionSource
$nativeManifest = "/win32manifest:$PSScriptRoot/Setup.manifest"
$launcher = "$out/Preview.exe"
Invoke-PreviewCompiler -Output $launcher -Sources $sources -Options @('/target:winexe', '/define:BOOTSTRAP', $nativeManifest)
$versionedLauncher = "$out/PreviewApp.exe"
Invoke-PreviewCompiler -Output $versionedLauncher -Sources $sources -Options @('/target:winexe', $nativeManifest)

$payloadPath = "$out/payload.zip"
$entries = @{}
$entries['Preview.exe'] = $launcher
$entries['PreviewApp.exe'] = $versionedLauncher
$entries['Ship/d3d12.dll'] = $Loader
$entries['Notices/Hades2Together-LICENSE.txt'] = "$repo/LICENSE"
$entries['Notices/NOTICE.txt'] = "$PSScriptRoot/NOTICE.txt"
$entries['ReturnOfModding/config/Hell2Modding-Hell2Modding-GUI.cfg'] = "$PSScriptRoot/Loader-GUI.toml"
$provenance = "$out/build.txt"
@(
    "Version: $version"
    "Hades2Together source revision: $commit"
    "Loader SHA-256: $LoaderSha256"
    "Development fixture: $([bool]$DevelopmentFixture)"
    "Hades2Together-Loader-Source.zip SHA-256: $LoaderSourceSha256"
) | Set-Content -LiteralPath $provenance -Encoding UTF8
$entries['Notices/build.txt'] = $provenance
$plugins = 'ReturnOfModding/plugins'
foreach ($path in $pluginFiles) {
    if ($path -cnotmatch '^src/([a-zA-Z0-9_/-]+\.lua|manifest\.json|hack/H2TGuest\.bin)$') {
        throw "Unexpected Hades2Together plugin file: $path"
    }
    $entries["$plugins/MuGdxy-Hades2Together/$($path.Substring(4))"] = "$repo/$path"
}
foreach ($name in $dependencyPins.Keys) { $entries["$plugins/$name"] = "$Dependencies/$name" }
if ($DevelopmentFixture) {
    $noticeRoot = (Get-Item -LiteralPath $LoaderNotices).FullName.TrimEnd('\')
    foreach ($notice in Get-ChildItem -LiteralPath $LoaderNotices -File -Recurse) {
        $relative = $notice.FullName.Substring($noticeRoot.Length + 1).Replace('\', '/')
        $entries["Notices/Loader/$relative"] = $notice.FullName
    }
}

function Add-PayloadEntry($zip, [string]$name, [IO.Stream]$inputStream) {
    $file = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
    $file.LastWriteTime = [DateTimeOffset]::Parse('2000-01-01T00:00:00+00:00')
    $entryStream = $file.Open()
    try { $inputStream.CopyTo($entryStream) } finally { $entryStream.Dispose() }
}

$zip = [IO.Compression.ZipFile]::Open($payloadPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    $names = [string[]]@($entries.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) {
        $inputFile = [IO.File]::OpenRead($entries[$name])
        try { Add-PayloadEntry $zip $name $inputFile } finally { $inputFile.Dispose() }
    }
    if (!$DevelopmentFixture) {
        $sourceArchive = [IO.Compression.ZipFile]::OpenRead($LoaderSourceZip)
        try {
            foreach ($entry in $sourceArchive.Entries) {
                $name = $entry.FullName
                if ($name -ne 'NOTICE.txt' -and (!$name.StartsWith('licenses/') -or !$entry.Name)) { continue }
                if ($name -cnotmatch '^[A-Za-z0-9_+. /-]+$' -or $name -match '(?:^|/)\.\.?(?:/|$)' -or
                    $name -match '\.(bin|dll|exe|pdb|sav|lua|zip)$' -or $entry.Length -gt 4MB) {
                    throw "Unexpected loader notice: $name"
                }
                $stream = $entry.Open()
                try { Add-PayloadEntry $zip "Notices/Loader/$name" $stream } finally { $stream.Dispose() }
            }
        } finally { $sourceArchive.Dispose() }
    }
} finally { $zip.Dispose() }

$artifact = "$out/$artifactName"
Invoke-PreviewCompiler -Output $artifact -Sources $sources -Options @(
    '/target:winexe', '/define:SETUP', $nativeManifest, "/resource:$payloadPath,payload.zip"
)
if (!$DevelopmentFixture) {
    Copy-Item -LiteralPath $LoaderSourceZip -Destination "$out/Hades2Together-Loader-Source.zip"
    Assert-Pin "$out/Hades2Together-Loader-Source.zip" $LoaderSourceSha256
}
Get-FileHash -LiteralPath $artifact
