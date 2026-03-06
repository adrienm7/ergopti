#!/usr/bin/env bash
# Triggered by launchd whenever the private AHK file is saved.
# Must be called with the project root as working directory.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Log file for debugging (tail -f ~/Library/Logs/ergopti-ahk-watcher.log)
LOG="$HOME/Library/Logs/ergopti-ahk-watcher.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] AHK file changed — running update pipeline…" >> "$LOG"

if npm run update >> "$LOG" 2>&1; then
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Done." >> "$LOG"
else
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Pipeline failed." >> "$LOG"
fi
