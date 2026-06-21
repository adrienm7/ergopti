import { execFileSync } from 'child_process';
import { existsSync, readFileSync, watchFile } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

// Watch the private AHK file and run the full update pipeline on every save.
// Self-contained: does not rely on npm or PATH — safe to run from pm2 or any
// process manager on macOS, Windows, and Linux.

// This file lives in tools/dev/, so the repo root is two directories up.
const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const NODE = process.execPath;

const overrideFile = path.join(PROJECT_DIR, 'static', 'ergopti_plus', 'windows', '.local_ahk_path');

if (!existsSync(overrideFile)) {
	console.error('❌ No .local_ahk_path found — nothing to watch.');
	process.exit(1);
}

const privatePath = readFileSync(overrideFile, 'utf8').trim();

if (!privatePath || !existsSync(privatePath)) {
	console.error(`❌ Private AHK file not found: ${privatePath}`);
	process.exit(1);
}

// The pipeline: sync the private file to the public location (with a refreshed
// date line), then strip the personal "2/ PERSONAL SHORTCUTS" section.
// Hotstrings are no longer generated from the AHK — the TOML catalogues under
// _shared/modules/hotstrings/ are the single source of truth.
const scripts = [
	path.join(PROJECT_DIR, 'tools', 'dev', 'sync-private-ahk.js'),
	path.join(PROJECT_DIR, 'tools', 'dev', 'remove_ahk_personal_configuration.js')
];

function runPipeline() {
	// Run Node scripts directly — no npm needed.
	for (const script of scripts) {
		execFileSync(NODE, [script], { cwd: PROJECT_DIR, stdio: 'inherit' });
	}
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
