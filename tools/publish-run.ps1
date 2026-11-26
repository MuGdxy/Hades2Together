# Publish the original records of a completed run to the local control page.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [string]$ControlRoot = (Join-Path $env:USERPROFILE 'Hades2Together')
)

$ErrorActionPreference = 'Stop'
$run = Get-Item -LiteralPath $RunDirectory
if (-not $run.PSIsContainer -or $run.Name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z') {
    throw 'Expected a run directory with a valid archive name.'
}

$names = 'run-output.txt', 'stages.txt', 'snapshots.tsv', 'door.log'
$files = @(foreach ($name in $names) {
    $source = Join-Path $run.FullName $name
    if (Test-Path -LiteralPath $source -PathType Leaf) { Get-Item -LiteralPath $source }
})
if ($files.Count -eq 0) { throw 'No control-page records found in this run.' }

$history = [IO.Directory]::CreateDirectory((Join-Path $ControlRoot 'history'))
$archive = Join-Path $history.FullName $run.Name
# A dot-prefixed staging directory stays out of the HTTP index until publication.
$staging = Join-Path $history.FullName ('.' + [Guid]::NewGuid().ToString('N'))
if (-not [IO.Directory]::Exists($archive)) {
    [void][IO.Directory]::CreateDirectory($staging)
    try {
        foreach ($file in $files) {
            [IO.File]::Copy($file.FullName, (Join-Path $staging $file.Name))
        }
        try { [IO.Directory]::Move($staging, $archive) }
        catch [IO.IOException] {
            if (-not [IO.Directory]::Exists($archive)) { throw }
            # Another publisher won the race. Check its records below.
        }
    } finally {
        if ([IO.Directory]::Exists($staging)) {
            foreach ($file in $files) { [IO.File]::Delete((Join-Path $staging $file.Name)) }
            [IO.Directory]::Delete($staging)
        }
    }
}
foreach ($name in $names) {
    $source = Join-Path $run.FullName $name
    $saved = Join-Path $archive $name
    $hasSource = Test-Path -LiteralPath $source -PathType Leaf
    $hasSaved = Test-Path -LiteralPath $saved -PathType Leaf
    if ($hasSource -ne $hasSaved -or ($hasSource -and
        (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $saved).Hash)) {
        throw "Run archive differs from source: $name"
    }
}
Write-Output $archive
