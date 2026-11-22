// tools/test/lib/known-debt.cjs

/**
 * ==============================================================================
 * MODULE: Known Debt Ledger
 * DESCRIPTION:
 * Compares the offenders a ratchet finds with the named ledger of offenders it
 * admits, each with the reason it is still there. A bare count baseline let a
 * fix and a new offender cancel out unseen and drifted from the tree it
 * described; the ledger names every admitted item, so the gate fails on the
 * new one and on the fixed one alike.
 *
 * FEATURES & RATIONALE:
 * 1. A found offender missing from the ledger fails: the debt may not grow,
 *    and the failure names the item instead of a total.
 * 2. A ledger entry the scan no longer finds fails too: the ledger may only
 *    shrink, so a fix removes its entry in the same change and the ratchet
 *    tightens by itself.
 * 3. Every entry carries a non-empty reason; an entry without one is refused,
 *    so the ledger cannot become a silent allowlist.
 * ==============================================================================
 */

'use strict';

/**
 * Compares found offenders with the ledger that admits them.
 * @param {Iterable<string>} found - Offender identities the scan found.
 * @param {Record<string, string>} ledger - Admitted offender to its reason.
 * @returns {{added: string[], fixed: string[]}} added: found but not admitted;
 *   fixed: admitted but no longer found. Both sorted.
 * @throws {Error} When a ledger entry has no reason.
 */
function compareKnownDebt(found, ledger) {
	for (const [item, reason] of Object.entries(ledger)) {
		if (typeof reason !== 'string' || reason.trim() === '')
			throw new Error(`known-debt: the ledger entry "${item}" has no reason`);
	}
	const foundSet = new Set(found);
	const added = [...foundSet].filter((item) => !Object.hasOwn(ledger, item)).sort();
	const fixed = Object.keys(ledger)
		.filter((item) => !foundSet.has(item))
		.sort();
	return { added, fixed };
}

/**
 * Compares and prints the result of one ledger.
 * @param {object} spec
 * @param {string} spec.label - What the offenders are, for the messages.
 * @param {Iterable<string>} spec.found - Offender identities the scan found.
 * @param {Record<string, string>} spec.ledger - Admitted offender to reason.
 * @param {string} spec.ledgerName - The constant that holds the ledger.
 * @param {string} [spec.advice] - How to fix a new offender.
 * @returns {boolean} True when the found offenders equal the ledger.
 */
function reportKnownDebt({ label, found, ledger, ledgerName, advice = '' }) {
	const { added, fixed } = compareKnownDebt(found, ledger);
	for (const item of added)
		console.error(`\x1b[31m[ERROR] ${label}: new offender ${item} (not in ${ledgerName}).\x1b[0m`);
	if (added.length > 0 && advice) console.error(advice);
	for (const item of fixed)
		console.error(
			`\x1b[31m[ERROR] ${label}: ${item} is fixed; remove its entry from ${ledgerName}.\x1b[0m`
		);
	return added.length === 0 && fixed.length === 0;
}

module.exports = { compareKnownDebt, reportKnownDebt };
