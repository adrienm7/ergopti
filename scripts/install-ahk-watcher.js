import { existsSync, readFileSync, writeFileSync } from 'fs';
import { execSync } from 'child_process';
import os from 'os';
import path from 'path';

// Install a launchd agent that watches the private AHK file and runs the
// update pipeline automatically on every save — no terminal needed.

const AGENT_LABEL = 'fr.ergopti.ahk-watcher';
const PLIST_PATH = path.join(os.homedir(), 'Library', 'LaunchAgents', `${AGENT_LABEL}.plist`);

const overrideFile = path.join('static', 'drivers', 'hotstrings', '.local_ahk_path');

if (!existsSync(overrideFile)) {
	console.error('❌ No .local_ahk_path found.');
	process.exit(1);
}

const privatePath = readFileSync(overrideFile, 'utf8').trim();

if (!privatePath || !existsSync(privatePath)) {
	console.error(`❌ Private AHK file not found: ${privatePath}`);
	process.exit(1);
}

const projectDir = path.resolve('.');
const scriptPath = path.join(projectDir, 'scripts', 'run-ahk-update.sh');

// Make the shell script executable
execSync(`chmod +x "${scriptPath}"`);

const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${AGENT_LABEL}</string>

	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${scriptPath}</string>
	</array>

	<key>WatchPaths</key>
	<array>
		<string>${privatePath}</string>
	</array>

	<key>WorkingDirectory</key>
	<string>${projectDir}</string>

	<key>RunAtLoad</key>
	<false/>

	<key>StandardOutPath</key>
	<string>${os.homedir()}/Library/Logs/ergopti-ahk-watcher.log</string>

	<key>StandardErrorPath</key>
	<string>${os.homedir()}/Library/Logs/ergopti-ahk-watcher.log</string>
</dict>
</plist>
`;

writeFileSync(PLIST_PATH, plist, 'utf8');
console.log(`📝 Plist written: ${PLIST_PATH}`);

// Unload first in case it was already loaded, then reload
try {
	execSync(`launchctl unload "${PLIST_PATH}" 2>/dev/null || true`);
} catch {}
execSync(`launchctl load "${PLIST_PATH}"`);

console.log(`✅ Launchd agent loaded — watching: ${privatePath}`);
console.log(`   Logs: ~/Library/Logs/ergopti-ahk-watcher.log`);
