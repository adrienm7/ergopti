// tools/test/lib/host-capabilities.cjs

/**
 * ==============================================================================
 * MODULE: Host Capability Probes
 * DESCRIPTION:
 * Tells a JS check whether this host can execute a case that needs a POSIX
 * capability, so the case is either executed or reported as not executed,
 * never silently passed.
 *
 * FEATURES & RATIONALE:
 * 1. Windows grants symlink creation only with Developer Mode or the
 *    SeCreateSymbolicLinkPrivilege; without it fs.symlinkSync throws EPERM
 *    (Win32 error 1314). Hosted runners hold the privilege.
 * 2. Only a local Windows host may skip. On GitHub Actions or another OS a
 *    probe never skips and any unexpected error throws, so every CI lane still
 *    executes every assertion.
 * 3. Each skip prints one "SKIP (not executed):" line with its reason; the JS
 *    suite runner lists those lines so a local summary cannot read as a pass.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const SKIP_PREFIX = 'SKIP (not executed):';
let symlinkProbe = null;

/** True on a developer's Windows machine, false on every CI runner. */
function isLocalWindowsHost() {
	return process.platform === 'win32' && process.env.GITHUB_ACTIONS !== 'true';
}

/**
 * Print the explicit not-executed line for one case.
 * @param {string} label Name of the case that did not run.
 * @param {string} reason Why this host cannot run it.
 */
function reportNotExecuted(label, reason) {
	console.log(`${SKIP_PREFIX} ${label}: ${reason}; hosted CI lanes execute it`);
}

/**
 * Probe once whether this process can create a file symlink.
 * @returns {boolean}
 */
function canCreateSymlinks() {
	if (symlinkProbe !== null) return symlinkProbe;
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-symlink-probe-'));
	try {
		const target = path.join(directory, 'target');
		fs.writeFileSync(target, '');
		try {
			fs.symlinkSync(target, path.join(directory, 'link'));
			symlinkProbe = true;
		} catch (error) {
			if (!(isLocalWindowsHost() && error.code === 'EPERM')) throw error;
			symlinkProbe = false;
		}
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
	return symlinkProbe;
}

/**
 * Return true when the symlink case may run; otherwise report why it did not.
 * @param {string} label Name of the case that needs a symlink.
 * @returns {boolean}
 */
function canRunSymlinkCase(label) {
	if (canCreateSymlinks()) return true;
	reportNotExecuted(
		label,
		'this Windows account lacks the symlink privilege (EPERM, Win32 error 1314); ' +
			'enable Developer Mode to run it here'
	);
	return false;
}

module.exports = {
	SKIP_PREFIX,
	canCreateSymlinks,
	canRunSymlinkCase,
	isLocalWindowsHost,
	reportNotExecuted
};
