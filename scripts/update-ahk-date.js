import { readFileSync, writeFileSync, existsSync } from 'fs';
import { execSync } from 'child_process';

const AHK_FILE = 'static/drivers/autohotkey/ErgoptiPlus.ahk';

if (!existsSync(AHK_FILE)) process.exit(0);

// Only update the date if the AHK file is staged AND its real content
// (everything after the date line) has actually changed vs HEAD.
// This prevents spurious diffs when committing other files.

// Check whether the file is staged at all.
const stagedFiles = execSync('git diff --cached --name-only', { encoding: 'utf8' });
if (!stagedFiles.split('\n').includes(AHK_FILE)) {
	console.log('⏭️  AHK date not updated: ErgoptiPlus.ahk not staged.');
	process.exit(0);
}

// Strip the date line (line 1) and compare the rest with HEAD.
const stripDateLine = (text) => {
	const lines = text.split('\n');
	return (lines[0].match(/^; (Created|Last modified) on /) ? lines.slice(1) : lines).join('\n');
};

const currentContent = readFileSync(AHK_FILE, 'utf8');

let headContent = '';
try {
	headContent = execSync(`git show HEAD:${AHK_FILE}`, { encoding: 'utf8' });
} catch {
	// File not in HEAD yet (new file) — always update.
	headContent = '';
}

// Normalize possible BOM and detect whether a date line is already present on first line.
const lines = currentContent.split('\n');
const firstLine = lines[0] ? lines[0].replace(/^\uFEFF/, '') : '';
const hasDateLine = !!firstLine.match(/^; (Created|Last modified) on /);

// Only skip updating when the file exists in HEAD, contents are identical after
// stripping a date line, AND a date line is already present. If there's no date
// line, we must add one even when the rest of the file matches HEAD.
if (
	headContent !== '' &&
	stripDateLine(currentContent) === stripDateLine(headContent) &&
	hasDateLine
) {
	console.log('⏭️  AHK date not updated: no real content change beyond the date line.');
	process.exit(0);
}

const now = new Date();
const pad = (n) => String(n).padStart(2, '0');
const offsetMin = -now.getTimezoneOffset();
const sign = offsetMin >= 0 ? '+' : '-';
const offsetH = Math.floor(Math.abs(offsetMin) / 60);
const datePart = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
const timePart = `${pad(now.getHours())}:${pad(now.getMinutes())}`;
const newLine = `; Last modified on ${datePart} at ${timePart} (UTC${sign}${offsetH})`;

// Replace the existing date line, or prepend a new one.
const rest = hasDateLine ? lines.slice(1).join('\n') : currentContent;
const updated = newLine + '\n' + rest;
writeFileSync(AHK_FILE, updated, 'utf8');
console.log(`✅ Updated AHK date: ${newLine}`);
