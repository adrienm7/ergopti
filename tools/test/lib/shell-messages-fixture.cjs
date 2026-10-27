// tools/test/lib/shell-messages-fixture.cjs

/**
 * ==============================================================================
 * MODULE: Shell Messages Fixture
 * DESCRIPTION:
 * The Linux shell scripts source install/messages.sh, which reads the generated
 * catalogues in _generated/shell_messages/ beside the install/ folder. A test
 * that copies a script into a sandbox driver tree provides both through this
 * helper, the way the real driver tree carries them, instead of the script
 * special-casing their absence.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const LINUX = path.resolve(__dirname, '..', '..', '..', 'static', 'ergopti_plus', 'linux');

/**
 * Copies the message reader and every catalogue into a sandbox driver tree.
 * @param {string} installDirectory The sandbox's install/ folder (it is created).
 */
function provideShellMessages(installDirectory) {
	fs.mkdirSync(installDirectory, { recursive: true });
	fs.copyFileSync(
		path.join(LINUX, 'install', 'messages.sh'),
		path.join(installDirectory, 'messages.sh')
	);
	fs.cpSync(
		path.join(LINUX, '_generated', 'shell_messages'),
		path.join(installDirectory, '..', '_generated', 'shell_messages'),
		{ recursive: true }
	);
}

module.exports = { provideShellMessages };
