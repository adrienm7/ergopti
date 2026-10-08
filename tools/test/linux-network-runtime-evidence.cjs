// tools/test/linux-network-runtime-evidence.cjs

/** Reads one exact native runtime receipt without exporting private log text. */
'use strict';
const fs = require('node:fs');
const RECEIPT =
	'[OK] Linux network runtime actual-native: 4 actual native groups passed; 0 skipped.';
function readActualNativeCount(source) {
	if (typeof source !== 'string' || Buffer.byteLength(source, 'utf8') > 65536)
		throw new Error('Native network runtime receipt refused.');
	const lines = source.split('\n');
	const observations = lines.filter((line) => line.includes('Linux network runtime actual-native'));
	if (
		observations.length !== 1 ||
		observations[0] !== RECEIPT ||
		lines.some((line) => line.startsWith('[DEFERRED]'))
	)
		throw new Error('Native network runtime receipt refused.');
	return 4;
}
if (require.main === module) {
	try {
		if (process.argv.length !== 3) throw new Error('Native network runtime receipt refused.');
		const count = readActualNativeCount(fs.readFileSync(process.argv[2], 'utf8'));
		process.stdout.write(`${count}\n`);
	} catch {
		process.stderr.write('Native network runtime receipt refused.\n');
		process.exitCode = 1;
	}
}
module.exports = { readActualNativeCount };
