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

// Helper to strip date line and section 2/ perso (découpage étape-par-étape comme remove_ahk_personal_configuration.js)
function stripForComparison(content) {
	// Remove BOM if present
	content = content.replace(/^\uFEFF/, '');
	// Remove date line if present
	content = content.replace(/^; (Created|Last modified) on .*(\r?\n)/, '');

	// Repère les blocs comme dans remove_ahk_personal_configuration.js
	const section2Re =
		/(?:^; ={5,}\s*\n){2,}; ={3,} 2\/ PERSONAL SHORTCUTS ={3,}\s*\n(?:^; ={5,}\s*\n){2,}/m;
	const section3Re =
		/(?:^; ={5,}\s*\n){2,}; ={3,} 3\/ LAYOUT MODIFICATION ={3,}\s*\n(?:^; ={5,}\s*\n){2,}/m;

	const start2Match = content.match(section2Re);
	const start3Match = content.match(section3Re);
	if (!start2Match || !start3Match) {
		return content.trim();
	}
	const start2Index = start2Match.index;
	const start2Block = start2Match[0];
	const after2Slice = content.slice(start2Index + start2Block.length);

	// Capture tout jusqu'à et incluant #InputLevel et lignes vides après
	const after2Match = after2Slice.match(/^([\s\S]*?\n#InputLevel[^\n]*\n(?:\s*\n)*)/m);
	const extra2 = after2Match ? after2Match[0] : '';

	const start3Index = content.match(section3Re).index;
	const endBlock = start3Match[0];

	const before = content.slice(0, start2Index);
	const after = content.slice(start3Index + endBlock.length);

	// On retire tout ce qu'il y a entre les deux blocs (hors commentaires/#InputLevel)
	return (before + start2Block + extra2 + endBlock + after).trim();
}

const privateContent = fs.readFileSync(privatePath, 'utf8');
let privateForCompare = stripForComparison(privateContent);

let publicForCompare = '';
if (fs.existsSync(publicPath)) {
	const publicContent = fs.readFileSync(publicPath, 'utf8');
	publicForCompare = stripForComparison(publicContent);
}

if (privateForCompare === publicForCompare) {
	console.log('ℹ️  No changes outside personal section — skipping sync and date update.');
	process.exit(0);
}

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
const lines = privateContent.split('\n');
const firstLine = lines[0] ? lines[0].replace(/^\uFEFF/, '') : '';
const hasDateLine = !!firstLine.match(/^; (Created|Last modified) on /);
const rest = hasDateLine ? lines.slice(1).join('\n') : privateContent;
const updated = dateLine + '\n' + rest;

fs.writeFileSync(publicPath, updated, 'utf8');
console.log(`✅ Synced private AHK → ${publicPath} (date line added)`);
