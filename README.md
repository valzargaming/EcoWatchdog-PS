# Eco Server Watchdog

[![Pester — Approved Verbs](https://github.com/valzargaming/EcoWatchdog-PS/actions/workflows/pester-approved-verbs.yml/badge.svg)](https://github.com/valzargaming/EcoWatchdog-PS/actions/workflows/pester-approved-verbs.yml)

A PowerShell-based watchdog and helper toolkit for managing an Eco game server.

This repository contains scripts and tests for monitoring, gracefully shutting down,
and restarting an Eco server using RCON (Source/plain), log rotation, backups,
and a state machine implemented in EcoWatchdog.ps1.

**Prerequisites**
- Windows PowerShell (5.1+) or PowerShell Core
- Optional: Pester (for running unit tests)

**Quick start**
- Place this repository inside your Eco server folder (the directory that contains `EcoServer.exe`). Ensure `EcoWatchdog.ps1` and `EcoWatchdog.bat` are located in the same directory as `EcoServer.exe` so the watchdog can control the server process and access game files.
- Run the watchdog on Windows using the provided batch wrapper:

```powershell
.\EcoWatchdog.bat
```

Or run the main script directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\EcoWatchdog.ps1
```

**Tests**
- To run Pester tests (if installed):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_tests.ps1
```

**Configuration & Secrets**
- Config files live in the `Configs/` directory. By default the code reads server config from these files.
- Do NOT commit secrets (RCON passwords) into the repository.

**Important scripts**
- `EcoWatchdog.ps1` — main watchdog implementation (state machine, RCON clients, backups, rotation)
- `EcoWatchdog.bat` — Windows wrapper to start the watchdog script
- `scripts/*` — utility scripts (maintenance scheduling, RCON diagnostics, graceful stop/restart helpers)
- `tests/*` — Pester unit and integration tests

**Repository hygiene**
- The `.gitignore` is configured to avoid tracking server binaries, game data, and backups. Only track scripts, tests, and project files.

**Contributing & Support**
- Open an issue or pull request with changes. Keep secrets out of commits.

**License**
- This project is available under the MIT License — see `LICENSE`.
