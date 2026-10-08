// tools/lib/python.cjs

/**
 * ==============================================================================
 * MODULE: Actual CPython Resolution
 * DESCRIPTION:
 * Resolves the native executable using the validated CPython convention of the
 * Swift fixture. Explicit PYTHON has no fallback; absence or unsupported native
 * capability fails before a receiving test can claim an executed control.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PROBE =
	'import json, platform, sys; assert platform.python_implementation() == "CPython"; assert sys.version_info >= (3, 8); print(json.dumps({"executable": sys.executable}))';

/** Return one observed absolute CPython executable or fail its prerequisite. */
function pythonExecutable(
	environment = process.env,
	native = { spawnSync, statSync: fs.statSync, isAbsolute: path.isAbsolute }
) {
	const explicit = Object.prototype.hasOwnProperty.call(environment, 'PYTHON');
	if (
		explicit &&
		(typeof environment.PYTHON !== 'string' ||
			environment.PYTHON === '' ||
			environment.PYTHON.includes('\0'))
	) {
		throw new Error('Configured PYTHON must name one executable.');
	}
	const candidates = explicit ? [environment.PYTHON] : ['python3', 'python'];
	for (const candidate of candidates) {
		const result = native.spawnSync(candidate, ['-c', PROBE], { encoding: 'utf8', timeout: 10000 });
		if (result.error || result.status !== 0) continue;
		try {
			const receipt = JSON.parse(result.stdout);
			if (
				receipt &&
				typeof receipt.executable === 'string' &&
				native.isAbsolute(receipt.executable) &&
				native.statSync(receipt.executable).isFile()
			)
				return receipt.executable;
		} catch {
			// An alias/banner or missing native file is not a usable interpreter.
		}
	}
	throw new Error(
		explicit
			? 'Configured PYTHON does not provide CPython 3.8 or later.'
			: 'CPython 3.8 or later is required.'
	);
}

module.exports = { pythonExecutable };
