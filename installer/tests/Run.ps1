param(
    [Parameter(Mandatory)][string]$ScratchDirectory,
    [string]$SetupExe,
    [string]$GameDirectory
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $ScratchDirectory) { throw 'Choose a fresh fixture directory.' }
$scratch = (New-Item -ItemType Directory -Path $ScratchDirectory).FullName
. "$PSScriptRoot/../Compiler.ps1"
$sources = @(Get-ChildItem -LiteralPath "$PSScriptRoot/.." -File -Filter '*.cs' | ForEach-Object FullName)
$sources += "$PSScriptRoot/Lifecycle.cs"
$test = "$scratch/Lifecycle.exe"
Invoke-PreviewCompiler -Output $test -Sources $sources -Options @(
    '/target:exe', '/main:Hades2Together.Setup.Lifecycle', "/win32manifest:$PSScriptRoot/../Setup.manifest"
)
& $test $scratch
if ($LASTEXITCODE) { throw "Lifecycle fixture failed: $LASTEXITCODE" }
$tokens = $null
$errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile("$scratch/uninstall-command.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
if ($SetupExe -and $GameDirectory) {
    & $test $scratch '--stage' (Resolve-Path -LiteralPath $SetupExe).Path (Resolve-Path -LiteralPath $GameDirectory).Path
    if ($LASTEXITCODE) { throw "Full staging fixture failed: $LASTEXITCODE" }
}
