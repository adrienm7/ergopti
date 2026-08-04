// tools/test/test-luajit-52-isms.cjs

/**
 * ==============================================================================
 * MODULE: Lua 5.2+ Constructs the Linux Driver Cannot Use
 * DESCRIPTION:
 * The Linux daemon and its CI suite run on LuaJIT, which is 5.1-based. Anything
 * added in 5.2 or later is a runtime nil there — and a developer's machine is
 * very likely to have Lua 5.4, where the same code works perfectly.
 *
 * WHY THIS GATE EXISTS, WITH THE DATE:
 * On 2026-08-05 the Linux suite passed locally under Lua 5.4 and failed on the CI
 * runner with `attempt to call field 'unpack' (a nil value)` — fourteen times.
 * `table.unpack` was in four files, three of them in _shared/lua and therefore
 * loaded by the daemon itself: compat/utf8.lua (the shim that exists FOR LuaJIT),
 * text_utils and the TOML codec. Two of those are on paths the daemon runs
 * constantly, so the only reason it had not crashed in front of a user is that
 * nobody had run it long enough.
 *
 * The package.json test script prefers luajit and falls back to lua5.4, so the
 * suite silently changes interpreter depending on what is installed. That is
 * convenient and it is exactly how this class of bug reaches CI: the local run is
 * green, and it is green on a different language version.
 *
 * WHAT IS CHECKED:
 * the constructs that are silently absent rather than syntax errors. A syntax
 * error (`goto` on 5.1, integer division `//`, bitwise `&`) fails to load and is
 * therefore self-announcing; a missing FUNCTION returns nil and dies only when
 * the branch containing it finally runs.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

// Everything the Linux driver loads: its own tree, plus the shared Lua both
// drivers share. macOS is excluded — Hammerspoon embeds Lua 5.4, so 5.2+
// constructs are legitimate there and flagging them would be noise.
const ROOTS = [path.join(SP, 'linux'), path.join(SP, '_shared', 'lua')];

// Absent under LuaJIT unless the build enabled 5.2 compatibility, which neither
// the CI runner's nor a distribution's luajit does. Each maps to what to write
// instead — a gate that only says "no" costs the reader a search.
const FORBIDDEN = [
	{
		pattern: /\btable\.unpack\s*\(/g,
		name: 'table.unpack',
		instead: 'local table_unpack = table.unpack or unpack, at the top of the file'
	},
	{
		pattern: /\bmath\.type\s*\(/g,
		name: 'math.type',
		instead: 'a manual check: type(v) == "number" and v % 1 == 0'
	},
	{
		pattern: /\btable\.move\s*\(/g,
		name: 'table.move',
		instead: 'an explicit loop'
	},
	{
		pattern: /\bstring\.pack\s*\(|\bstring\.unpack\s*\(/g,
		name: 'string.pack / string.unpack',
		instead: 'infra/input_event.lua\'s byte helpers, which exist for exactly this'
	}
];

// A bare `utf8.x` inside _shared/lua. LuaJIT has no utf8 table; the daemon and
// the unit runner each install the compat shim as a global before loading
// anything, which is why a first version of this gate called these correct and
// dropped the rule entirely.
//
// CI then crashed in _shared/lua/keymap/terminators.lua from the E2E runner —
// a THIRD entry point, which installs nothing. The reasoning was right about the
// two call sites it looked at and wrong about the population: a SHARED module
// cannot depend on its caller having installed a global, because it does not know
// its callers. Each one asks for the shim itself, which costs a require and
// removes a whole class of "works from here, crashes from there".
//
// Scoped to _shared/lua on purpose. A driver's own files may legitimately use the
// global — that driver's entry point installs it, and it is the same codebase.
const SHARED_ONLY = {
	// No trailing `\(` here, and that is the point: the crash CI found was
	// `pcall(utf8.offset, s, 2)` — a function REFERENCE, not a call. A first
	// version required the parenthesis and walked straight past all three of them,
	// so the gate went green and the E2E job kept crashing on the same line.
	pattern: /\butf8\.(char|codepoint|len|offset|codes)\b/g,
	name: 'a bare utf8.* in shared code',
	instead: 'a module-local `local utf8_lib = ... or require("compat.utf8")`, '
		+ 'as _shared/lua/keymap/terminators.lua does',
	// The shim necessarily names the functions it provides.
	skip: (file) => file.endsWith(path.join('compat', 'utf8.lua'))
};

const errors = [];
let scanned = 0;

/**
 * Every .lua file under a root, tests included.
 *
 * Tests included deliberately: the failure that prompted this gate WAS in a test
 * file, and a suite that cannot run on the interpreter it gates is a suite that
 * gates nothing.
 * @param {string} dir Directory to walk.
 * @param {string[]} out Accumulator.
 * @returns {string[]}
 */
function luaFiles(dir, out) {
	out = out || [];
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			// vendor/ is third-party and not ours to rewrite.
			if (entry.name === 'vendor' || entry.name === 'node_modules') continue;
			luaFiles(full, out);
		} else if (entry.name.endsWith('.lua')) {
			out.push(full);
		}
	}
	return out;
}

for (const root of ROOTS) {
	if (!fs.existsSync(root)) {
		errors.push(`${root} does not exist — this gate is scanning nothing.`);
		continue;
	}
	for (const file of luaFiles(root)) {
		scanned += 1;
		const src = fs.readFileSync(file, 'utf8');
		const relative = path.relative(SP, file).replace(/\\/g, '/');

		// The shared-only rule applies to _shared/lua and nothing else.
		const rules = relative.startsWith('_shared/lua/')
			? FORBIDDEN.concat([SHARED_ONLY])
			: FORBIDDEN;

		for (const rule of rules) {
			if (rule.skip && rule.skip(file)) continue;
			rule.pattern.lastIndex = 0;
			// The shim's own declaration line probes the global to decide whether it
			// is needed, so it names utf8.* legitimately. Blanked rather than dropped
			// so the reported line numbers still match the file.
			const subject = rule === SHARED_ONLY
				? src.split('\n').map((l) => (l.includes('local utf8_lib =') ? '' : l)).join('\n')
				: src;
			const hits = [...subject.matchAll(rule.pattern)];
			if (hits.length === 0) continue;

			// Report the line, because a file-level "somewhere in here" is a grep the
			// reader has to redo.
			const lines = [];
			for (const hit of hits) {
				lines.push(src.slice(0, hit.index).split('\n').length);
			}
			errors.push(
				`${relative}:${lines.join(',')} uses ${rule.name}, which is nil under LuaJIT — the ` +
					`interpreter the Linux daemon and its CI suite actually run. Use ${rule.instead}.`
			);
		}
	}
}

// A floor. A walk that stopped finding files would report a clean tree, and this
// gate would pass by scanning nothing at all.
const MIN_FILES = 150;
if (scanned < MIN_FILES) {
	errors.push(
		`scanned only ${scanned} Lua file(s) (floor ${MIN_FILES}) — the walk is broken, so a clean ` +
			'result here means nothing was read rather than nothing was found.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] Lua 5.2+ constructs in code that runs on LuaJIT:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	console.error(
		'\n  These do not fail to load. They return nil and die when the branch runs, which is why\n' +
			'  the suite can be green locally on Lua 5.4 and red on CI.'
	);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] no Lua 5.2+ constructs in the ${scanned} file(s) LuaJIT has to load.\x1b[0m`
);
