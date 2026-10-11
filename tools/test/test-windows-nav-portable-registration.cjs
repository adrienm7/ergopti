// tools/test/test-windows-nav-portable-registration.cjs

/**
 * Platform-neutral census controls for the authored native C registrations.
 * This verifies selection only; it never compiles C or qualifies Windows.
 */
'use strict';

const assert = require('node:assert/strict');
const { testNames, testNamesFromSource } = require('./run-nav-event-owner-portable.cjs');

// This authored census is independent of the reader's dynamic source traversal.
// Add a case explicitly here when its native registration is introduced.
const EXPECTED = [
	'A7 receipt survives B swap',
	'repaint swap rejects stale index',
	'B6 refusal is fail-open',
	'transition fence passes',
	'arrows pass with receipts',
	'digit keyup latch',
	'injected input levels',
	'injected modifiers cannot poison physical input',
	'modifier provenance survives crossed releases',
	'acceptance claim linearizes navigation',
	'duplicate receipt ownership',
	'queue full is fail-open',
	'suspend is fail-open',
	'held-key overflow stays fail-open',
	'suppressed menu chord disguises release',
	'menu mask failure precedes suppression',
	'passed events do not emit menu mask',
	'passed untrusted control prevents menu mask',
	'startup snapshot cannot claim physical provenance',
	'orphan modifier up disguises pending menu',
	'menu mask survives multiple Win holds',
	'stop drain balances consumed holds',
	'terminal capture replays exact physical edges',
	'terminal route snapshots retain exact suffix (todo49-route-fifo)',
	'terminal output preview is authenticated and guarded (todo49-output-preview)',
	'terminal output custody settles exact FIFO head (todo49-output-custody)',
	'terminal replay cannot promote lower integrity (todo49-replay-provenance)',
	'terminal replay retains effective modifiers (todo49-replay-modifiers)',
	'terminal replay survives crossed modifier releases (todo49-replay-modifiers)',
	'terminal replay hands off held modifier (todo49-replay-modifiers)',
	'terminal capture partial replay is retryable',
	'terminal capture admission and overflow',
	'terminal release has one owner',
	'terminal release preserves concurrent overflow',
	'unmatched down latches pass across modifiers',
	'profile receipt survives order swap',
	'profile transition freezes pending targets',
	'navigation precedes profile selection',
	'plan validation is atomic',
	'nav-stale-physical-modifier',
	'hook trace refuses unauthenticated sessions (todo49-hook-trace)',
	'hook trace excludes deterministic dispatch (todo49-hook-trace)',
	'native editor receiver matrix',
	'terminal output custody preserves fault debt (todo49-output-custody)'
];

/** Requires the complete authored census, including the explicitly native-only case. */
function checkCensus(names) {
	assert.equal(EXPECTED.length, 44);
	assert.deepEqual(names, EXPECTED, 'A native registration was lost, added or reordered.');
	assert.equal(names.filter((name) => name !== 'native editor receiver matrix').length, 43);
}

/** Creates an independent source fixture with the parser's documented table shape. */
function fixture(names) {
	return (
		'NavTestCase tests[] = {\n' +
		names.map((name, index) => `\t\t{"${name}", Case${index}},`).join('\n') +
		'\n\t};'
	);
}

checkCensus(testNames());
const source = fixture(EXPECTED);
checkCensus(testNamesFromSource(source));
assert.throws(() => testNamesFromSource(''), /registration table is missing/);
assert.throws(() => checkCensus(testNamesFromSource(fixture(EXPECTED.slice(1)))), /registration/);
assert.throws(() => testNamesFromSource(fixture([...EXPECTED, EXPECTED[0]])), /unique/);
assert.throws(
	() =>
		testNamesFromSource(source.replace('{"arrows pass with receipts", Case4}', 'UNPARSED_CASE()')),
	/Every native registration must be parsed/
);
assert.throws(
	() =>
		testNamesFromSource(
			fixture(EXPECTED.filter((name) => name !== 'native editor receiver matrix'))
		),
	/Native-only editor registration/
);
assert.throws(
	() => checkCensus(testNamesFromSource(fixture([...EXPECTED].reverse()))),
	/registration/
);
console.log(
	'Portable navigation registration: 44 authored cases and 6 negative selection controls passed.'
);
console.log('Source selection only; no C execution or Windows native qualification.');
