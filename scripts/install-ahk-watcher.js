import { existsSync, readFileSync } from 'fs';
import { execFileSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

// Install the AHK file watcher as a persistent background process via pm2.
// Works on macOS, Windows, and Linux — runs under the current user account,
// so no permission/TCC issues.
//
// After running this script, also run once in a terminal:
//   npx pm2 startup
// and execute the command it prints — this makes the watcher survive reboots.

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const PM2 = path.join(PROJECT_DIR, 'node_modules', '.bin', 'pm2');
const WATCHER = path.join(PROJECT_DIR, 'scripts', 'watch-ahk.js');
const APP_NAME = 'ergopti-ahk-watcher';

const overrideFile = path.join(PROJECT_DIR, 'static', 'drivers', 'hotstrings', '.local_ahk_path');

if (!existsSync(overrideFile)) {
	console.error('❌ No .local_ahk_path found.');
	process.exit(1);
}

const privatePath = readFileSync(overrideFile, 'utf8').trim();

if (!privatePath || !existsSync(privatePath)) {
	console.error(`❌ Private AHK file not found: ${privatePath}`);
	process.exit(1);
}

// Stop existing instance if running, then start fresh.
try {
	execFileSync(PM2, ['delete', APP_NAME], { stdio: 'ignore' });
} catch {}

execFileSync(
	PM2,
	[
		'start',
		WATCHER,
		'--name',
		APP_NAME,
		'--interpreter',
		process.execPath,
		'--cwd',
		PROJECT_DIR,
		'--output',
		path.join(PROJECT_DIR, 'logs', 'ahk-watcher.log'),
		'--error',
		path.join(PROJECT_DIR, 'logs', 'ahk-watcher.log'),
		'--time'
	],
	{ cwd: PROJECT_DIR, stdio: 'inherit' }
);

// Save the pm2 process list so it survives reboots (requires pm2 startup to
// have been configured once).
execFileSync(PM2, ['save'], { cwd: PROJECT_DIR, stdio: 'inherit' });

console.log(`
✅ Watcher started as pm2 process "${APP_NAME}"`);
console.log(`   Watching: ${privatePath}`);
console.log(`   Logs: logs/ahk-watcher.log`);
console.log(`
   To survive reboots, run once in your terminal:`);
console.log(`     npx pm2 startup`);
console.log(`   Then execute the command it prints.`);
