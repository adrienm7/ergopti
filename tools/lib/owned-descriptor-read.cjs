// tools/lib/owned-descriptor-read.cjs

/** Read an acquired descriptor and attempt its close exactly once.
 * A secondary close refusal preserves the exact original read failure.
 * Successful close alone cannot turn a refused read into accepted bytes.
 */
'use strict';

function readOwnedDescriptor(descriptor, read, close) {
	let value;
	let primary;
	let refused = false;
	try {
		value = read();
	} catch (error) {
		primary = error;
		refused = true;
	}
	try {
		close(descriptor);
	} catch (closure) {
		if (refused)
			throw new AggregateError([primary, closure], 'Owned descriptor read and close refused.');
		throw closure;
	}
	if (refused) throw primary;
	return value;
}

module.exports = { readOwnedDescriptor };
