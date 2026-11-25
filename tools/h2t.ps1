# Talks to a running Hades II process that has Hades2Together loaded.
# Examples:
#   .\tools\h2t.ps1 status
#   .\tools\h2t.ps1 players
#   .\tools\h2t.ps1 player add
#   .\tools\h2t.ps1 player add "Second Melinoe"
#   .\tools\h2t.ps1 player remove 2

[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 27779,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Command
)

$line = ($Command -join " ").Trim()
if (-not $line) {
    Write-Error "usage: h2t.ps1 status | players | player add [name] | player remove <slot|name>"
    exit 2
}

$client = New-Object System.Net.Sockets.TcpClient
try {
    $client.Connect("127.0.0.1", $Port)
} catch {
    Write-Error "游戏未在 127.0.0.1:${Port} 上监听。先启动带 Hades2Together 的哈迪斯 2。"
    exit 1
}

$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream, [Text.Encoding]::UTF8)
$writer.NewLine = "`n"
$writer.AutoFlush = $true
$reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
$writer.WriteLine($line)
$response = $reader.ReadLine()
$writer.Dispose()
$reader.Dispose()
$client.Close()

if (-not $response) {
    Write-Error "游戏没有返回结果。"
    exit 1
}

Write-Output $response
if ($response.StartsWith("ERR")) {
    exit 1
}
