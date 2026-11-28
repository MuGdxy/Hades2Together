function Invoke-PreviewCompiler {
    param([string]$Output, [string[]]$Sources, [string[]]$Options)
    $sdk = @(& dotnet --list-sdks | Where-Object { $_ -match '^\d+\.\d+\.\d+ \[.+\]$' })[-1]
    if (!$sdk -or $sdk -notmatch '^([^ ]+) \[(.+)\]$') { throw 'Install a .NET SDK with C# 10 or later.' }
    $compiler = Join-Path $Matches[2] "$($Matches[1])/Roslyn/bincore/csc.dll"
    $programs = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $framework = Join-Path $programs 'Reference Assemblies/Microsoft/Framework/.NETFramework/v4.8'
    if (!(Test-Path -LiteralPath "$framework/mscorlib.dll")) {
        $framework = Join-Path $env:windir 'Microsoft.NET/Framework64/v4.0.30319'
    }
    $references = @(
        'mscorlib', 'System', 'System.Core', 'System.Drawing', 'System.Windows.Forms',
        'System.Web.Extensions', 'System.IO.Compression', 'Microsoft.CSharp'
    ) | ForEach-Object { "/reference:$framework/$_.dll" }
    & dotnet $compiler /nologo /noconfig /nostdlib+ /optimize+ /deterministic+ /warnaserror+ /langversion:10 /platform:x64 "/out:$Output" @references @Options @Sources
    if ($LASTEXITCODE) { throw "Compiler failed: $LASTEXITCODE" }
}
