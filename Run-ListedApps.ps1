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
    [switch]$Stop,
    [switch]$ApiOnly,
    [switch]$WebUiOnly,
    [switch]$DashboardOnly,
    [int]$DashboardPort = 5050
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

$ApiPortMin = 8171
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
                listen  = $true
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
        if ($line -match '^\s+listen:\s*(.+)$') {
            $val = $Matches[1].Trim().ToLowerInvariant()
            $current.listen = $val -notin @("false", "no", "0")
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

function Test-PortBindable {
    param([int]$Port)
    if ($UsedPorts.Contains($Port)) {
        return $false
    }
    if (Test-PortInUse -Port $Port) {
        return $false
    }
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

function Find-FreePort {
    param(
        [int]$Min,
        [int]$Max
    )
    for ($p = $Min; $p -le $Max; $p++) {
        if (Test-PortBindable -Port $p) {
            [void]$UsedPorts.Add($p)
            return $p
        }
    }
    throw "No bindable port in range $Min-$Max (listening or OS-excluded)"
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

function Resolve-ApiWorkingDir {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) {
        return $Dir
    }
    if (Test-Path -LiteralPath (Join-Path $Dir "manage.py")) {
        return $Dir
    }
    $backend = Join-Path $Dir "backend"
    if (Test-Path -LiteralPath (Join-Path $backend "manage.py")) {
        return $backend
    }
    return $Dir
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
    $pkgPath = Join-Path $Dir "package.json"
    if (Test-Path -LiteralPath $pkgPath) {
        return "node"
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
    $bind = "127.0.0.1:$Port"
    $envMap = @{
        PORT              = "$Port"
        API_PORT          = "$Port"
        CORS_ORIGIN       = $origin
        ALLOWED_ORIGINS   = $origin
        JANUS_API_BIND    = $bind
        NETVAN_API_BIND   = $bind
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
            $runArgs = @("run")
            $leaf = Split-Path $Dir -Leaf
            if ($leaf -like "*roust*") {
                $runArgs = @("run", "--bin", "roust-api", "--", "--bind", "127.0.0.1:$Port")
            }
            Write-Info "  hot reload: off (cargo run); cargo-watch is blocked on this machine"
            return Start-LoggedProcess -FilePath $cargo -ArgumentList $runArgs -WorkingDirectory $Dir -LogPath $log -Environment $envMap
        }
        "node" {
            if (-not (Install-NodePackages -Dir $Dir)) {
                return $null
            }
            $pm = Get-PackageManager -Dir $Dir
            if (-not $pm) {
                Write-ErrLine "npm/pnpm/yarn not found; skip API for $Name"
                return $null
            }
            Write-Info "  hot reload: $($pm.Name) run dev"
            return Start-LoggedProcess -FilePath $pm.Exe -ArgumentList @("run", "dev") -WorkingDirectory $Dir -LogPath $log -Environment $envMap
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

function Stop-DashboardOnPort {
    param([int]$Port)
    try {
        $conns = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        foreach ($c in $conns) {
            if ($c.OwningProcess -and $c.OwningProcess -gt 4) {
                Stop-Process -Id ([int]$c.OwningProcess) -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
    # Kill leftover dashboard powershell by command line if still holding HTTP.sys reservation
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*Start-LinksDashboard.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Start-LinksDashboard {
    param([int]$Port = 5050)
    Stop-DashboardOnPort -Port $Port
    if (-not (Test-PortBindable -Port $Port)) {
        Write-WarnLine "Dashboard port $Port is not bindable."
        return $null
    }
    $dashScript = Join-Path $ScriptDir "Start-LinksDashboard.ps1"
    if (-not (Test-Path -LiteralPath $dashScript)) {
        Write-ErrLine "Missing $dashScript"
        return $null
    }
    $log = Join-Path $LogDir "links-dashboard.log"
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir | Out-Null
    }
    $errPath = "$log.err"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $dashScript,
        "-StatePath", $StatePath,
        "-Port", "$Port"
    )
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $args -WorkingDirectory $ScriptDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $errPath
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-PortInUse -Port $Port) {
            Write-Info "Links page: http://127.0.0.1:$Port/  PID $($proc.Id)"
            return $proc
        }
    }
    Write-WarnLine "Dashboard did not listen on $Port. See logs/links-dashboard.log"
    return $proc
}

function Stop-LastRun {
    Stop-DashboardOnPort -Port $DashboardPort
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

if ($DashboardOnly) {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir | Out-Null
    }
    $dash = Start-LinksDashboard -Port $DashboardPort
    if ($dash) {
        $stateObj = $null
        if (Test-Path -LiteralPath $StatePath) {
            try { $stateObj = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { }
        }
        $procs = New-Object System.Collections.Generic.List[object]
        if ($stateObj -and $stateObj.processes) {
            foreach ($p in @($stateObj.processes)) {
                if ($p.role -ne "dashboard") { [void]$procs.Add($p) }
            }
        }
        [void]$procs.Add([pscustomobject]@{
            name = "links"
            role = "dashboard"
            pid  = $dash.Id
            port = $DashboardPort
            url  = "http://127.0.0.1:$DashboardPort/"
            wait = $true
        })
        $out = [pscustomobject]@{
            startedAt = if ($stateObj -and $stateObj.startedAt) { $stateObj.startedAt } else { (Get-Date).ToString("s") }
            processes = $procs
        }
        $out | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }
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
    $shouldListen = $true
    if ($null -ne $app.listen) {
        $shouldListen = [bool]$app.listen
    }

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

    if ($apiDir) {
        $apiDir = Resolve-ApiWorkingDir -Dir $apiDir
    }

    $apiStack = Get-ApiStack -Dir $apiDir
    $uiStack = Get-WebUiStack -Dir $uiDir
    $apiPort = $null
    $uiPort = $null
    $apiProc = $null
    $uiProc = $null

    if ($WebUiOnly) {
        $apiStack = $null
        $apiPort = $null
    }

    if ($apiDir -and $apiStack -and -not $WebUiOnly) {
        $apiPort = Find-FreePort -Min $ApiPortMin -Max $ApiPortMax
    }
    if ($uiDir -and $uiStack -and -not $ApiOnly) {
        $uiPort = Find-FreePort -Min $UiPortMin -Max $UiPortMax
    }
    if (-not $uiPort) { $uiPort = 5173 }

    if ($apiDir -and $apiStack -and -not $WebUiOnly) {
        Write-Info "API stack: $apiStack  port: $apiPort"
        $apiProc = Start-ApiProcess -Name $app.name -Dir $apiDir -Stack $apiStack -Port $apiPort -UiPort $uiPort
        if ($apiProc) {
            Write-Info "API started PID $($apiProc.Id) (waiting for listen at end)"
            [void]$started.Add([pscustomobject]@{
                name = $app.name
                role = "api"
                pid  = $apiProc.Id
                port = $apiPort
                url  = "http://127.0.0.1:$apiPort"
                wait = $shouldListen
            })
        }
    } elseif ($apiDir -and -not $WebUiOnly) {
        Write-WarnLine "Could not detect API stack in $apiDir"
    }

    if ($uiDir -and $uiStack -and -not $ApiOnly) {
        $bindApi = 8000
        if ($apiPort) { $bindApi = $apiPort }
        Write-Info "WebUI stack: $uiStack  port: $uiPort"
        $uiProc = Start-WebUiProcess -Name $app.name -Dir $uiDir -Port $uiPort -ApiPort $bindApi
        if ($uiProc) {
            Write-Info "WebUI started PID $($uiProc.Id) (waiting for listen at end)"
            [void]$started.Add([pscustomobject]@{
                name = $app.name
                role = "webui"
                pid  = $uiProc.Id
                port = $uiPort
                url  = "http://127.0.0.1:$uiPort"
                wait = $true
            })
        }
    } elseif ($uiDir -and -not $ApiOnly) {
        Write-WarnLine "Could not detect WebUI stack in $uiDir"
    }
}

Write-Host ""
Write-Info "Waiting up to 90s for HTTP ports..."
$deadline = (Get-Date).AddSeconds(90)
do {
    $pending = @($started | Where-Object { $_.wait -and -not (Test-PortInUse -Port ([int]$_.port)) })
    if ($pending.Count -eq 0) {
        break
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)

$merged = @{}
if (($ApiOnly -or $WebUiOnly) -and (Test-Path -LiteralPath $StatePath)) {
    try {
        $prev = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        foreach ($p in @($prev.processes)) {
            if (-not $p.name -or -not $p.role) { continue }
            if ($p.role -eq "dashboard") { continue }
            $merged["{0}|{1}" -f $p.name, $p.role] = $p
        }
    } catch {
        # ignore corrupt state
    }
}
foreach ($row in $started) {
    $merged["{0}|{1}" -f $row.name, $row.role] = $row
}
$allProcs = New-Object System.Collections.Generic.List[object]
foreach ($key in ($merged.Keys | Sort-Object)) {
    [void]$allProcs.Add($merged[$key])
}

$state = [pscustomobject]@{
    startedAt  = (Get-Date).ToString("s")
    processes  = $allProcs
}
$state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8

Write-Host ""
Write-Info "Summary"
if ($started.Count -eq 0) {
    Write-WarnLine "No processes started."
} else {
    foreach ($row in $started) {
        $status = "started"
        if ($row.wait) {
            if (Test-PortInUse -Port ([int]$row.port)) {
                $status = "listening"
            } else {
                $status = "not-listening"
            }
        } else {
            $status = "no-http-wait"
        }
        Write-Info ("  {0,-22} {1,-6} {2,-28} PID {3,-6} {4}" -f $row.name, $row.role, $row.url, $row.pid, $status)
    }
}

$dash = Start-LinksDashboard -Port $DashboardPort
if ($dash) {
    [void]$allProcs.Add([pscustomobject]@{
        name = "links"
        role = "dashboard"
        pid  = $dash.Id
        port = $DashboardPort
        url  = "http://127.0.0.1:$DashboardPort/"
        wait = $true
    })
    $state = [pscustomobject]@{
        startedAt  = (Get-Date).ToString("s")
        processes  = $allProcs
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}
Write-Info "Stop: .\Run-ListedApps.ps1 -Stop"
