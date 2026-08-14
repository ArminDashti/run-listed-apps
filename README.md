# run-listed-apps

Start only the local API + WebUI pairs you list in `apps.yaml`, with hot reload on safe free ports.

This repo does **not** scan `C:/Users/armin/GitHub`. If an app is not in `apps.yaml` with `enabled: true`, it is not started.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## About

Local development often means many `*-api` / `*-webui` clones on disk. This runner starts **only** the pairs you previously listed, using the same rules as a typical local hot-reload session: install project packages when needed, pick a free port, start the API first, then the WebUI.

## Requirements

- Windows PowerShell 5.1 or later
- Project runtimes already installed for the stacks you start (Node, Go, Rust, and/or Python)
- Optional: `air` (Go hot reload), `cargo-watch` (Rust hot reload)

The script does not install system runtimes or global CLIs.

## Install

```powershell
git clone https://github.com/ArminDashti/run-listed-apps.git
cd run-listed-apps
```

Clone the API and WebUI repos you care about under the `root` path in `apps.yaml` (default `C:/Users/armin/GitHub`).

## Usage

1. Edit `apps.yaml`.
2. Add an entry per pair (`name`, `api`, `webui`).
3. Set `enabled: true` only for apps you want to start.
4. Run:

```powershell
cd C:\Users\armin\GitHub\run-listed-apps
.\Run-ListedApps.ps1
```

List what would run (no start):

```powershell
.\Run-ListedApps.ps1 -List
```

Stop processes this script last started:

```powershell
.\Run-ListedApps.ps1 -Stop
```

After a successful start, open the links page:

```text
http://127.0.0.1:5050/
```

That page lists every app’s WebUI and API URLs (with up/down status) and refreshes every 5 seconds. Start only the page against an existing state file:

```powershell
.\Run-ListedApps.ps1 -DashboardOnly
```

## apps.yaml

```yaml
root: C:/Users/armin/GitHub

apps:
  - name: helix
    enabled: true
    api: helix-api
    webui: helix-webui
```

| Field | Meaning |
|-------|---------|
| `root` | Parent folder for relative `api` / `webui` paths |
| `name` | Label used in logs and the PID state file |
| `enabled` | `true` to start; `false` or omitted to skip |
| `api` | Folder name or absolute path (optional if WebUI-only) |
| `webui` | Folder name or absolute path (optional if API-only) |

See `apps.example.yaml` for copy-paste entries. Do not put secrets in these files.

## What the runner does

For each enabled app:

1. Resolves folders under `root` (or absolute paths).
2. Detects stack from files (`go.mod`, `Cargo.toml`, Django/`manage.py`, FastAPI, Vite `package.json`).
3. Installs **project** packages when needed (`npm install`, `go mod download`, and similar).
4. Picks a **free** port: API `8000–8999`, WebUI `5173–5299`. Never binds `1–1023`. Never kills other processes to free a port.
5. Starts API, then WebUI, with hot reload when the tool is available (`air`, `cargo-watch`, Django/Vite reload, `uvicorn --reload`).
6. Prints URLs, ports, PIDs, and log paths.
7. Opens a links dashboard at `http://127.0.0.1:5050/` with clickable links to every started app.

Process logs go to `logs/`. Last-run PIDs are stored in `.run-listed-apps-state.json` (both gitignored).

## License

MIT. See [`LICENSE`](LICENSE).
