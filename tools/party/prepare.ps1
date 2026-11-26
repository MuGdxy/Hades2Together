# Stage one authority and four independent play plugin packages. Never starts Hades.
param(
    [Parameter(Mandatory)][string]$SourceStage,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][ipaddress]$Address,
    [Parameter(Mandatory)][string]$CaptureHelper
)
$ErrorActionPreference = 'Stop'
$repo = (Get-Item "$PSScriptRoot/../..").FullName
$source = (Get-Item -LiteralPath $SourceStage).FullName
if ($Address.AddressFamily -ne 'InterNetwork') { throw 'Expected the host LAN IPv4 address' }
if ((Get-FileHash "$source/Ship/d3d12.dll").Hash -ne '8A85AB29B5F259EBAA793FCEB53856B7CDF8F80BB3A9E63773D9030FBFF3BF3B') { throw 'Unexpected authority loader' }
if ((Get-FileHash $CaptureHelper).Hash -ne '5557FB8BBF37421F9202C27AC783ECCAD88AF588CE08824BE4354EED95B28B83') { throw 'Unexpected game-window recorder' }
if (Test-Path -LiteralPath $Out) { throw 'Use a fresh output directory' }
$root = (New-Item -ItemType Directory -Path $Out).FullName
$ship = New-Item -ItemType Directory "$root/Ship"
Get-ChildItem "$source/Ship" -File | Copy-Item -Destination $ship.FullName
$plugins = New-Item -ItemType Directory "$ship/ReturnOfModding/plugins" -Force
foreach ($name in 'Hell2Modding-GLOBAL','LuaENVY-ENVY') {
    Copy-Item "$source/Ship/ReturnOfModding/plugins/$name" -Destination $plugins.FullName -Recurse
}
$content = New-Item -ItemType Directory "$root/Content"
foreach ($item in Get-ChildItem "$source/Content") {
    if ($item.Name -eq 'Scripts') { Copy-Item $item.FullName -Destination $content.FullName -Recurse }
    elseif ($item.PSIsContainer) {
        $null = New-Item -ItemType Junction -Path "$content/$($item.Name)" -Target $item.FullName
    } else { Copy-Item $item.FullName -Destination $content.FullName }
}
# Change only the private room definition. The original default encounter must
# still finish its enemy waves and call SpawnRoomReward with the normal menu.
$roomFile = "$content/Scripts/RoomDataF.lua"
$roomData = [IO.File]::ReadAllText($roomFile)
$marker = [regex]'(?m)^(\s*F_Combat02 =\r?\n\s*\{\r?\n)'
if ($marker.Matches($roomData).Count -ne 1) { throw 'Missing unique retail F_Combat02 definition' }
$settings = "`t`tChangeReward = `"Boon`",`n`t`tForceLootName = `"PoseidonUpgrade`",`n`t`tForcedRewards = { { Name = `"Boon`", LootName = `"PoseidonUpgrade`" } },`n"
[IO.File]::WriteAllText($roomFile, $marker.Replace($roomData, '$1' + $settings))

foreach ($name in 'Authority','PlayerA','PlayerB','PlayerC','PlayerD') {
    $parent = if ($name -eq 'Authority') { $plugins.FullName } else { (New-Item -ItemType Directory "$root/clients/$name" -Force).FullName }
    $dest = Join-Path $parent 'MuGdxy-Hades2Together'
    Copy-Item "$repo/src" -Destination $dest -Recurse
    $configPath = Join-Path $dest 'config.lua'
    $cfg = [IO.File]::ReadAllText($configPath).Replace('playerName = "Player"',('playerName = "' + $name + '"'))
    if ($name -eq 'Authority') {
        $cfg = $cfg.Replace('role = "serve+play"','role = "serve"').Replace('bindAddress = "127.0.0.1"',('bindAddress = "' + $Address + '"')).Replace('cliSnapshots = false','cliSnapshots = true')
    } else {
        $cfg = $cfg.Replace('role = "serve+play"','role = "play"').Replace('serverAddress = "127.0.0.1"',('serverAddress = "' + $Address + '"'))
        Copy-Item "$PSScriptRoot/guest.ps1" $parent
    }
    [IO.File]::WriteAllText($configPath, $cfg)
}
# Keep the reviewed HWND/PID, encoder, frame hashes and finalization. Stop
# interactively with ffmpeg's q so a real party is not cut off at 45 seconds.
$capture = [IO.File]::ReadAllText((Resolve-Path $CaptureHelper))
$capture = $capture.Replace('-nostdin ', '').Replace('-t $Seconds ', '').Replace('UtcNow.AddSeconds(6)', 'UtcNow.AddSeconds(45)')
[IO.File]::WriteAllText("$root/record.ps1", $capture)
$events = (New-Item -ItemType Directory "$plugins/H2T-PartyObserver").FullName
Copy-Item "$PSScriptRoot/events.lua" "$events/main.lua"
[IO.File]::WriteAllText("$events/manifest.json", '{"namespace":"H2T","name":"PartyObserver","version_number":"0.0.1","description":"Isolated original fire and hit recorder","dependencies":[]}')
Copy-Item "$PSScriptRoot/host.ps1","$PSScriptRoot/observe.lua" $root
$null = New-Item -ItemType Directory "$root/profile/Hades2Together" -Force
"Prepared $root for $Address TCP 27780"
