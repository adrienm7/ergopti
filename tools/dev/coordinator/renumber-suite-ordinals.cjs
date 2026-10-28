// tools/dev/coordinator/renumber-suite-ordinals.cjs

/**
 * ==============================================================================
 * MODULE: Suite ordinal renumbering
 * DESCRIPTION:
 * Renumbers every check of tools/test/features/<feature>/suite.json from 1,
 * contiguously, after an integration batch brought two checks onto the same
 * ordinal (test-js-feature-inventory.cjs refuses collisions and gaps). Within a
 * file the file order is kept, since the inventory requires increasing ordinals
 * per file; across files the current ordinal decides, ties by file name. Only
 * the ordinal digits change.
 *
 * USAGE:
 *   node tools/dev/coordinator/renumber-suite-ordinals.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../../..');
const FEATURES = path.join(ROOT, 'tools/test/features');

const files = fs
	.readdirSync(FEATURES)
	.map((name) => path.join(FEATURES, name, 'suite.json'))
	.filter((file) => fs.existsSync(file))
	.sort();

const entries = [];
for (const file of files) {
	let key = 0;
	JSON.parse(fs.readFileSync(file, 'utf8')).checks.forEach((check, index) => {
		// A later check of the file never sorts before an earlier one.
		key = Math.max(key, check.ordinal);
		entries.push({ key, file, index, id: check.id, ordinal: check.ordinal });
	});
}
entries.sort((a, b) => a.key - b.key || a.file.localeCompare(b.file) || a.index - b.index);

const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
let changed = 0;
entries.forEach((entry, position) => {
	const ordinal = position + 1;
	if (entry.ordinal === ordinal) return;
	const text = fs.readFileSync(entry.file, 'utf8');
	const pattern = new RegExp(`("id": "${escape(entry.id)}",\\s*\\n\\s*"ordinal": )\\d+`, 'g');
	let hits = 0;
	const next = text.replace(pattern, (_, head) => {
		hits++;
		return head + ordinal;
	});
	if (hits !== 1) throw new Error(`${entry.file}: check ${entry.id} matched ${hits} times`);
	fs.writeFileSync(entry.file, next);
	changed++;
});
console.log(`[OK] renumbered ${changed} suite check(s).`);
