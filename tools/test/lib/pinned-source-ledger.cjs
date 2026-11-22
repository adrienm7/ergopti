// tools/test/lib/pinned-source-ledger.cjs

/**
 * ==============================================================================
 * MODULE: Pinned Source-Read Ledger
 * DESCRIPTION:
 * Checks and shrinks tools/test/pinned-source-reads-ledger.json, the single
 * source of the test files and path literals that the three pinned source-read
 * ratchets (AHK, macOS Lua, Linux Lua) still admit. Their count baselines
 * drifted from the tree several times — frozen 91 above the measurement once,
 * two below it another time — and a count let a fix pay for a new pin; the
 * ledger names every pin instead.
 *
 * FEATURES & RATIONALE:
 * 1. Two sections per driver: "<driver>.files", the location-pinned test files,
 *    and "<driver>.reads", the pinned path literals ("<test file> <literal>",
 *    ranked " #2" when a file repeats one). Each section carries the reason
 *    its entries were admitted.
 * 2. A pin missing from the ledger fails, and so does a ledger entry the scan
 *    no longer finds (known-debt.cjs), so the lists can only shrink.
 * 3. --shrink-ledger drops the fixed entries and refuses to run while a new
 *    pin is found: the tool never adds an entry.
 * ==============================================================================
 */

'use strict';

const path = require('path');
const { readJsonLedger, reportKnownDebt, shrinkJsonLedger } = require('./known-debt.cjs');

const LEDGER_FILE = path.join(__dirname, '..', 'pinned-source-reads-ledger.json');
const LEDGER_NAME = path.basename(LEDGER_FILE);

/**
 * Compares a scan with one driver's two sections, or shrinks them when the
 * command line asks for --shrink-ledger, and exits on any difference.
 * @param {object} spec
 * @param {string} spec.driver - windows, macos or linux.
 * @param {string[]} spec.files - Location-pinned test files found.
 * @param {string[]} spec.reads - Pinned path literals found.
 * @param {string} spec.fileAdvice - How to fix a new pinned file.
 * @param {string} spec.readAdvice - How to fix a new pinned literal.
 * @param {string} spec.script - The ratchet's path, for the shrink hint.
 * @returns {void} Returns only when the scan equals the ledger.
 */
function enforcePinnedLedger({ driver, files, reads, fileAdvice, readAdvice, script }) {
	const sections = { [`${driver}.files`]: files, [`${driver}.reads`]: reads };
	if (process.argv.includes('--shrink-ledger'))
		process.exit(shrinkJsonLedger(LEDGER_FILE, sections) ? 0 : 1);
	const filesMatch = reportKnownDebt({
		label: `Location-pinned ${driver} test file`,
		found: files,
		ledger: readJsonLedger(LEDGER_FILE, `${driver}.files`),
		ledgerName: `${LEDGER_NAME} ${driver}.files`,
		advice: fileAdvice
	});
	const readsMatch = reportKnownDebt({
		label: `Pinned ${driver} source path`,
		found: reads,
		ledger: readJsonLedger(LEDGER_FILE, `${driver}.reads`),
		ledgerName: `${LEDGER_NAME} ${driver}.reads`,
		advice: readAdvice
	});
	if (filesMatch && readsMatch) return;
	console.error(`  Run \`node ${script} --shrink-ledger\` to drop fixed entries.`);
	process.exit(1);
}

module.exports = { enforcePinnedLedger };
