// scripts/test-ahk-encoding.cjs

/**
 * ==============================================================================
 * MODULE: AHK Encoding Guard
 * DESCRIPTION:
 * Validates that every .ahk file under static/ergopti_plus/windows/ is encoded
 * as UTF-8 with BOM and uses CRLF line endings.
 *
 * FEATURES & RATIONALE:
 * 1. BOM check: AHK v2 silently aborts mid-file when the UTF-8 BOM is absent.
 * 2. CRLF check: A bare LF in the source causes the parser to silently stop
 *    processing at the affected line, producing invisible test failures.
 * 3. Vendor exclusion: Third-party files under vendor/ are not maintained by
 *    this project and are excluded from the invariant.
 * ==============================================================================
 */

"use strict";

const fs = require("fs");
const path = require("path");




// ===================================
// ===================================
// ======= 1/ File Collection =======
// ===================================
// ===================================

const ROOT = path.resolve(__dirname, "..", "..", "static", "ergopti_plus", "windows");

/**
 * Recursively collects all .ahk files under a directory, skipping vendor/.
 * @param {string} dir - Absolute path to the directory to scan.
 * @returns {string[]} Sorted list of absolute .ahk file paths.
 */
function collectAhkFiles(dir) {
	const results = [];

	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const fullPath = path.join(dir, entry.name);

		if (entry.isDirectory()) {
			// Skip third-party vendor files — they are not maintained here
			if (entry.name === "vendor") continue;
			results.push(...collectAhkFiles(fullPath));
		} else if (entry.isFile() && entry.name.endsWith(".ahk")) {
			results.push(fullPath);
		}
	}

	return results.sort();
}




// ===================================
// ===================================
// ======= 2/ Encoding Checks =======
// ===================================
// ===================================

// UTF-8 BOM byte sequence
const BOM_BYTE_0 = 0xef;
const BOM_BYTE_1 = 0xbb;
const BOM_BYTE_2 = 0xbf;

// Minimum file length to contain a BOM
const MIN_BOM_LENGTH = 3;

/**
 * Checks whether a file starts with the UTF-8 BOM (EF BB BF).
 * @param {Buffer} buf - Raw file contents.
 * @returns {boolean} True if the BOM is present.
 */
function hasBom(buf) {
	return (
		buf.length >= MIN_BOM_LENGTH &&
		buf[0] === BOM_BYTE_0 &&
		buf[1] === BOM_BYTE_1 &&
		buf[2] === BOM_BYTE_2
	);
}

/**
 * Checks whether a file contains bare LF bytes (0x0A not preceded by CR 0x0D).
 * @param {Buffer} buf - Raw file contents.
 * @returns {boolean} True if at least one bare LF is found.
 */
function hasBareLf(buf) {
	for (let i = 0; i < buf.length; i++) {
		if (buf[i] === 0x0a && (i === 0 || buf[i - 1] !== 0x0d)) {
			return true;
		}
	}
	return false;
}


// =====================================
// =====================================
// ======= 3/ Validation Runner =======
// =====================================
// =====================================

/**
 * Validates all collected .ahk files and reports any encoding violations.
 * Exits with code 1 if at least one violation is found, 0 otherwise.
 */
function run() {
	if (!fs.existsSync(ROOT)) {
		console.error(`ERROR: AHK root directory not found: ${ROOT}`);
		process.exit(1);
	}

	const files = collectAhkFiles(ROOT);

	if (files.length === 0) {
		console.warn(`WARNING: No .ahk files found under ${ROOT}`);
		process.exit(0);
	}

	const violations = [];

	for (const filePath of files) {
		const buf = fs.readFileSync(filePath);
		const rel = path.relative(path.resolve(__dirname, ".."), filePath).replace(/\\/g, "/");

		if (!hasBom(buf)) {
			violations.push(`  MISSING BOM  : ${rel}`);
			// Do not check CRLF when BOM is absent — the file is already invalid
			continue;
		}

		if (hasBareLf(buf)) {
			violations.push(`  BARE LF      : ${rel}`);
		}
	}

	const total = files.length;

	if (violations.length > 0) {
		console.error(`\nAHK encoding violations detected (${violations.length} file(s) out of ${total}):\n`);
		for (const v of violations) {
			console.error(v);
		}
		console.error("\nAll .ahk source files must be UTF-8 with BOM and CRLF line endings.");
		console.error("To fix: open the file in VS Code, set encoding to 'UTF-8 with BOM' and");
		console.error("line endings to CRLF, then save.\n");
		process.exit(1);
	}

	console.log(`\nEncoding check passed — ${total} .ahk file(s) verified (UTF-8 BOM + CRLF).\n`);
	process.exit(0);
}

run();
