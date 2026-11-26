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
$lastReadOnlyStatus = ""
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

function Initialize-Playback {
    $sample = Join-Path (Split-Path $PSScriptRoot -Parent) "control\inputs.txt"
    $dest = Join-Path $control "inputs.txt"
    if (-not (Test-Path -LiteralPath $dest) -and (Test-Path -LiteralPath $sample)) {
        Copy-Item -LiteralPath $sample -Destination $dest
    }
}

function Test-MapName([string]$Name) {
    return $Name -cmatch '^[A-Za-z0-9_]+\z'
}

function Get-BoonCommand([string]$Seat, [string]$Opportunity, [string]$Option) {
    $ids = $Opportunity.Split('/')
    if ($ids.Count -ne 3 -or $Option -cnotmatch '\A[A-Za-z0-9_]{1,128}\z') { return }
    foreach ($id in (@($Seat) + $ids)) {
        if ($id -cnotmatch '\A[1-9][0-9]{0,15}\z' -or [long]$id -gt 9007199254740991) { return }
    }
    return "boon $Seat $Opportunity $Option"
}

function Test-BoonAuthority([string]$Snapshot) {
    return ($Snapshot -cmatch '(?m)^control=polling\r?$' -and $Snapshot -cmatch '(?m)^OK role=serve(?:\+play)? players=')
}

function Get-ReadOnlyMode([string]$Snapshot) {
    if ($Snapshot -cmatch '\Acontrol=(observer|play)(?:\r?\n|\z)') { return $Matches[1] }
    if ($Snapshot -and 'control=play'.StartsWith($Snapshot, [StringComparison]::Ordinal)) { return 'play' }
    if ($Snapshot -and 'control=observer'.StartsWith($Snapshot, [StringComparison]::Ordinal)) { return 'observer' }
}

function Get-ControlStatus {
    $snapshot = ""
    try {
        $snapshot = [IO.File]::ReadAllText($statusPath).TrimEnd()
    } catch [IO.IOException] {
        # The game may be publishing a status update.
    }
    $mode = Get-ReadOnlyMode $snapshot
    if ($mode) {
        if ($snapshot -cmatch '\r?\nobserverStatus=complete\z') {
            $script:lastReadOnlyStatus = $snapshot.Substring(0, $snapshot.Length - $Matches[0].Length)
            return $script:lastReadOnlyStatus
        }
        if ($script:lastReadOnlyStatus -and
            ($snapshot -notmatch '\Acontrol=(observer|play)(?:\r?\n|\z)' -or
             (Get-ReadOnlyMode $script:lastReadOnlyStatus) -eq $mode)) {
            return $script:lastReadOnlyStatus
        }
        if ($mode -eq 'observer') {
            return "control=observer`nRead-only observer`nsnapshot=waiting"
        }
        return "control=play`nsnapshot=waiting"
    }
    if (-not $snapshot) {
        if ($script:lastReadOnlyStatus) { return $script:lastReadOnlyStatus }
        $snapshot = "control=waiting for game status"
    }
    $script:lastReadOnlyStatus = ""
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
    if ($head -in 'input', 'play', 'enter', 'player' -and (Get-ReadOnlyMode (Get-ControlStatus))) {
        Write-Error "The current observer or play client is read-only."
        exit 2
    }
    if ($head -eq "help" -and $Command.Count -eq 1) {
        if (-not (Get-ReadOnlyMode (Get-ControlStatus))) { Add-ControlCommand "help" }
        Write-Output "input <seat> <moveX> <moveY> [action ...]"
        Write-Output "boon <seat> <room/reward/round> <option>"
        Write-Output "player remove <slot|name> marks the seat offline. Use player add <same name> to reconnect."
        if (Get-ReadOnlyMode (Get-ControlStatus)) {
            Write-Output "Read-only client. Run h2t.ps1 status to view the latest snapshot."
        } else {
            Write-Output "queued help. Run h2t.ps1 status after the game polls to see the V1 action names."
        }
        exit 0
    }
    if ($head -eq "boon") {
        if (-not (Test-BoonAuthority (Get-ControlStatus))) {
            Write-Error "Boon claims require the local polling authority."
            exit 2
        }
        $line = if ($Command.Count -eq 4) { Get-BoonCommand $Command[1] $Command[2] $Command[3] }
        if (-not $line) {
            Write-Error "usage: h2t.ps1 boon <seat> <room/reward/round> <option>"
            exit 2
        }
        Add-ControlCommand $line
        Write-Output "queued $line"
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
        Initialize-Playback
        Add-ControlCommand "play"
        Write-Output "queued play"
        exit 0
    }
    if ($head -eq "enter") {
        if ($Command.Count -gt 2 -or ($Command.Count -eq 2 -and -not (Test-MapName $Command[1]))) {
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
    Write-Error "usage: h2t.ps1 [help | input <seat> <moveX> <moveY> [action ...] | boon <seat> <room/reward/round> <option> | enter [map] | play | status | players | player add [name] | player remove <slot|name>]"
    exit 2
}

$webRoot = Join-Path $PSScriptRoot 'control-web'
$historyRoot = Join-Path $control 'history'
$historyFiles = @('run-output.txt', 'stages.txt', 'snapshots.tsv', 'door.log')
$assets = @{
    '/' = @('index.html', 'text/html')
    '/index.html' = @('index.html', 'text/html')
    '/control.css' = @('control.css', 'text/css')
    '/control.js' = @('control.js', 'text/javascript')
}

function Write-Response($context, [int]$code, [string]$contentType, [string]$body) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $response = $context.Response
    $response.StatusCode = $code
    $response.ContentType = "$contentType; charset=utf-8"
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['Content-Security-Policy'] = "default-src 'self'; frame-ancestors 'none'; base-uri 'none'"
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.Close()
}

function Get-HistoryItem([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return $item
    }
}

function Get-HistoryRun([string]$Id) {
    if ($Id -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z') { return }
    $root = Get-HistoryItem $historyRoot
    if ($root -and $root.PSIsContainer) {
        $run = Get-HistoryItem (Join-Path $root.FullName $Id)
        if ($run -and $run.PSIsContainer) { return $run }
    }
}

function Get-HistoryFiles($Run) {
    foreach ($name in $historyFiles) {
        $file = Get-HistoryItem (Join-Path $Run.FullName $name)
        if ($file -and -not $file.PSIsContainer) { $file }
    }
}

function Get-HistoryIndex {
    $root = Get-HistoryItem $historyRoot
    if (-not $root -or -not $root.PSIsContainer) { return }
    foreach ($dir in (Get-ChildItem -LiteralPath $root.FullName -Directory | Sort-Object Name -Descending)) {
        $run = Get-HistoryRun $dir.Name
        if (-not $run) { continue }
        $files = @(Get-HistoryFiles $run)
        if ($files.Count) {
            [ordered]@{ id = $run.Name; files = @($files | ForEach-Object Name) }
        }
    }
}

function Test-InputAxis([string]$Axis) {
    $number = 0.0
    return [double]::TryParse($Axis, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -ge -1 -and $number -le 1
}

function Get-WebQuery($Url) {
    $query = @{}
    foreach ($pair in $Url.Query.TrimStart('?').Split('&')) {
        if (-not $pair) { continue }
        $parts = $pair.Split('=', 2)
        if ($parts.Length -ne 2) { return }
        $key = [Uri]::UnescapeDataString($parts[0])
        if ($query.ContainsKey($key)) { return }
        $query[$key] = [Uri]::UnescapeDataString($parts[1].Replace('+', ' '))
    }
    return $query
}

function Get-WebCommand($Request) {
    $query = Get-WebQuery $Request.Url
    if ($null -eq $query) { return }
    switch ($Request.Url.AbsolutePath) {
        '/api/boon' {
            if ($query.Count -eq 3 -and $query.ContainsKey('seat') -and $query.ContainsKey('opportunity') -and
                $query.ContainsKey('option') -and -not $Request.HasEntityBody) {
                return (Get-BoonCommand $query['seat'] $query['opportunity'] $query['option'])
            }
        }
        '/api/enter' {
            $map = [string]$query['map']
            if (-not $map) { $map = 'F_Test' }
            if (Test-MapName $map) { return "enter $map" }
        }
        '/api/play' {
            return 'play'
        }
        '/api/player/add' {
            $name = ([string]$query['name']).Trim()
            if ($name -match '[\x00-\x1F\x7F]') { return }
            if ($name) { return "player add $name" }
            return 'player add'
        }
        '/api/player/remove' {
            $who = ([string]$query['who']).Trim()
            if ($who -and $who -notmatch '[\x00-\x1F\x7F]') { return "player remove $who" }
        }
        '/api/input' {
            $seat = [string]$query['seat']
            $x = [string]$query['x']
            $y = [string]$query['y']
            $buttons = ([string]$query['actions']).Trim()
            if ($seat -cnotmatch '\A[1-9][0-9]{0,15}\z' -or [long]$seat -gt 9007199254740991 -or
                $x -match '\s' -or $y -match '\s' -or
                -not (Test-InputAxis $x) -or -not (Test-InputAxis $y)) { return }
            if ($buttons -and $buttons -cnotmatch '\A(Attack1|Attack2)( (Attack1|Attack2))?\z') { return }
            return ("input $seat $x $y $buttons").TrimEnd()
        }
    }
}

$listener = New-Object System.Net.HttpListener
$address = "http://127.0.0.1:$Port"
$listener.Prefixes.Add("$address/")
$listener.Start()
Write-Output "$address/"
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $path = $request.Url.AbsolutePath
        try {
            if ($path -in '/api/player/add', '/api/player/remove', '/api/input', '/api/enter', '/api/play', '/api/boon') {
                $snapshot = Get-ControlStatus
                if ($request.HttpMethod -ne 'POST') {
                    $context.Response.Headers['Allow'] = 'POST'
                    Write-Response $context 405 'text/plain' "ERR POST required`n"
                } elseif (($request.Headers['Origin'] -and $request.Headers['Origin'] -cne $address) -or
                          $request.Headers['Sec-Fetch-Site'] -eq 'cross-site') {
                    Write-Response $context 403 'text/plain' "ERR local page required`n"
                } elseif (Get-ReadOnlyMode $snapshot) {
                    Write-Response $context 409 'text/plain' "ERR observer or play client is read-only`n"
                } elseif ($path -eq '/api/boon' -and -not (Test-BoonAuthority $snapshot)) {
                    Write-Response $context 409 'text/plain' "ERR local polling authority required`n"
                } else {
                    $line = Get-WebCommand $request
                    if ($line) {
                        if ($line -eq 'play') { Initialize-Playback }
                        Add-ControlCommand $line
                        Write-Response $context 200 'text/plain' "queued $line`n"
                    } else {
                        Write-Response $context 400 'text/plain' "ERR invalid command arguments`n"
                    }
                }
            } elseif ($request.HttpMethod -ne 'GET') {
                $context.Response.Headers['Allow'] = 'GET'
                Write-Response $context 405 'text/plain' "ERR GET required`n"
            } elseif ($assets.ContainsKey($path)) {
                $asset, $type = $assets[$path]
                Write-Response $context 200 $type ([IO.File]::ReadAllText((Join-Path $webRoot $asset)))
            } elseif ($path -eq '/api/status') {
                Write-Response $context 200 'text/plain' ((Get-ControlStatus) + "`n")
            } elseif ($path -eq '/api/live') {
                $status = Get-ControlStatus
                $file = Get-Item -LiteralPath $statusPath -ErrorAction SilentlyContinue
                $updated = $null
                if ($file) { $updated = $file.LastWriteTimeUtc.ToString('o') }
                $body = @{ status = $status; updatedAt = $updated } | ConvertTo-Json -Compress
                Write-Response $context 200 'application/json' $body
            } elseif ($path -eq '/api/history') {
                Write-Response $context 200 'application/json' (ConvertTo-Json -InputObject @(Get-HistoryIndex) -Depth 4 -Compress)
            } elseif ($path -eq '/api/history/file') {
                $query = Get-WebQuery $request.Url
                $run = if ($query) { Get-HistoryRun $query['run'] }
                $name = if ($query) { [string]$query['file'] }
                $file = if ($run -and $name -cin $historyFiles) {
                    Get-HistoryItem (Join-Path $run.FullName $name)
                }
                if ($file -and -not $file.PSIsContainer) {
                    Write-Response $context 200 'text/plain' ([IO.File]::ReadAllText($file.FullName))
                } else {
                    Write-Response $context 404 'text/plain' "ERR record not found`n"
                }
            } else {
                Write-Response $context 404 'text/plain' "ERR not found`n"
            }
        } catch {
            try { Write-Response $context 500 'text/plain' "ERR internal`n" } catch { $context.Response.Abort() }
        }
    }
} finally {
    $listener.Close()
}
