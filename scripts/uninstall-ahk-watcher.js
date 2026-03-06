import { existsSync, rmSync } from 'fs';
import { execSync } from 'child_process';
import os from 'os';
import path from 'path';

const AGENT_LABEL = 'fr.ergopti.ahk-watcher';
const PLIST_PATH = path.join(os.homedir(), 'Library', 'LaunchAgents', `${AGENT_LABEL}.plist`);

if (!existsSync(PLIST_PATH)) {
	console.log('ℹ️  No launchd agent found — nothing to uninstall.');
	process.exit(0);
}

try {
	execSync(`launchctl unload "${PLIST_PATH}"`);
} catch {}

rmSync(PLIST_PATH);
console.log(`✅ Launchd agent unloaded and removed.`);
