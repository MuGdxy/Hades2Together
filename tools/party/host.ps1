param([switch]$Run)
$ErrorActionPreference = 'Stop'
if (!$Run) { throw 'Use -Run only for the scheduled game session.' }
$root = $PSScriptRoot
$ship = "$root/Ship"
$log = "$ship/ReturnOfModding/LogOutput.log"
if ((Test-Path "$root/run-output.txt") -or (Test-Path $log) -or (Get-Process Hades2 -ErrorAction SilentlyContinue)) {
    throw 'A game or previous run exists'
}
if ((Get-FileHash "$ship/d3d12.dll").Hash -ne '8A85AB29B5F259EBAA793FCEB53856B7CDF8F80BB3A9E63773D9030FBFF3BF3B') { throw 'Unexpected loader' }
$realSaves = Join-Path $env:USERPROFILE 'Saved Games/Hades II'
function SavedProfiles { Get-ChildItem $realSaves -File -Filter 'Profile*.sav' | Sort-Object Name | ForEach-Object { $_.Name + ' ' + (Get-FileHash $_.FullName).Hash } }
$before = @(SavedProfiles)
if (!$before.Count) { throw 'No save baseline' }
$power = & nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits
if ($LASTEXITCODE -or @($power).Count -ne 1 -or $power -notmatch '^\s*\d+\s*$' -or [int]$power -gt 10) { throw 'GPU busy or unknown' }
$gpuTasks = & nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits
if ($LASTEXITCODE -or $gpuTasks) { throw 'GPU compute occupied or unavailable' }
$before | Set-Content "$root/saves-before.txt"
$profilePath = "$root/profile"
$game = $null
$observer = $null
$recorder = $null
$originalProfile = $env:USERPROFILE
$originalShip = $env:H2T_SAMPLER_SCRATCH_SHIP
$originalApp = $env:SteamAppId
function Record($line) { $line | Tee-Object -FilePath "$root/run-output.txt" -Append }
try {
    $lua = (Get-Command texlua.exe).Source
    $env:USERPROFILE = $profilePath
    $env:H2T_SAMPLER_SCRATCH_SHIP = $ship
    $env:SteamAppId = '1145350'
    $options = @('/Windowed=true','/X=960','/Y=540','/RequireFocusToUpdate=false','/AllowSaveLoad=false',
        '/UseDevSaves=true',('/DevSavePathStr="' + $profilePath + '"'),'/AllowControlHotSwap=false',
        '/DirectLoad=F_Combat02','/DirectLoadShell=false')
    $observer = Start-Process $lua -ArgumentList ('"'+$root+'/observe.lua" "'+$root+'"') -PassThru -WindowStyle Hidden -RedirectStandardError "$root/observer.err"
    # The player controlling the stock hero uses the original menu in this window.
    $game = Start-Process "$ship/Hades2.exe" -WorkingDirectory $ship -ArgumentList $options -PassThru
    $null = $game.Handle
    Record ("start_utc=" + [datetime]::UtcNow.ToString('o') + " pid=" + $game.Id)
    # This console takes ffmpeg's q after the players finish choosing.
    $recorder = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
        ('"'+$root+'/record.ps1"'),'-GamePid',$game.Id,'-RunRoot',('"'+$root+'"')) -PassThru
    $game.WaitForExit()
    Record "game_exit=$($game.ExitCode)"
} finally {
    $env:USERPROFILE = $originalProfile
    $env:H2T_SAMPLER_SCRATCH_SHIP = $originalShip
    $env:SteamAppId = $originalApp
    if ($observer -and !$observer.WaitForExit(2500)) { $observer.Kill(); $observer.WaitForExit() }
    if ($observer) { Record "observer_exit=$($observer.ExitCode)" }
    if ($recorder) {
        if (!$recorder.HasExited) { Write-Host 'Press q in the recording console to finalize the game-window clip.' }
        $recorder.WaitForExit()
        Record "recorder_exit=$($recorder.ExitCode)"
        if (Test-Path "$root/pair-movement-window.mp4") {
            Record ("clip=pair-movement-window.mp4 sha256=" + (Get-FileHash "$root/pair-movement-window.mp4").Hash)
        }
    }
    if (Test-Path $log) {
        Select-String -LiteralPath $log -SimpleMatch '[H2T-party]' | ForEach-Object Line | Set-Content "$root/stages.txt" -Encoding UTF8
    }
    $after = @(SavedProfiles)
    $after | Set-Content "$root/saves-after.txt"
    $parity = !(Compare-Object $before $after)
    Record "save_parity=$parity count=$($after.Count)"
}
if (!$parity -or !$observer -or $observer.ExitCode -ne 0 -or !$recorder -or $recorder.ExitCode -ne 0 -or !$game -or $game.ExitCode -ne 0) { exit 1 }
