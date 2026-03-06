import fs from 'fs';
import path from 'path';

// Sync the private AHK file to the public repo location.
// Reads the path from "static/drivers/hotstrings/.local_ahk_path" (gitignored).
// If the file does not exist, this script is a no-op.
// The subsequent clean-ahk step will strip the personal section before commit.

const overrideFile = path.join('static', 'drivers', 'hotstrings', '.local_ahk_path');

if (!fs.existsSync(overrideFile)) {
	console.log('ℹ️  No .local_ahk_path found — skipping private AHK sync.');
	process.exit(0);
}

const privatePath = fs.readFileSync(overrideFile, 'utf8').trim();

if (!privatePath) {
	console.error('❌ .local_ahk_path is empty.');
	process.exit(1);
}

if (!fs.existsSync(privatePath)) {
	console.error(`❌ Private AHK file not found: ${privatePath}`);
	process.exit(1);
}

const publicPath = path.join('static', 'drivers', 'autohotkey', 'ErgoptiPlus.ahk');

fs.copyFileSync(privatePath, publicPath);
console.log(`✅ Synced private AHK → ${publicPath}`);
