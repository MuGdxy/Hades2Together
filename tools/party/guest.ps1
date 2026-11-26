param([Parameter(Mandatory)][string]$Ship, [Parameter(Mandatory)][string]$ProfileDirectory, [switch]$Run)
$ErrorActionPreference = 'Stop'
if (!$Run) { throw 'Use -Run only for the scheduled game session.' }
$Ship = (Get-Item -LiteralPath $Ship).FullName
$plugin = 'MuGdxy-Hades2Together'
$installed = "$Ship/ReturnOfModding/plugins/$plugin"
foreach ($file in Get-ChildItem "$PSScriptRoot/$plugin" -File -Recurse) {
    $relative = $file.FullName.Substring("$PSScriptRoot/$plugin".Length + 1)
    if ((Get-FileHash "$installed/$relative").Hash -ne (Get-FileHash $file.FullName).Hash) { throw "Client package differs: $relative" }
}
if (Test-Path -LiteralPath $ProfileDirectory) { throw 'Use a fresh isolated client profile' }
$profilePath = (New-Item -ItemType Directory -Path $ProfileDirectory).FullName
$null = New-Item -ItemType Directory "$profilePath/Hades2Together"
$originalProfile = $env:USERPROFILE
$originalApp = $env:SteamAppId
try {
    $env:USERPROFILE = $profilePath
    $env:SteamAppId = '1145350'
    $options = @('/Windowed=true','/AllowSaveLoad=false','/UseDevSaves=true',('/DevSavePathStr="' + $profilePath + '"'),
        '/RequireFocusToUpdate=false','/DirectLoad=F_Reprieve01','/DirectLoadShell=false')
    $game = Start-Process "$Ship/Hades2.exe" -WorkingDirectory $Ship -ArgumentList $options -PassThru
    $game.WaitForExit()
    $log = "$Ship/ReturnOfModding/LogOutput.log"
    if (Test-Path $log) {
        Select-String -LiteralPath $log -SimpleMatch '[H2T-play]' | ForEach-Object Line | Set-Content "$profilePath/player-events.txt" -Encoding UTF8
    }
    exit $game.ExitCode
} finally {
    $env:USERPROFILE = $originalProfile
    $env:SteamAppId = $originalApp
}
