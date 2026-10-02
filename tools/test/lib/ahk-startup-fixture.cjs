// tools/test/lib/ahk-startup-fixture.cjs

/**
 * ==============================================================================
 * MODULE: Private AutoHotkey Startup Code Fixture
 * DESCRIPTION:
 * Isolates generated includes as well as configuration. A wrapper beside the
 * production entry still shares its generated personal-shortcuts forwarder,
 * causing the next real reload to repair a test path and restart a second time.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

/** Copies executable source while sharing read-only bundle dependencies. */
function createStartupCodeFixture(container, sourceWindows) {
	const windows = path.join(container, 'static/ergopti_plus/windows');
	fs.cpSync(sourceWindows, windows, {
		recursive: true,
		filter: (file) => {
			const relative = path.relative(sourceWindows, file);
			return !/^tests([\\/]|$)/.test(relative) && !/^\.ergopti_/.test(relative);
		}
	});
	const links = [
		[
			path.join(container, 'static/ergopti_plus/_shared'),
			path.resolve(sourceWindows, '../_shared')
		],
		[path.join(container, 'static/layouts'), path.resolve(sourceWindows, '../../layouts')],
		[path.join(container, 'static/img'), path.resolve(sourceWindows, '../../img')]
	];
	const installed = [];
	try {
		for (const [destination, source] of links) {
			fs.symlinkSync(source, destination, 'junction');
			installed.push(destination);
		}
	} catch (error) {
		for (const destination of installed) fs.unlinkSync(destination);
		throw error;
	}
	return {
		windows,
		close() {
			// Detach junctions before the caller recursively deletes its private tree.
			for (const destination of installed) {
				if (!fs.lstatSync(destination).isSymbolicLink())
					throw new Error('The private dependency junction changed identity.');
				fs.unlinkSync(destination);
			}
		}
	};
}

/** Binds the parse-time include to the same personal file that boot will own. */
function prepareStartupPersonalInclude(windows, config) {
	const personal = path.join(config, 'autohotkey/personal_shortcuts.ahk');
	fs.writeFileSync(
		path.join(windows, '_generated/personal_shortcuts.ahk'),
		`\uFEFF; Private startup fixture forwarding include.\n#Include *i ${personal}\n`
	);
}

module.exports = { createStartupCodeFixture, prepareStartupPersonalInclude };
