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

// Read private file content
const privateContent = fs.readFileSync(privatePath, 'utf8');
const lines = privateContent.split('\n');

// Format date line
const now = new Date();
const pad = (n) => String(n).padStart(2, '0');
const offsetMin = -now.getTimezoneOffset();
const sign = offsetMin >= 0 ? '+' : '-';
const offsetH = Math.floor(Math.abs(offsetMin) / 60);
const datePart = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
const timePart = `${pad(now.getHours())}:${pad(now.getMinutes())}`;
const dateLine = `; Last modified on ${datePart} at ${timePart} (UTC${sign}${offsetH})`;

// Replace or insert date line
const firstLine = lines[0] ? lines[0].replace(/^\uFEFF/, '') : '';
const hasDateLine = !!firstLine.match(/^; (Created|Last modified) on /);
const rest = hasDateLine ? lines.slice(1).join('\n') : privateContent;
const updated = dateLine + '\n' + rest;

fs.writeFileSync(publicPath, updated, 'utf8');
console.log(`✅ Synced private AHK → ${publicPath} (date line added)`);
