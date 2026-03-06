import { execSync } from 'child_process';
import { existsSync, readFileSync, watchFile } from 'fs';
import path from 'path';

// Watch the private AHK file and run the full update pipeline on every save.
// Reads the target path from "static/drivers/hotstrings/.local_ahk_path".

const overrideFile = path.join('static', 'drivers', 'hotstrings', '.local_ahk_path');

if (!existsSync(overrideFile)) {
	console.error('❌ No .local_ahk_path found — nothing to watch.');
	process.exit(1);
}

const privatePath = readFileSync(overrideFile, 'utf8').trim();

if (!privatePath || !existsSync(privatePath)) {
	console.error(`❌ Private AHK file not found: ${privatePath}`);
	process.exit(1);
}

console.log(`👁  Watching: ${privatePath}`);
console.log('    Press Ctrl+C to stop.\n');

// Debounce to avoid double-triggers on rapid saves
let debounceTimer = null;

watchFile(privatePath, { interval: 500 }, (curr, prev) => {
	if (curr.mtimeMs === prev.mtimeMs) return;

	clearTimeout(debounceTimer);
	debounceTimer = setTimeout(() => {
		console.log(`\n🔄 Change detected — running update pipeline…`);
		try {
			execSync('npm run update', { stdio: 'inherit' });
			console.log('✅ Done.\n');
		} catch {
			console.error('❌ Pipeline failed (see output above).\n');
		}
	}, 300);
});
