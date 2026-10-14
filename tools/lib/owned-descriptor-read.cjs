// tools/lib/owned-descriptor-read.cjs

/** Preserve owned operation/cleanup failures with one cleanup attempt.
 * Explicit failure state retains falsy thrown values without claiming retirement.
 */
'use strict';

function performOwnedCleanup(operation, cleanup, message) {
	let value;
	let primary;
	let refused = false;
	try {
		value = operation();
	} catch (error) {
		primary = error;
		refused = true;
	}
	try {
		cleanup();
	} catch (closure) {
		if (refused) throw new AggregateError([primary, closure], message);
		throw closure;
	}
	if (refused) throw primary;
	return value;
}

/** Run one owned operation and attempt its original cleanup once. */
function runWithOwnedCleanup(operation, cleanup) {
	return performOwnedCleanup(operation, cleanup, 'Owned operation and cleanup refused.');
}

/** Read an acquired descriptor without changing its original close arguments. */
function readOwnedDescriptor(descriptor, read, close) {
	return performOwnedCleanup(
		read,
		() => close(descriptor),
		'Owned descriptor read and close refused.'
	);
}

module.exports = { readOwnedDescriptor, runWithOwnedCleanup };
