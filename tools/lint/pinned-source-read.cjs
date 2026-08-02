// tools/lint/pinned-source-read.cjs

/**
 * ==============================================================================
 * MODULE: Pinned Source-Read Definition (single source of truth)
 * DESCRIPTION:
 * Defines what "a test reads a driver source file by a hardcoded path" MEANS,
 * for the ratchet that counts them (test-no-pinned-source-reads-lua.cjs) and the
 * auto-fixer that converts them (fix-pinned-source-reads.cjs). Both used to
 * carry their own regex, and they disagreed: the ratchet counted 56 pins while
 * the fixer could see 12, so "the fixer converts most of the lot" was a claim
 * about two different populations.
 *
 * FEATURES & RATIONALE:
 * 1. The unit is the PATH LITERAL, not the read expression. Three separate
 *    widenings of a shape-specific pattern each surfaced pins that had been
 *    there the whole time — a dead `lib` arm, a missing driver-root `init.lua`
 *    arm, and paths reached through a local bound to driver_root() on an
 *    earlier line. What a `git mv` breaks is the string naming the file; how
 *    that string reaches io.open is irrelevant to the breakage, so matching on
 *    the read expression will always be a guess about shapes someone will
 *    write next. Matching the literal is not.
 * 2. Only literals that RESOLVE to a real file count. A test asserting that
 *    ui/menu/menu_script_control.lua is gone must name it; there is nothing to
 *    convert, and counting it would freeze a number that can only be lowered by
 *    weakening an absence assertion. The trade is that deleting a production
 *    file silently drops its pins from the count instead of failing here — but
 *    those tests fail at runtime on the next read anyway, which is louder.
 * 3. Directories, not a file list: anything under modules/, infra/, lib/, ui/
 *    or adapters/, plus the driver-root init.lua, which is in no sub-tree at
 *    all and was invisible to every directory arm for as long as the gate
 *    existed. `lib` is dead since e97ddbd08 renamed it to infra/ and is kept
 *    only so a stray lib/ path cannot slip back in unseen.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

// A quoted path naming a file inside one of a driver's source trees, or the
// driver-root init.lua. Deliberately unanchored to any concatenation syntax.
const SOURCE_PATH_LITERAL =
	'["\'](?:[.\\\\/]*(?:modules|infra|lib|ui|adapters)[\\\\/][^"\'\\n]*|[.\\\\/]*init)\\.lua["\']';

/** Fresh global matcher — callers must not share lastIndex. */
function literalMatcher() {
	return new RegExp(SOURCE_PATH_LITERAL, 'g');
}

/**
 * Extracts every pinned driver-source path in one test file.
 *
 * @param {string} src - Test file contents.
 * @param {string} driverRoot - Absolute path of the driver root the paths resolve against.
 * @returns {{literal: string, rel: string, line: number, resolves: boolean}[]} One entry per literal.
 */
function findPinnedPaths(src, driverRoot) {
	const out = [];
	const re = literalMatcher();
	let m;
	while ((m = re.exec(src))) {
		const literal = m[0];
		const rel = literal.slice(1, -1).replace(/^[.\\/]+/, '');
		const abs = path.join(driverRoot, rel.split('/').join(path.sep));
		out.push({
			literal,
			rel,
			line: src.slice(0, m.index).split('\n').length,
			resolves: fs.existsSync(abs),
		});
	}
	return out;
}

/**
 * Collects every test_*.lua file under a directory.
 * @param {string} dir - Absolute directory to walk.
 * @param {string[]} acc - Accumulator for matched absolute file paths.
 * @returns {string[]} The accumulator, populated with absolute paths.
 */
function collectLuaTests(dir, acc) {
	if (!fs.existsSync(dir)) return acc;
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) collectLuaTests(full, acc);
		else if (entry.isFile() && /^test_.*\.lua$/.test(entry.name)) acc.push(full);
	}
	return acc;
}

module.exports = { SOURCE_PATH_LITERAL, literalMatcher, findPinnedPaths, collectLuaTests };
