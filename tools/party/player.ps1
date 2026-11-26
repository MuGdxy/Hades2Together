param([string]$Plugin = "$PSScriptRoot/MuGdxy-Hades2Together")
$ErrorActionPreference = 'Stop'
$Plugin = (Resolve-Path -LiteralPath $Plugin).Path
$journal = [IO.Path]::GetTempFileName()
$utf8 = New-Object Text.UTF8Encoding($false)
try {
    Write-Host "Player log: $journal.log"
    $worker = Start-Process (Get-Command texlua.exe).Source -NoNewWindow -PassThru -ArgumentList @(
        ('"' + $PSScriptRoot + '/player.lua"'), ('"' + $Plugin + '"'), ('"' + $journal + '"'))
    while (!$worker.HasExited -and !(Test-Path -LiteralPath "$journal.joined")) { Start-Sleep -Milliseconds 50 }
    Write-Host 'Commands: status | input X Y [actions] | boon opportunity option | quit'
    while (!$worker.HasExited) {
        $line = [Console]::ReadLine()
        if ($null -eq $line) { $line = 'quit' }
        [IO.File]::AppendAllText($journal, $line + "`n", $utf8)
        if ($line.Trim() -eq 'quit') { break }
    }
    $worker.WaitForExit()
    if ($worker.ExitCode) { throw "Player exited with code $($worker.ExitCode)" }
} finally {
    if ($worker -and !$worker.HasExited) { $worker.Kill(); $worker.WaitForExit() }
    Remove-Item -LiteralPath $journal,"$journal.joined" -ErrorAction SilentlyContinue
}
