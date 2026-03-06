import { execFileSync, execSync } from 'child_process';
import { existsSync, readFileSync, watchFile } from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

// Watch the private AHK file and run the full update pipeline on every save.
// Self-contained: does not rely on npm or PATH — safe to run from pm2 or any
// process manager on macOS, Windows, and Linux.

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const NODE = process.execPath;

const overrideFile = path.join(PROJECT_DIR, 'static', 'drivers', 'hotstrings', '.local_ahk_path');

if (!existsSync(overrideFile)) {
	console.error('❌ No .local_ahk_path found — nothing to watch.');
	process.exit(1);
}

const privatePath = readFileSync(overrideFile, 'utf8').trim();

if (!privatePath || !existsSync(privatePath)) {
	console.error(`❌ Private AHK file not found: ${privatePath}`);
	process.exit(1);
}

// Locate uv: try PATH first, then common install locations.
function findUv() {
	try {
		const cmd = os.platform() === 'win32' ? 'where uv' : 'which uv';
		return execSync(cmd, { encoding: 'utf8' }).trim().split('\n')[0].trim();
	} catch {
		const candidates = [
			path.join(os.homedir(), '.local', 'bin', 'uv'), // Linux
			path.join(os.homedir(), 'Library', 'Python', '3.13', 'bin', 'uv'), // macOS pip-installed
			path.join(os.homedir(), 'Library', 'Python', '3.12', 'bin', 'uv'),
			path.join(os.homedir(), '.cargo', 'bin', 'uv'), // cargo install
			'C:\\Users\\' + os.userInfo().username + '\\AppData\\Local\\Programs\\uv\\uv.exe' // Windows
		];
		return candidates.find(existsSync) ?? null;
	}
}

const uvPath = findUv();
if (!uvPath) {
	console.error('❌ uv not found. Install it or ensure it is in PATH.');
	process.exit(1);
}

const scripts = [
	path.join(PROJECT_DIR, 'scripts', 'sync-private-ahk.js'),
	path.join(PROJECT_DIR, 'remove_ahk_personal_configuration.js'),
	path.join(PROJECT_DIR, 'scripts', 'update-ahk-date.js')
];

function runPipeline() {
	// Run Node scripts directly — no npm needed.
	for (const script of scripts) {
		execFileSync(NODE, [script], { cwd: PROJECT_DIR, stdio: 'inherit' });
	}
	// Generate TOML hotstrings via uv.
	execFileSync(uvPath, ['run', 'python', 'static/drivers/hotstrings/0_generate_hotstrings.py'], {
		cwd: PROJECT_DIR,
		stdio: 'inherit'
	});
}

console.log(`👁  Watching: ${privatePath}`);
console.log('    Pipeline will run on every save.\n');

// Debounce to avoid double-triggers on rapid saves.
let debounceTimer = null;

watchFile(privatePath, { interval: 500 }, (curr, prev) => {
	if (curr.mtimeMs === prev.mtimeMs) return;

	clearTimeout(debounceTimer);
	debounceTimer = setTimeout(() => {
		console.log(`\n🔄 Change detected — running update pipeline…`);
		try {
			runPipeline();
			console.log('✅ Done.\n');
		} catch {
			console.error('❌ Pipeline failed (see output above).\n');
		}
	}, 300);
});
