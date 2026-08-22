// scripts/test-ahk-encoding.cjs

/**
 * ==============================================================================
 * MODULE: AHK Encoding Guard
 * DESCRIPTION:
 * Validates that every .ahk file under static/ergopti_plus/windows/ is encoded
 * as UTF-8 with BOM and uses LF line endings.
 *
 * FEATURES & RATIONALE:
 * 1. BOM check: AHK v2 silently aborts mid-file when the UTF-8 BOM is absent.
 * 2. LF check: CR bytes are rejected so every source uses one line-ending
 *    convention and no mixed-line-ending parser edge case can hide tests.
 * 3. Vendor exclusion: Third-party files under vendor/ are not maintained by
 *    this project and are excluded from the invariant.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('node:os');
const path = require('path');
const { spawnSync } = require('node:child_process');

// ===================================
// ===================================
// ======= 1/ File Collection =======
// ===================================
// ===================================

const ROOT = path.resolve(__dirname, '..', '..', 'static', 'ergopti_plus', 'windows');
const REPOSITORY_ROOT = path.resolve(__dirname, '..', '..');
const FIXER = path.join(REPOSITORY_ROOT, 'tools', 'deploy', 'fix-ahk-encoding.cjs');
const HOOK = path.join(REPOSITORY_ROOT, '.husky', 'pre-commit');

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
			if (entry.name === 'vendor') continue;
			results.push(...collectAhkFiles(fullPath));
		} else if (entry.isFile() && entry.name.endsWith('.ahk')) {
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
 * Checks whether a file contains any CR byte (0x0D).
 * @param {Buffer} buf - Raw file contents.
 * @returns {boolean} True if at least one CR byte is found.
 */
function hasCr(buf) {
	for (let i = 0; i < buf.length; i++) {
		if (buf[i] === 0x0d) {
			return true;
		}
	}
	return false;
}

function git(cwd, args, encoding = 'utf8') {
	const result = spawnSync('git', args, { cwd, encoding });
	assert.equal(result.status, 0, result.stderr?.toString() || result.error?.message);
	return result.stdout;
}

function testStagedFixerDoesNotMutateUnstagedAhk() {
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-encoding-'));
	try {
		git(temporary, ['init']);
		git(temporary, ['config', 'user.email', 'encoding-test@example.invalid']);
		git(temporary, ['config', 'user.name', 'Encoding Test']);
		const staged = path.join(temporary, 'staged.ahk');
		const unstaged = path.join(temporary, 'unstaged.ahk');
		const valid = (body) => Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(body)]);
		fs.writeFileSync(staged, valid('; staged\n'));
		fs.writeFileSync(unstaged, valid('; unstaged\n'));
		git(temporary, ['add', '--', 'staged.ahk', 'unstaged.ahk']);
		git(temporary, ['commit', '-m', 'chore: initialize fixture']);

		fs.writeFileSync(staged, Buffer.from('; staged change\r\n'));
		git(temporary, ['add', '--', 'staged.ahk']);
		fs.writeFileSync(unstaged, Buffer.from('; preserve this unstaged file\r\n'));
		const unstagedBefore = fs.readFileSync(unstaged);

		const fixtureFixer = path.join(temporary, 'tools', 'deploy', 'fix-ahk-encoding.cjs');
		fs.mkdirSync(path.dirname(fixtureFixer), { recursive: true });
		fs.copyFileSync(FIXER, fixtureFixer);
		const result = spawnSync(process.execPath, [fixtureFixer, '--staged'], {
			cwd: temporary,
			encoding: 'utf8'
		});
		assert.equal(result.status, 0, result.stderr);

		const stagedWorking = fs.readFileSync(staged);
		assert.ok(hasBom(stagedWorking), 'the staged AHK working file must gain a UTF-8 BOM');
		assert.equal(hasCr(stagedWorking), false, 'the staged AHK working file must become LF-only');
		assert.deepEqual(
			fs.readFileSync(unstaged),
			unstagedBefore,
			'an unstaged AHK file must remain byte-for-byte untouched'
		);
		const stagedIndex = git(temporary, ['show', ':staged.ahk'], null);
		assert.ok(hasBom(stagedIndex), 'the corrected staged AHK bytes must be re-staged');
		assert.equal(hasCr(stagedIndex), false, 'the staged AHK index blob must become LF-only');
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}

	const hook = fs.readFileSync(HOOK, 'utf8');
	assert.match(
		hook,
		/node tools\/deploy\/fix-ahk-encoding\.cjs --staged/,
		'the pre-commit hook must invoke the fixer in staged-only mode'
	);
}

function testStagedFixerRefusesPartiallyStagedAhkAtomically() {
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-partial-stage-'));
	try {
		git(temporary, ['init']);
		git(temporary, ['config', 'user.email', 'encoding-test@example.invalid']);
		git(temporary, ['config', 'user.name', 'Encoding Test']);
		const partiallyStaged = path.join(temporary, 'partially-staged.ahk');
		const fullyStaged = path.join(temporary, 'fully-staged.ahk');
		const valid = (body) => Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(body)]);
		fs.writeFileSync(partiallyStaged, valid('; partial baseline\n'));
		fs.writeFileSync(fullyStaged, valid('; full baseline\n'));
		git(temporary, ['add', '--', 'partially-staged.ahk', 'fully-staged.ahk']);
		git(temporary, ['commit', '-m', 'chore: initialize fixture']);

		fs.writeFileSync(partiallyStaged, Buffer.from('; staged portion\r\n'));
		fs.writeFileSync(fullyStaged, Buffer.from('; fully staged change\r\n'));
		git(temporary, ['add', '--', 'partially-staged.ahk', 'fully-staged.ahk']);
		fs.writeFileSync(
			partiallyStaged,
			Buffer.from('; staged portion\r\n; preserve this unstaged portion\r\n')
		);

		const before = {
			partialWorking: fs.readFileSync(partiallyStaged),
			partialIndex: git(temporary, ['show', ':partially-staged.ahk'], null),
			fullWorking: fs.readFileSync(fullyStaged),
			fullIndex: git(temporary, ['show', ':fully-staged.ahk'], null)
		};
		const fixtureFixer = path.join(temporary, 'tools', 'deploy', 'fix-ahk-encoding.cjs');
		fs.mkdirSync(path.dirname(fixtureFixer), { recursive: true });
		fs.copyFileSync(FIXER, fixtureFixer);
		const result = spawnSync(process.execPath, [fixtureFixer, '--staged'], {
			cwd: temporary,
			encoding: 'utf8'
		});

		assert.notEqual(result.status, 0, 'a partially staged AHK file must stop the fixer');
		assert.match(
			result.stderr,
			/partially staged AHK file.*partially-staged\.ahk/is,
			'the refusal must identify the partially staged destination'
		);
		assert.deepEqual(fs.readFileSync(partiallyStaged), before.partialWorking);
		assert.deepEqual(
			git(temporary, ['show', ':partially-staged.ahk'], null),
			before.partialIndex,
			'the partially staged index blob must remain unchanged'
		);
		assert.deepEqual(
			fs.readFileSync(fullyStaged),
			before.fullWorking,
			'an earlier fully staged destination must not be rewritten before refusal'
		);
		assert.deepEqual(
			git(temporary, ['show', ':fully-staged.ahk'], null),
			before.fullIndex,
			'an earlier fully staged index blob must not be re-staged before refusal'
		);
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
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
		const rel = path.relative(path.resolve(__dirname, '..'), filePath).replace(/\\/g, '/');

		if (!hasBom(buf)) {
			violations.push(`  MISSING BOM  : ${rel}`);
			// Do not check CRLF when BOM is absent — the file is already invalid
			continue;
		}

		if (hasCr(buf)) {
			violations.push(`  CR BYTE      : ${rel}`);
		}
	}

	const total = files.length;

	if (violations.length > 0) {
		console.error(
			`\nAHK encoding violations detected (${violations.length} file(s) out of ${total}):\n`
		);
		for (const v of violations) {
			console.error(v);
		}
		console.error('\nAll .ahk source files must be UTF-8 with BOM and LF line endings.');
		console.error("To fix: open the file in VS Code, set encoding to 'UTF-8 with BOM' and");
		console.error('line endings to LF, then save.\n');
		process.exit(1);
	}

	testStagedFixerDoesNotMutateUnstagedAhk();
	testStagedFixerRefusesPartiallyStagedAhkAtomically();

	console.log(`\nEncoding check passed — ${total} .ahk file(s) verified (UTF-8 BOM + LF).\n`);
	process.exit(0);
}

run();
