# Local control page for a running Hades II with this mod loaded.
#   .\tools\h2t.ps1
# Then open http://127.0.0.1:27779/
#
# Commands can also be queued without the page:
#   .\tools\h2t.ps1 player add
#   .\tools\h2t.ps1 player add "Second Melinoe"
#   .\tools\h2t.ps1 player remove 2
#   .\tools\h2t.ps1 enter
#   .\tools\h2t.ps1 input 1 0 0 Attack1
#   .\tools\h2t.ps1 help
#   .\tools\h2t.ps1 status

[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 27779,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Command
)

$control = Join-Path $env:USERPROFILE "Hades2Together"
$commandsPath = Join-Path $control "commands.txt"
$statusPath = Join-Path $control "status.txt"
New-Item -ItemType Directory -Force -Path $control | Out-Null

function Add-ControlCommand([string]$Line) {
    if ($Line -match '[\r\n]') {
        throw 'Expected one command per line.'
    }
    $stream = [IO.File]::Open($commandsPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Line + "`n")
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
}

function Get-ControlStatus {
    $snapshot = ""
    try {
        $snapshot = [IO.File]::ReadAllText($statusPath).TrimEnd()
    } catch [IO.IOException] {
        # The game may be publishing a status update.
    }
    if (-not $snapshot) {
        $snapshot = "control=waiting for game status"
    }
    if (Test-Path -LiteralPath $commandsPath) {
        return "queue=waiting for game update`n$snapshot"
    }
    return $snapshot
}

if ($Command -and $Command.Count -gt 0) {
    foreach ($word in $Command) {
        if ($word -match '[\r\n]') {
            Write-Error "Expected single-line arguments."
            exit 2
        }
    }
    $head = $Command[0]
    $action = if ($Command.Count -ge 2) { $Command[1] } else { "" }
    if ($head -eq "help" -and $Command.Count -eq 1) {
        Add-ControlCommand "help"
        Write-Output "input <seat> <moveX> <moveY> [action ...]"
        Write-Output "queued help. Run h2t.ps1 status after the game polls to see the V1 action names."
        exit 0
    }
    if ($head -eq "input") {
        if ($Command.Count -lt 4 -or ($Command[1..($Command.Count - 1)] -match '^$|\s')) {
            Write-Error "usage: h2t.ps1 input <seat> <moveX> <moveY> [action ...]"
            exit 2
        }
        $line = "input " + ($Command[1..($Command.Count - 1)] -join " ")
        Add-ControlCommand $line
        Write-Output "queued $line"
        exit 0
    }
    if ($head -eq "play") {
        $sample = Join-Path (Split-Path $PSScriptRoot -Parent) "control\inputs.txt"
        $dest = Join-Path $control "inputs.txt"
        if (-not (Test-Path $dest) -and (Test-Path $sample)) {
            Copy-Item $sample $dest
        }
        Add-ControlCommand "play"
        Write-Output "queued play"
        exit 0
    }
    if ($head -eq "enter") {
        if ($Command.Count -gt 2 -or ($Command.Count -eq 2 -and $Command[1] -cnotmatch '^[A-Za-z0-9_]+\z')) {
            Write-Error "usage: h2t.ps1 enter [F_Test | F_Combat01]"
            exit 2
        }
        $map = "F_Test"
        if ($Command.Count -ge 2) { $map = $Command[1] }
        Add-ControlCommand "enter $map"
        Write-Output "queued enter $map"
        exit 0
    }
    if ($head -eq "status" -or $head -eq "players") {
        Write-Output (Get-ControlStatus)
        exit 0
    }
    if ($head -eq "player" -and $action -eq "add") {
        $line = "player add"
        if ($Command.Count -ge 3) {
            $line += " " + ($Command[2..($Command.Count - 1)] -join " ")
        }
        Add-ControlCommand $line
        Write-Output "queued $line"
        exit 0
    }
    if ($head -eq "player" -and $action -eq "remove") {
        if ($Command.Count -lt 3) {
            Write-Error "usage: h2t.ps1 player remove <slot|name>"
            exit 2
        }
        $line = "player remove " + ($Command[2..($Command.Count - 1)] -join " ")
        Add-ControlCommand $line
        Write-Output "queued $line"
        exit 0
    }
    Write-Error "usage: h2t.ps1 [help | input <seat> <moveX> <moveY> [action ...] | enter [map] | play | status | players | player add [name] | player remove <slot|name>]"
    exit 2
}

$page = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>Hades2Together</title>
<style>
  body { font: 16px/1.5 sans-serif; margin: 32px; background: #141210; color: #f3ead7; }
  h1 { font-size: 28px; margin: 0 0 8px; }
  p { color: #b7aa96; max-width: 40em; }
  button, input { font: inherit; padding: 8px 12px; margin: 0 8px 8px 0; }
  button { background: #f3ead7; color: #141210; border: 0; cursor: pointer; }
  input { background: #241f1a; color: #f3ead7; border: 1px solid #5c5144; }
  pre { background: #241f1a; padding: 16px; white-space: pre-wrap; }
</style>
</head>
<body>
<h1>多人游戏</h1>
<p>命令会先排队，游戏开始更新后会执行并写回席位。</p>
<pre id="status">读取中…</pre>
<button id="add" type="button">加入假玩家</button>
<input id="name" placeholder="名字">
<button id="addNamed" type="button">按名字加入</button>
<input id="who" placeholder="席位或名字">
<button id="remove" type="button">移除</button>
<script>
async function refresh() {
  const response = await fetch("/api/status");
  document.getElementById("status").textContent = await response.text();
}
async function send(url) {
  await fetch(url, { method: "POST" });
  refresh();
}
document.getElementById("add").onclick = function () { send("/api/player/add"); };
document.getElementById("addNamed").onclick = function () {
  var name = document.getElementById("name").value;
  send("/api/player/add?name=" + encodeURIComponent(name));
};
document.getElementById("remove").onclick = function () {
  var who = document.getElementById("who").value;
  send("/api/player/remove?who=" + encodeURIComponent(who));
};
refresh();
setInterval(refresh, 1000);
</script>
</body>
</html>
'@

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Output "http://127.0.0.1:$Port/"

function Write-Response($context, $contentType, $body) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $context.Response.ContentType = $contentType
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
}

function Get-QueryValue($url, $key) {
    $query = $url.Query.TrimStart("?")
    foreach ($pair in $query.Split("&")) {
        $bits = $pair.Split("=", 2)
        if ($bits.Length -eq 2 -and [Uri]::UnescapeDataString($bits[0]) -eq $key) {
            return [Uri]::UnescapeDataString($bits[1].Replace("+", " "))
        }
    }
    return ""
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $path = $context.Request.Url.AbsolutePath
    try {
        if ($path -eq "/" -or $path -eq "/index.html") {
            Write-Response $context "text/html; charset=utf-8" $page
        } elseif ($path -eq "/api/status") {
            Write-Response $context "text/plain; charset=utf-8" ((Get-ControlStatus) + "`n")
        } elseif ($path -eq "/api/player/add") {
            $name = Get-QueryValue $context.Request.Url "name"
            $line = "player add"
            if ($name) { $line += " " + $name }
            Add-ControlCommand $line
            Write-Response $context "text/plain; charset=utf-8" "queued $line`n"
        } elseif ($path -eq "/api/player/remove") {
            $who = Get-QueryValue $context.Request.Url "who"
            if (-not $who) {
                Write-Response $context "text/plain; charset=utf-8" "ERR name required`n"
            } else {
                $line = "player remove $who"
                Add-ControlCommand $line
                Write-Response $context "text/plain; charset=utf-8" "queued $line`n"
            }
        } else {
            $context.Response.StatusCode = 404
            Write-Response $context "text/plain; charset=utf-8" "ERR not found`n"
        }
    } catch {
        $context.Response.StatusCode = 500
        Write-Response $context "text/plain; charset=utf-8" "ERR internal`n"
    }
}
