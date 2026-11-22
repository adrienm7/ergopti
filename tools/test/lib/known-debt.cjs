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
 * 4. A long ledger lives in a JSON file beside its test, one reason per
 *    section; --shrink-ledger style rewrites only ever drop entries.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

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

/**
 * Builds a ledger whose entries share one reason, for a long list frozen in
 * one go whose items have not been triaged one by one.
 * @param {string[]} items - Admitted offender identities.
 * @param {string} reason - Why they were admitted.
 * @returns {Record<string, string>} The ledger.
 * @throws {Error} When an item repeats.
 */
function ledgerFromList(items, reason) {
	const ledger = {};
	for (const item of items) {
		if (Object.hasOwn(ledger, item)) throw new Error(`known-debt: "${item}" is listed twice`);
		ledger[item] = reason;
	}
	return ledger;
}

/**
 * Suffixes repeated identities with their rank (" #2", " #3"), so one file
 * reading the same path twice is two ledger entries, not one.
 * @param {string[]} ids - Identities in source order.
 * @returns {string[]} The same identities, made unique.
 */
function withOrdinals(ids) {
	const seen = new Map();
	return ids.map((id) => {
		const rank = (seen.get(id) || 0) + 1;
		seen.set(id, rank);
		return rank === 1 ? id : `${id} #${rank}`;
	});
}

/**
 * Reads one section of a JSON ledger file: {"<section>": {"reason": "...",
 * "entries": ["...", ...]}}. Long ledgers live in such a file, beside their
 * test, so the test code holds the rule and the file the admitted items.
 * @param {string} file - Absolute path of the ledger file.
 * @param {string} section - The section name.
 * @returns {Record<string, string>} The ledger.
 * @throws {Error} When the section, its reason or its entries are missing.
 */
function readJsonLedger(file, section) {
	const entry = JSON.parse(fs.readFileSync(file, 'utf8'))[section];
	if (!entry || typeof entry.reason !== 'string' || entry.reason.trim() === '')
		throw new Error(`${path.basename(file)}: no "${section}" section with a reason`);
	if (!Array.isArray(entry.entries))
		throw new Error(`${path.basename(file)}: the "${section}" section has no entries list`);
	return ledgerFromList(entry.entries, entry.reason);
}

/**
 * Drops the fixed entries of JSON ledger sections; refuses, and writes
 * nothing, while a scan finds an item its section does not admit.
 * @param {string} file - Absolute path of the ledger file.
 * @param {Record<string, string[]>} foundBySection - Each section's scan.
 * @returns {boolean} True when the file was rewritten.
 */
function shrinkJsonLedger(file, foundBySection) {
	const all = JSON.parse(fs.readFileSync(file, 'utf8'));
	let refused = false;
	for (const [section, found] of Object.entries(foundBySection)) {
		for (const item of compareKnownDebt(found, readJsonLedger(file, section)).added) {
			refused = true;
			console.error(`[ERROR] ${section}: ${item} is new; a ledger never grows.`);
		}
	}
	if (refused) return false;
	for (const [section, found] of Object.entries(foundBySection)) {
		const kept = new Set(found);
		all[section].entries = all[section].entries.filter((item) => kept.has(item));
		console.log(`${path.basename(file)} ${section}: ${all[section].entries.length} entr(ies).`);
	}
	fs.writeFileSync(file, JSON.stringify(all, null, '\t') + '\n');
	return true;
}

module.exports = {
	compareKnownDebt,
	reportKnownDebt,
	ledgerFromList,
	withOrdinals,
	readJsonLedger,
	shrinkJsonLedger
};
