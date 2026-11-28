param(
    [Parameter(Mandatory)][string]$GameDirectory,
    [Parameter(Mandatory)][string]$Output
)
$ErrorActionPreference = 'Stop'
$root = (Get-Item -LiteralPath $GameDirectory).FullName
$pins = @{
    'Ship/Hades2.exe' = 'A6BE16E91683E6FE3E566C5D68C1DCF8992BAB9126B856606D57B7115E9C30DC'
    'Ship/Hades2.pdb' = 'DFEBC6219DEAAAA1D96DC03FE2866D14CA621E1836F685FF40E989C81D577EA7'
    'Ship/SDL2.dll' = '7457CC5C885505B7EBF9C05AD57881468C3DBBA551B3DF8E18CE5D31A09F6A2C'
    'Content/Scripts/Main.lua' = 'CC64A8D7838CF60198D20E8D3C33D7B7792430BC4D86E700CA54925D122D236C'
    'Content/Maps/F_Combat02.map_text' = '42B5E48375FFDB3C858FCBE61F6C8EE4AF1B96AA98F747387131B794AD8D4970'
}

function Assert-Ordinary($item) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $($item.FullName)" }
}

function Get-ContentFiles($directory) {
    Assert-Ordinary $directory
    foreach ($item in Get-ChildItem -LiteralPath $directory.FullName -Force) {
        Assert-Ordinary $item
        if ($item.PSIsContainer) { Get-ContentFiles $item } else { $item }
    }
}

for ($parent = Get-Item -LiteralPath $root; $parent; $parent = $parent.Parent) { Assert-Ordinary $parent }
Assert-Ordinary (Get-Item -LiteralPath "$root/Ship")
foreach ($pin in $pins.GetEnumerator()) {
    $path = Get-Item -LiteralPath "$root/$($pin.Key)"
    for ($parent = $path.Directory; $parent; $parent = $parent.Parent) { Assert-Ordinary $parent }
    Assert-Ordinary $path
    if ((Get-FileHash -LiteralPath $path.FullName).Hash -ne $pin.Value) { throw "Wrong Steam build: $($pin.Key)" }
}

$shipFiles = @(
    'Hades2.exe', 'Hades2.pdb', 'SDL2.dll', 'amd_ags_x64.dll', 'bink2w64.dll',
    'crashpad_handler.exe', 'dbgcore.dll', 'dbghelp.dll', 'discord_game_sdk.dll',
    'dxcompiler.dll', 'fmod.dll', 'fmodstudio.dll', 'GFSDK_Aftermath_Lib.x64.dll',
    'granny2_x64.dll', 'lua52.dll', 'steam_api64.dll', 'WinPixEventRuntime.dll',
    'CursorAttack.cur', 'CursorAttackPress.cur', 'CursorAttackPress_HighContrast.cur',
    'CursorDefault.cur', 'CursorDefault_HighContrast.cur', 'CursorDefaultPress.cur',
    'CursorDefaultPress_HighContrast.cur', 'CursorFreeAim.cur', 'CursorInteract.cur',
    'CursorInteractPress.cur', 'CursorMove.cur', 'CursorOutOfRange.cur', 'CursorRally.cur'
)
$files = @($shipFiles | ForEach-Object { Get-Item -LiteralPath "$root/Ship/$_" })
$files += @(Get-ContentFiles (Get-Item -LiteralPath "$root/Content"))
$lines = foreach ($file in $files) {
    Assert-Ordinary $file
    $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
    if ($relative -match '[\x00-\x1f]' -or $relative -match '\.(dll|exe|pdb|sav)$' -and $relative.StartsWith('Content/')) {
        throw "Unexpected Steam content path: $relative"
    }
    "$relative`t$($file.Length)`t$((Get-FileHash -LiteralPath $file.FullName).Hash)"
}
$lines = [string[]]$lines
[Array]::Sort($lines, [StringComparer]::Ordinal)
[IO.File]::WriteAllText($Output, ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding $false))
Get-FileHash -LiteralPath $Output
