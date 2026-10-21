// tools/ci/windows-exe-size-budget.cjs

/**
 * ==============================================================================
 * MODULE: Windows Executable Size Budget
 * DESCRIPTION:
 * The single declaration of how large the compiled ErgoptiPlus.exe may be, and
 * the check the Windows build stage runs on the exe it has just compiled.
 *
 * WHY THIS EXISTS:
 * The exe grew from 10528256 bytes (v1.0.0) to 11403776 bytes (v1.0.4) in
 * eleven days, and nothing reported it. Most of it is the compiled script,
 * which Ahk2Exe stores uncompressed, plus the embedded runtime bundle. A
 * sudden jump (a vendored binary or a data file entering the bundle by
 * mistake) now fails the build. Raising the budget is a reviewed one-line
 * change here, made with the measured composition in the commit message.
 *
 * USAGE:  node tools/ci/windows-exe-size-budget.cjs <path-to-ErgoptiPlus.exe>
 *         Exits 1 with the size, the budget and the excess when the exe is
 *         missing, empty or over the budget.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');

/** Largest accepted ErgoptiPlus.exe in bytes: 12 MiB, about 1.1 MiB above v1.0.4. */
const WINDOWS_EXE_SIZE_BUDGET_BYTES = 12 * 1024 * 1024;

/**
 * Checks one compiled executable against the budget.
 * @param {string} exePath Path of the compiled ErgoptiPlus.exe.
 * @param {number} [budgetBytes] Budget to apply; the declared budget by default.
 * @return {{size: number, budget: number}} The measured size and the budget.
 * @throws {Error} When the file is missing, not a regular file, empty or over the budget.
 */
function checkWindowsExeSize(exePath, budgetBytes = WINDOWS_EXE_SIZE_BUDGET_BYTES) {
	if (typeof exePath !== 'string' || exePath.length === 0)
		throw new Error('A compiled ErgoptiPlus.exe path is required.');
	if (!Number.isSafeInteger(budgetBytes) || budgetBytes <= 0)
		throw new Error(`Invalid Windows exe size budget: ${budgetBytes}.`);
	const stat = fs.statSync(exePath);
	if (!stat.isFile()) throw new Error(`${exePath} is not a regular file.`);
	if (stat.size === 0) throw new Error(`${exePath} is empty.`);
	if (stat.size > budgetBytes) {
		throw new Error(
			`${exePath} is ${stat.size} bytes, over the ${budgetBytes}-byte budget by ` +
				`${stat.size - budgetBytes} bytes. Find what grew (the compiled script resource ` +
				'RCDATA/1 and RCDATA/BUILD/STATIC_BUNDLE.ZIP) before raising ' +
				'WINDOWS_EXE_SIZE_BUDGET_BYTES in tools/ci/windows-exe-size-budget.cjs.'
		);
	}
	return { size: stat.size, budget: budgetBytes };
}

module.exports = { WINDOWS_EXE_SIZE_BUDGET_BYTES, checkWindowsExeSize };

if (require.main === module) {
	const args = process.argv.slice(2);
	if (args.length !== 1) {
		console.error('Usage: node tools/ci/windows-exe-size-budget.cjs <path-to-ErgoptiPlus.exe>');
		process.exit(1);
	}
	try {
		const { size, budget } = checkWindowsExeSize(args[0]);
		console.log(
			`[OK] ${args[0]}: ${size} bytes, ${budget - size} bytes under the ${budget}-byte budget.`
		);
	} catch (error) {
		console.error(`[FAIL] ${error.message}`);
		process.exit(1);
	}
}
