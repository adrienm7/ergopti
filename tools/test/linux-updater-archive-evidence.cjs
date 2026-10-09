// tools/test/linux-updater-archive-evidence.cjs

/** Counts only exact owning archive/source-control receipts; raw transcripts stay private. */
'use strict';
const fs = require('node:fs');
function refuse() {
	throw new Error('Archive evidence refused');
}
function readArchiveCount(text) {
	if (
		text !==
		'[OK] Linux updater archive pipeline: 3 actual native cases; 15 checks; 0 skipped; closure complete.\n'
	)
		refuse();
	return 15;
}
const FOLLOWUP =
	'[OK] Linux archive snapshot: 5 controls passed; 0 skipped; actual private Git snapshots only.\n' +
	'[OK] Linux CONNECT terminal protocol: 9 controls passed; 0 skipped; modeled socket/select only.\n';
function readSourceCounts(text) {
	// Preserve the exact old twelve-control receipt, and admit only the explicit
	// whole extension. Separate mandatory readers below require the extension.
	if (typeof text === 'string' && text.endsWith(FOLLOWUP)) text = text.slice(0, -FOLLOWUP.length);
	if (
		text !==
		'[OK] Linux archive source crypto: 8 controls passed; 0 skipped; controlled metadata only.\n' +
			'[OK] Linux archive source bin parents: 4 controls passed; 0 skipped; filesystem guards only.\n'
	)
		refuse();
	return { crypto: 8, parents: 4 };
}
function readFollowupCounts(text) {
	const original =
		'[OK] Linux archive source crypto: 8 controls passed; 0 skipped; controlled metadata only.\n' +
		'[OK] Linux archive source bin parents: 4 controls passed; 0 skipped; filesystem guards only.\n';
	if (text !== original + FOLLOWUP) refuse();
	return { snapshot: 5, connect: 9 };
}
function readRegular(filename) {
	const before = fs.lstatSync(filename, { bigint: true });
	if (!before.isFile() || before.isSymbolicLink() || before.size > 4096n) refuse();
	const bytes = fs.readFileSync(filename);
	const after = fs.lstatSync(filename, { bigint: true });
	if (
		!after.isFile() ||
		after.dev !== before.dev ||
		after.ino !== before.ino ||
		after.size !== before.size ||
		after.mode !== before.mode ||
		after.uid !== before.uid ||
		after.nlink !== before.nlink ||
		BigInt(bytes.length) !== before.size
	)
		refuse();
	return bytes.toString('utf8');
}
if (require.main === module) {
	try {
		const [kind, filename, ...extra] = process.argv.slice(2);
		if (extra.length || typeof filename !== 'string') refuse();
		const text = readRegular(filename);
		const value =
			kind === 'archive'
				? readArchiveCount(text)
				: ['crypto', 'parents'].includes(kind)
					? readSourceCounts(text)[kind]
					: ['snapshot', 'connect'].includes(kind)
						? readFollowupCounts(text)[kind]
						: refuse();
		process.stdout.write(String(value) + '\n');
	} catch {
		console.error('[FAIL] Archive evidence refused.');
		process.exitCode = 1;
	}
}
module.exports = { readArchiveCount, readSourceCounts, readFollowupCounts };
