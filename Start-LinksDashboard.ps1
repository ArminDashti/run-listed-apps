#Requires -Version 5.1
<#
.SYNOPSIS
  Serve an HTML links page for apps started by Run-ListedApps.ps1 on http://127.0.0.1:5050/
#>
[CmdletBinding()]
param(
    [string]$StatePath = "",
    [int]$Port = 5050
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $ScriptDir ".run-listed-apps-state.json"
}

function Get-ListeningPortSet {
    $set = New-Object "System.Collections.Generic.HashSet[int]"
    try {
        foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            if ($c.LocalPort) { [void]$set.Add([int]$c.LocalPort) }
        }
    } catch {
        netstat -ano | Select-String "LISTENING" | ForEach-Object {
            if ($_.Line -match ':(\d+)\s+') {
                [void]$set.Add([int]$Matches[1])
            }
        }
    }
    return $set
}

function Get-AppRows {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return @()
    }
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $listening = Get-ListeningPortSet
    $byKey = @{}
    foreach ($p in @($state.processes)) {
        if (-not $p.name -or -not $p.role) { continue }
        if ($p.role -eq "dashboard") { continue }
        $key = "{0}|{1}" -f $p.name, $p.role
        $byKey[$key] = $p
    }
    $names = @($byKey.Values | ForEach-Object { $_.name } | Sort-Object -Unique)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($name in $names) {
        $api = $byKey["$name|api"]
        $webui = $byKey["$name|webui"]
        $apiUrl = $null
        $webuiUrl = $null
        $apiUp = $false
        $webuiUp = $false
        if ($api -and $api.url -and $api.wait -ne $false) {
            $apiUrl = [string]$api.url
            if ($api.port) { $apiUp = $listening.Contains([int]$api.port) }
        }
        if ($webui -and $webui.url) {
            $webuiUrl = [string]$webui.url
            if ($webui.port) { $webuiUp = $listening.Contains([int]$webui.port) }
        }
        [void]$rows.Add([pscustomobject]@{
            name     = $name
            apiUrl   = $apiUrl
            webuiUrl = $webuiUrl
            apiUp    = $apiUp
            webuiUp  = $webuiUp
            agent    = ($api -and $api.wait -eq $false)
        })
    }
    return $rows
}

function Escape-Html {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Build-Html {
    $rows = @(Get-AppRows)
    $startedAt = ""
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $startedAt = (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).startedAt
        } catch { }
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head>')
    [void]$sb.AppendLine('<meta charset="utf-8" />')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1" />')
    [void]$sb.AppendLine('<meta http-equiv="refresh" content="5" />')
    [void]$sb.AppendLine('<title>run-listed-apps</title>')
    [void]$sb.AppendLine('<style>
:root { color-scheme: light dark; }
body { font-family: Segoe UI, system-ui, sans-serif; margin: 0; padding: 2rem; background: #0f1419; color: #e7ecf1; }
h1 { font-size: 1.5rem; margin: 0 0 0.25rem; font-weight: 650; }
.sub { color: #9aa7b5; margin-bottom: 1.5rem; font-size: 0.95rem; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 0.7rem 0.85rem; border-bottom: 1px solid #243041; vertical-align: middle; }
th { color: #9aa7b5; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; font-weight: 600; }
a { color: #7dd3fc; text-decoration: none; }
a:hover { text-decoration: underline; }
.badge { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 999px; font-size: 0.75rem; font-weight: 600; }
.up { background: #14532d; color: #bbf7d0; }
.down { background: #7f1d1d; color: #fecaca; }
.na { background: #1f2937; color: #9ca3af; }
.name { font-weight: 600; }
.empty { color: #9aa7b5; padding: 2rem 0; }
</style>')
    [void]$sb.AppendLine('</head><body>')
    [void]$sb.AppendLine('<h1>run-listed-apps</h1>')
    [void]$sb.AppendLine(('<p class="sub">Links for apps started by this runner. Auto-refresh every 5s. Started: {0}</p>' -f (Escape-Html $startedAt)))
    if ($rows.Count -eq 0) {
        [void]$sb.AppendLine('<p class="empty">No apps in state file yet. Run <code>.\Run-ListedApps.ps1</code> first.</p>')
    } else {
        [void]$sb.AppendLine('<table><thead><tr><th>App</th><th>WebUI</th><th>API</th></tr></thead><tbody>')
        foreach ($r in $rows) {
            $name = Escape-Html $r.name
            $webuiCell = '<span class="badge na">—</span>'
            $apiCell = '<span class="badge na">—</span>'
            if ($r.webuiUrl) {
                $u = Escape-Html $r.webuiUrl
                $badge = if ($r.webuiUp) { '<span class="badge up">up</span>' } else { '<span class="badge down">down</span>' }
                $webuiCell = "$badge <a href=`"$u`" target=`"_blank`" rel=`"noopener`">$u</a>"
            }
            if ($r.agent) {
                $apiCell = '<span class="badge na">agent (no HTTP)</span>'
            } elseif ($r.apiUrl) {
                $u = Escape-Html $r.apiUrl
                $badge = if ($r.apiUp) { '<span class="badge up">up</span>' } else { '<span class="badge down">down</span>' }
                $apiCell = "$badge <a href=`"$u`" target=`"_blank`" rel=`"noopener`">$u</a>"
            }
            [void]$sb.AppendLine(("<tr><td class=`"name`">{0}</td><td>{1}</td><td>{2}</td></tr>" -f $name, $webuiCell, $apiCell))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    [void]$sb.AppendLine('</body></html>')
    return $sb.ToString()
}

function Read-HttpRequest {
    param([System.Net.Sockets.NetworkStream]$Stream)
    $buffer = New-Object byte[] 4096
    $ms = New-Object System.IO.MemoryStream
    $Stream.ReadTimeout = 5000
    while ($true) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $ms.Write($buffer, 0, $read)
        $text = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
        if ($text -match "`r`n`r`n") { break }
        if ($ms.Length -gt 65536) { break }
    }
    return [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
}

function Write-HttpResponse {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode,
        [string]$ContentType,
        [byte[]]$Body
    )
    $reason = switch ($StatusCode) {
        200 { "OK" }
        404 { "Not Found" }
        default { "Error" }
    }
    $header = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($Body, 0, $Body.Length)
    $Stream.Flush()
}

# Clear leftover HttpListener reservation on this port if present
try {
    Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.OwningProcess -and $_.OwningProcess -ne 4) {
                Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
            }
        }
} catch { }

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
} catch {
    Write-Error "Could not bind 127.0.0.1:$Port : $_"
    exit 1
}
Write-Host "Links dashboard: http://127.0.0.1:$Port/"
Write-Host "State: $StatePath"

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $req = Read-HttpRequest -Stream $stream
        $path = "/"
        if ($req -match '^(GET|HEAD)\s+(\S+)') {
            $path = $Matches[2]
        }
        if ($path.StartsWith("/health")) {
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
            Write-HttpResponse -Stream $stream -StatusCode 200 -ContentType "application/json; charset=utf-8" -Body $body
        } else {
            $html = Build-Html
            $body = [System.Text.Encoding]::UTF8.GetBytes($html)
            Write-HttpResponse -Stream $stream -StatusCode 200 -ContentType "text/html; charset=utf-8" -Body $body
        }
    } catch {
        # ignore per-request errors
    } finally {
        if ($client) {
            try { $client.Close() } catch { }
        }
    }
}
