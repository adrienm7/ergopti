// tools/deploy/fix-ahk-encoding.cjs
// Adds the missing UTF-8 BOM and normalizes line endings to LF on all .ahk files.
// Run from the pre-commit hook; the same invariant is asserted by
// tools/test/test-ahk-encoding.cjs.

'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const BOM = Buffer.from([0xef, 0xbb, 0xbf]);
const PROJECT_ROOT = path.resolve(__dirname, '..', '..');

// Collect all .ahk files recursively
function collectAhkFiles(dir, results = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			collectAhkFiles(full, results);
		} else if (entry.isFile() && entry.name.endsWith('.ahk')) {
			results.push(full);
		}
	}
	return results;
}

let fixedBom = 0;
let fixedLf = 0;
let alreadyOk = 0;

const files = collectAhkFiles(PROJECT_ROOT);

for (const filePath of files) {
	let data = fs.readFileSync(filePath);
	let changed = false;

	// 1. Add BOM if missing
	const hasBom = data[0] === 0xef && data[1] === 0xbb && data[2] === 0xbf;
	if (!hasBom) {
		data = Buffer.concat([BOM, data]);
		changed = true;
		fixedBom++;
	}

	// 2. Normalize line endings to LF — this is what tools/test/test-ahk-encoding.cjs
	// enforces, so any CR byte is collapsed away. Work on the content after the BOM.
	const contentStart = hasBom ? 3 : 0; // after we already prepended BOM above, offset is 3
	// Since we may have prepended BOM, re-derive: BOM is always first 3 bytes now
	const content = data.slice(3).toString('binary');
	const normalized = content.replace(/\r\n?/g, '\n');
	if (normalized !== content) {
		data = Buffer.concat([data.slice(0, 3), Buffer.from(normalized, 'binary')]);
		changed = true;
		fixedLf++;
	}

	if (changed) {
		fs.writeFileSync(filePath, data);
		const rel = path.relative(PROJECT_ROOT, filePath).replace(/\\/g, '/');
		const tags = [];
		if (!hasBom) tags.push('BOM added');
		if (normalized !== content) tags.push('LF normalized');
		console.log(`  FIXED [${tags.join(', ')}]: ${rel}`);
	} else {
		alreadyOk++;
	}
}

console.log('');
console.log(
	`Done. ${fixedBom} file(s) got BOM, ${fixedLf} file(s) got LF normalization, ${alreadyOk} already OK.`
);
