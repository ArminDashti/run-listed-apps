#Requires -Version 5.1
<#
.SYNOPSIS
  Start only the API + WebUI pairs listed in apps.yaml.

.DESCRIPTION
  Never scans the GitHub folder. Disabled or missing entries are skipped.
  Uses safe free ports and prefers hot reload.
#>
[CmdletBinding()]
param(
    [string]$Config = "",
    [switch]$List,
    [switch]$Stop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($Config)) {
    $Config = Join-Path $ScriptDir "apps.yaml"
}
$StatePath = Join-Path $ScriptDir ".run-listed-apps-state.json"
$LogDir = Join-Path $ScriptDir "logs"
$UsedPorts = New-Object "System.Collections.Generic.HashSet[int]"

$ApiPortMin = 8000
$ApiPortMax = 8999
$UiPortMin = 5173
$UiPortMax = 5299

function Write-Info([string]$Message) {
    Write-Host $Message
}

function Write-WarnLine([string]$Message) {
    Write-Host "WARN  $Message" -ForegroundColor Yellow
}

function Write-ErrLine([string]$Message) {
    Write-Host "ERROR $Message" -ForegroundColor Red
}

function Read-AppsYaml {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    $rawLines = Get-Content -LiteralPath $Path -Encoding UTF8
    $root = $null
    $apps = New-Object System.Collections.Generic.List[object]
    $current = $null
    $inApps = $false

    foreach ($raw in $rawLines) {
        $withoutComment = $raw -replace '#.*$', ''
        $line = $withoutComment.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^root:\s*(.+)$') {
            $root = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }

        if ($line -match '^apps:\s*(\[\s*\]\s*)?$') {
            $inApps = $true
            continue
        }

        if ($inApps -and ($line -match '^\s*-\s+name:\s*(.+)$')) {
            if ($null -ne $current) {
                [void]$apps.Add($current)
            }
            $current = [pscustomobject]@{
                name    = $Matches[1].Trim().Trim('"').Trim("'")
                enabled = $false
                api     = $null
                webui   = $null
            }
            continue
        }

        if ($null -eq $current) {
            continue
        }

        if ($line -match '^\s+enabled:\s*(.+)$') {
            $val = $Matches[1].Trim().ToLowerInvariant()
            $current.enabled = $val -in @("true", "yes", "1")
            continue
        }
        if ($line -match '^\s+api:\s*(.+)$') {
            $current.api = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }
        if ($line -match '^\s+webui:\s*(.+)$') {
            $current.webui = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }
    }

    if ($null -ne $current) {
        [void]$apps.Add($current)
    }

    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = "C:/Users/armin/GitHub"
    }

    return [pscustomobject]@{
        Root = $root
        Apps = $apps
    }
}

function Resolve-AppPath {
    param(
        [string]$Root,
        [string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Value))
}

function Test-PortInUse {
    param([int]$Port)
    try {
        $conns = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        if ($conns.Count -gt 0) {
            return $true
        }
    } catch {
        # Fallback below.
    }
    $escaped = [regex]::Escape(":$Port")
    $hits = netstat -ano | Select-String "LISTENING" | Where-Object { $_.Line -match "$escaped\s" }
    return $null -ne $hits
}

function Find-FreePort {
    param(
        [int]$Min,
        [int]$Max
    )
    for ($p = $Min; $p -le $Max; $p++) {
        if ($UsedPorts.Contains($p)) {
            continue
        }
        if (-not (Test-PortInUse -Port $p)) {
            [void]$UsedPorts.Add($p)
            return $p
        }
    }
    throw "No free port in range $Min-$Max"
}

function Get-CommandPath {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $null
    }
    return $cmd.Source
}

function Get-PackageManager {
    param([string]$Dir)
    if (Test-Path -LiteralPath (Join-Path $Dir "pnpm-lock.yaml")) {
        $pnpm = Get-CommandPath "pnpm"
        if ($pnpm) { return @{ Exe = $pnpm; Name = "pnpm" } }
        Write-WarnLine "pnpm-lock.yaml found but pnpm is not installed; using npm"
    }
    if (Test-Path -LiteralPath (Join-Path $Dir "yarn.lock")) {
        $yarn = Get-CommandPath "yarn"
        if ($yarn) { return @{ Exe = $yarn; Name = "yarn" } }
        Write-WarnLine "yarn.lock found but yarn is not installed; using npm"
    }
    $npm = Get-CommandPath "npm.cmd"
    if (-not $npm) {
        $npm = Get-CommandPath "npm"
    }
    if ($npm) {
        return @{ Exe = $npm; Name = "npm" }
    }
    return $null
}

function Get-GoMainPackage {
    param([string]$Dir)
    $cmdDir = Join-Path $Dir "cmd"
    if (Test-Path -LiteralPath $cmdDir) {
        $mains = @(Get-ChildItem -LiteralPath $cmdDir -Recurse -Filter "main.go" -File -ErrorAction SilentlyContinue)
        if ($mains.Count -gt 0) {
            $preferred = $mains | Where-Object {
                $_.Directory.Name -in @("api", "server", "app") -or $_.Directory.Name -eq (Split-Path $Dir -Leaf)
            } | Select-Object -First 1
            if (-not $preferred) {
                $preferred = $mains[0]
            }
            $rel = $preferred.Directory.FullName.Substring($Dir.Length).TrimStart("\", "/")
            return "./" + ($rel -replace "\\", "/")
        }
    }
    if (Test-Path -LiteralPath (Join-Path $Dir "main.go")) {
        return "."
    }
    return $null
}

function Get-PythonExe {
    param([string]$Dir)
    $venv = Join-Path $Dir ".venv\Scripts\python.exe"
    if (Test-Path -LiteralPath $venv) {
        return $venv
    }
    $py = Get-CommandPath "python"
    if ($py) { return $py }
    return Get-CommandPath "py"
}

function Get-FastApiTarget {
    param([string]$Dir)
    $candidates = @(
        @{ File = "app\main.py"; Target = "app.main:app" },
        @{ File = "main.py"; Target = "main:app" },
        @{ File = "src\main.py"; Target = "src.main:app" }
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $Dir $c.File)) {
            return $c.Target
        }
    }
    return "main:app"
}

function Test-LooksLikeFastApi {
    param([string]$Dir)
    $files = @("requirements.txt", "pyproject.toml", "Pipfile")
    foreach ($f in $files) {
        $p = Join-Path $Dir $f
        if (Test-Path -LiteralPath $p) {
            $text = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            if ($text -and ($text -match "fastapi|uvicorn")) {
                return $true
            }
        }
    }
    return $false
}

function Get-ApiStack {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) {
        return $null
    }
    if (Test-Path -LiteralPath (Join-Path $Dir "go.mod")) { return "go" }
    if (Test-Path -LiteralPath (Join-Path $Dir "Cargo.toml")) { return "rust" }
    if (Test-Path -LiteralPath (Join-Path $Dir "manage.py")) { return "django" }
    if (Test-LooksLikeFastApi -Dir $Dir) { return "fastapi" }
    if ((Test-Path -LiteralPath (Join-Path $Dir "pyproject.toml")) -or (Test-Path -LiteralPath (Join-Path $Dir "requirements.txt"))) {
        return "python"
    }
    return $null
}

function Get-WebUiStack {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) {
        return $null
    }
    $pkgPath = Join-Path $Dir "package.json"
    if (-not (Test-Path -LiteralPath $pkgPath)) {
        return $null
    }
    try {
        $pkg = Get-Content -LiteralPath $pkgPath -Raw | ConvertFrom-Json
        if ($pkg.scripts -and $pkg.scripts.dev) {
            return "vite"
        }
    } catch {
        return "vite"
    }
    return "vite"
}

function Ensure-EnvFile {
    param([string]$Dir)
    if (-not $Dir) { return }
    $envFile = Join-Path $Dir ".env"
    $example = Join-Path $Dir ".env.example"
    if ((-not (Test-Path -LiteralPath $envFile)) -and (Test-Path -LiteralPath $example)) {
        Copy-Item -LiteralPath $example -Destination $envFile
        Write-Info "  copied .env.example -> .env in $(Split-Path $Dir -Leaf)"
    }
}

function Install-NodePackages {
    param([string]$Dir)
    $nm = Join-Path $Dir "node_modules"
    $lockNpm = Join-Path $Dir "package-lock.json"
    $needInstall = -not (Test-Path -LiteralPath $nm)
    if ((Test-Path -LiteralPath $lockNpm) -and (Test-Path -LiteralPath $nm)) {
        if ((Get-Item -LiteralPath $lockNpm).LastWriteTime -gt (Get-Item -LiteralPath $nm).LastWriteTime) {
            $needInstall = $true
        }
    }
    if (-not $needInstall) {
        return $true
    }
    $pm = Get-PackageManager -Dir $Dir
    if (-not $pm) {
        Write-ErrLine "Node package manager not found for $Dir"
        return $false
    }
    Write-Info "  $($pm.Name) install in $(Split-Path $Dir -Leaf)"
    $old = Get-Location
    try {
        Set-Location -LiteralPath $Dir
        if ($pm.Name -eq "npm") {
            & $pm.Exe "install" | Out-Host
        } else {
            & $pm.Exe "install" | Out-Host
        }
        return $LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE
    } finally {
        Set-Location $old
    }
}

function Start-LoggedProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [string]$LogPath,
        [hashtable]$Environment
    )

    $dirName = Split-Path $LogPath -Parent
    if (-not (Test-Path -LiteralPath $dirName)) {
        New-Item -ItemType Directory -Path $dirName | Out-Null
    }

    $oldEnv = @{}
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            $oldEnv[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
        }
    }

    try {
        $errPath = "$LogPath.err"
        $start = @{
            FilePath               = $FilePath
            WorkingDirectory       = $WorkingDirectory
            PassThru               = $true
            WindowStyle            = "Hidden"
            RedirectStandardOutput = $LogPath
            RedirectStandardError  = $errPath
        }
        if ($ArgumentList -and $ArgumentList.Count -gt 0) {
            $start.ArgumentList = $ArgumentList
        }
        return Start-Process @start
    } finally {
        if ($Environment) {
            foreach ($key in $Environment.Keys) {
                [Environment]::SetEnvironmentVariable($key, $oldEnv[$key], "Process")
            }
        }
    }
}

function Wait-PortListen {
    param(
        [int]$Port,
        [int]$TimeoutSec = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortInUse -Port $Port) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Start-ApiProcess {
    param(
        [string]$Name,
        [string]$Dir,
        [string]$Stack,
        [int]$Port,
        [int]$UiPort
    )

    Ensure-EnvFile -Dir $Dir
    $log = Join-Path $LogDir "$Name-api.log"
    $origin = "http://127.0.0.1:$UiPort"
    $envMap = @{
        PORT              = "$Port"
        API_PORT          = "$Port"
        CORS_ORIGIN       = $origin
        ALLOWED_ORIGINS   = $origin
    }

    switch ($Stack) {
        "go" {
            $go = Get-CommandPath "go"
            if (-not $go) {
                Write-ErrLine "Go is not installed; skip API for $Name"
                return $null
            }
            Write-Info "  go mod download"
            $old = Get-Location
            try {
                Set-Location -LiteralPath $Dir
                & $go "mod" "download" | Out-Host
            } finally {
                Set-Location $old
            }
            $air = Get-CommandPath "air"
            if ($air) {
                Write-Info "  hot reload: air"
                return Start-LoggedProcess -FilePath $air -ArgumentList @() -WorkingDirectory $Dir -LogPath $log -Environment $envMap
            }
            $pkg = Get-GoMainPackage -Dir $Dir
            if (-not $pkg) {
                Write-ErrLine "No Go main package found in $Dir"
                return $null
            }
            Write-Info "  hot reload: off (air not installed); go run $pkg"
            return Start-LoggedProcess -FilePath $go -ArgumentList @("run", $pkg) -WorkingDirectory $Dir -LogPath $log -Environment $envMap
        }
        "rust" {
            $cargo = Get-CommandPath "cargo"
            if (-not $cargo) {
                Write-ErrLine "Rust/cargo is not installed; skip API for $Name"
                return $null
            }
            $watch = Get-CommandPath "cargo-watch"
            if ($watch) {
                Write-Info "  hot reload: cargo watch"
                return Start-LoggedProcess -FilePath $cargo -ArgumentList @("watch", "-x", "run") -WorkingDirectory $Dir -LogPath $log -Environment $envMap
            }
            Write-Info "  hot reload: off (cargo-watch not installed); cargo run"
            return Start-LoggedProcess -FilePath $cargo -ArgumentList @("run") -WorkingDirectory $Dir -LogPath $log -Environment $envMap
        }
        "django" {
            $py = Get-PythonExe -Dir $Dir
            if (-not $py) {
                Write-ErrLine "Python is not installed; skip API for $Name"
                return $null
            }
            $req = Join-Path $Dir "requirements.txt"
            if ((Test-Path -LiteralPath $req) -and -not (Test-Path -LiteralPath (Join-Path $Dir ".venv"))) {
                Write-WarnLine "No .venv in $Dir; using system Python"
            }
            Write-Info "  hot reload: Django runserver"
            return Start-LoggedProcess -FilePath $py -ArgumentList @("manage.py", "runserver", "127.0.0.1:$Port") -WorkingDirectory $Dir -LogPath $log -Environment $envMap
        }
        "fastapi" {
            $py = Get-PythonExe -Dir $Dir
            if (-not $py) {
                Write-ErrLine "Python is not installed; skip API for $Name"
                return $null
            }
            $target = Get-FastApiTarget -Dir $Dir
            $uvicorn = Join-Path (Split-Path $py -Parent) "uvicorn.exe"
            Write-Info "  hot reload: uvicorn --reload"
            if (Test-Path -LiteralPath $uvicorn) {
                return Start-LoggedProcess -FilePath $uvicorn -ArgumentList @($target, "--reload", "--host", "127.0.0.1", "--port", "$Port") -WorkingDirectory $Dir -LogPath $log -Environment $envMap
            }
            return Start-LoggedProcess -FilePath $py -ArgumentList @("-m", "uvicorn", $target, "--reload", "--host", "127.0.0.1", "--port", "$Port") -WorkingDirectory $Dir -LogPath $log -Environment $envMap
        }
        "python" {
            Write-WarnLine "Python API stack for $Name is not Django/FastAPI; skip"
            return $null
        }
        default {
            Write-ErrLine "Unknown API stack '$Stack' for $Name"
            return $null
        }
    }
}

function Start-WebUiProcess {
    param(
        [string]$Name,
        [string]$Dir,
        [int]$Port,
        [int]$ApiPort
    )

    Ensure-EnvFile -Dir $Dir
    if (-not (Install-NodePackages -Dir $Dir)) {
        return $null
    }
    $pm = Get-PackageManager -Dir $Dir
    if (-not $pm) {
        Write-ErrLine "npm/pnpm/yarn not found; skip WebUI for $Name"
        return $null
    }
    $log = Join-Path $LogDir "$Name-webui.log"
    $apiUrl = "http://127.0.0.1:$ApiPort"
    $envMap = @{
        PORT                 = "$Port"
        VITE_API_URL         = $apiUrl
        VITE_API_BASE_URL    = $apiUrl
        NUXT_PUBLIC_API_BASE = $apiUrl
    }
    Write-Info "  hot reload: $($pm.Name) run dev --port $Port"
    $args = @("run", "dev", "--", "--host", "127.0.0.1", "--port", "$Port", "--strictPort")
    if ($pm.Name -eq "pnpm") {
        $args = @("run", "dev", "--", "--host", "127.0.0.1", "--port", "$Port", "--strictPort")
    }
    return Start-LoggedProcess -FilePath $pm.Exe -ArgumentList $args -WorkingDirectory $Dir -LogPath $log -Environment $envMap
}

function Stop-LastRun {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        Write-WarnLine "No state file; nothing to stop."
        return
    }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $stopped = 0
    foreach ($proc in @($state.processes)) {
        if (-not $proc.pid) { continue }
        try {
            $running = Get-Process -Id ([int]$proc.pid) -ErrorAction SilentlyContinue
            if ($running) {
                Stop-Process -Id ([int]$proc.pid) -Force -ErrorAction SilentlyContinue
                Write-Info "Stopped $($proc.name) $($proc.role) PID $($proc.pid)"
                $stopped++
            }
        } catch {
            Write-WarnLine "Could not stop PID $($proc.pid)"
        }
    }
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    Write-Info "Stopped $stopped process(es)."
}

function Show-List {
    param($ConfigObj)
    $enabled = @($ConfigObj.Apps | Where-Object { $_.enabled })
    Write-Info "root: $($ConfigObj.Root)"
    Write-Info "enabled apps: $($enabled.Count)"
    foreach ($app in $enabled) {
        $apiPath = Resolve-AppPath -Root $ConfigObj.Root -Value $app.api
        $uiPath = Resolve-AppPath -Root $ConfigObj.Root -Value $app.webui
        Write-Info "  - $($app.name)"
        if ($apiPath) { Write-Info "      api:   $apiPath" }
        if ($uiPath) { Write-Info "      webui: $uiPath" }
    }
    if ($enabled.Count -eq 0) {
        Write-WarnLine "Nothing enabled. Edit apps.yaml and set enabled: true."
    }
}

# --- main ---

if ($Stop) {
    Stop-LastRun
    exit 0
}

$configObj = Read-AppsYaml -Path $Config
if ($List) {
    Show-List -ConfigObj $configObj
    exit 0
}

$enabled = @($configObj.Apps | Where-Object { $_.enabled })
if ($enabled.Count -eq 0) {
    Write-WarnLine "No enabled apps in $Config"
    Write-Info "Add entries (see apps.example.yaml) and set enabled: true, then run again."
    exit 0
}

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$started = New-Object System.Collections.Generic.List[object]

foreach ($app in $enabled) {
    Write-Host ""
    Write-Info "=== $($app.name) ==="
    $apiDir = Resolve-AppPath -Root $configObj.Root -Value $app.api
    $uiDir = Resolve-AppPath -Root $configObj.Root -Value $app.webui

    if ($app.api -and -not (Test-Path -LiteralPath $apiDir)) {
        Write-ErrLine "API path missing: $apiDir"
        $apiDir = $null
    }
    if ($app.webui -and -not (Test-Path -LiteralPath $uiDir)) {
        Write-ErrLine "WebUI path missing: $uiDir"
        $uiDir = $null
    }
    if (-not $apiDir -and -not $uiDir) {
        Write-ErrLine "Skip $($app.name): no usable paths"
        continue
    }

    $apiStack = Get-ApiStack -Dir $apiDir
    $uiStack = Get-WebUiStack -Dir $uiDir
    $apiPort = $null
    $uiPort = $null
    $apiProc = $null
    $uiProc = $null

    if ($apiDir -and $apiStack) {
        $apiPort = Find-FreePort -Min $ApiPortMin -Max $ApiPortMax
    }
    if ($uiDir -and $uiStack) {
        $uiPort = Find-FreePort -Min $UiPortMin -Max $UiPortMax
    }
    if (-not $uiPort) { $uiPort = 5173 }

    if ($apiDir -and $apiStack) {
        Write-Info "API stack: $apiStack  port: $apiPort"
        $apiProc = Start-ApiProcess -Name $app.name -Dir $apiDir -Stack $apiStack -Port $apiPort -UiPort $uiPort
        if ($apiProc) {
            $ok = Wait-PortListen -Port $apiPort
            if ($ok) {
                Write-Info "API listening http://127.0.0.1:$apiPort  PID $($apiProc.Id)"
            } else {
                Write-WarnLine "API did not listen on $apiPort within timeout. See logs/$($app.name)-api.log"
            }
            [void]$started.Add([pscustomobject]@{ name = $app.name; role = "api"; pid = $apiProc.Id; port = $apiPort; url = "http://127.0.0.1:$apiPort" })
        }
    } elseif ($apiDir) {
        Write-WarnLine "Could not detect API stack in $apiDir"
    }

    if ($uiDir -and $uiStack) {
        $bindApi = 8000
        if ($apiPort) { $bindApi = $apiPort }
        Write-Info "WebUI stack: $uiStack  port: $uiPort"
        $uiProc = Start-WebUiProcess -Name $app.name -Dir $uiDir -Port $uiPort -ApiPort $bindApi
        if ($uiProc) {
            $ok = Wait-PortListen -Port $uiPort
            if ($ok) {
                Write-Info "WebUI listening http://127.0.0.1:$uiPort  PID $($uiProc.Id)"
            } else {
                Write-WarnLine "WebUI did not listen on $uiPort within timeout. See logs/$($app.name)-webui.log"
            }
            [void]$started.Add([pscustomobject]@{ name = $app.name; role = "webui"; pid = $uiProc.Id; port = $uiPort; url = "http://127.0.0.1:$uiPort" })
        }
    } elseif ($uiDir) {
        Write-WarnLine "Could not detect WebUI stack in $uiDir"
    }
}

$state = [pscustomobject]@{
    startedAt  = (Get-Date).ToString("s")
    processes  = $started
}
$state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8

Write-Host ""
Write-Info "Summary"
if ($started.Count -eq 0) {
    Write-WarnLine "No processes started."
} else {
    foreach ($row in $started) {
        Write-Info ("  {0,-16} {1,-6} {2,-28} PID {3}" -f $row.name, $row.role, $row.url, $row.pid)
    }
    Write-Info "Stop: .\Run-ListedApps.ps1 -Stop"
}
