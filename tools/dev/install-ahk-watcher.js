import { existsSync, readFileSync } from 'fs';
import { execFileSync } from 'child_process';
import path from 'path';
import os from 'os';
import { fileURLToPath } from 'url';

// Install the AHK file watcher as a persistent background process via pm2.
// Works on macOS, Windows, and Linux — runs under the current user account,
// so no permission/TCC issues.
//
// After running this script, also run once in a terminal:
//   npx pm2 startup
// and execute the command it prints — this makes the watcher survive reboots.

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const PM2 = path.join(
	PROJECT_DIR,
	'node_modules',
	'.bin',
	'pm2' + (os.platform() === 'win32' ? '.cmd' : '')
);
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

// Helper: try local pm2 binary, fallback to `npx pm2` if it fails on Windows.
function runPm2(args, customOptions = {}) {
	const isWindows = os.platform() === 'win32';
	const execOptions = {
		cwd: PROJECT_DIR,
		stdio: 'inherit',
		shell: isWindows,
		...customOptions // Permet de surcharger stdio si besoin
	};

	try {
		execFileSync(PM2, args, execOptions);
		return;
	} catch (e) {
		if (args[0] !== 'ping') {
			console.warn('⚠️  pm2 local binary failed, trying fallbacks (npx.cmd / npx).');
		}
	}

	// Try npx variants (prefer npx.cmd on Windows)
	const npxCandidates = isWindows ? ['npx.cmd', 'npx'] : ['npx'];
	for (const npxCmd of npxCandidates) {
		try {
			execFileSync(npxCmd, ['pm2', ...args], execOptions);
			return;
		} catch {
			// try next candidate
		}
	}

	if (args[0] !== 'ping') {
		throw new Error('pm2 invocation failed (all fallbacks exhausted)');
	}
}

// 1. Force PM2 to start its daemon entirely detached from our terminal
try {
	runPm2(['ping'], { stdio: 'ignore' });
} catch {}

// 2. Stop existing instance if running, then start fresh.
try {
	runPm2(['delete', APP_NAME]);
} catch {}

runPm2([
	'start',
	WATCHER,
	'--name',
	APP_NAME,
	'--interpreter',
	'node',
	'--cwd',
	PROJECT_DIR,
	'--output',
	path.join(PROJECT_DIR, 'logs', 'ahk-watcher.log'),
	'--error',
	path.join(PROJECT_DIR, 'logs', 'ahk-watcher.log'),
	'--time'
]);

// 3. Save the pm2 process list
runPm2(['save']);

console.log(`
✅ Watcher started as pm2 process "${APP_NAME}"`);
console.log(`   Watching: ${privatePath}`);
console.log(`   Logs: logs/ahk-watcher.log`);
console.log(`
   To survive reboots, run once in your terminal:`);
console.log(`     npx pm2 startup`);
console.log(`   Then execute the command it prints.`);
