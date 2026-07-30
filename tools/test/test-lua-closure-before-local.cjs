// tools/test/test-lua-closure-before-local.cjs

/**
 * ==============================================================================
 * MODULE: Lua Closure-Binds-Nil-Global Ratchet
 * DESCRIPTION:
 * Rejects the one bug class this repo has recorded THREE separate recurrences
 * of: a closure that captures a `local` which does not exist yet, and therefore
 * binds the nil global of the same name.
 *
 * THE LANGUAGE RULE:
 * In Lua the scope of `local x = <expr>` begins AFTER the full statement. Inside
 * `<expr>` the name `x` still resolves to `_G.x`, which is nil. So
 *
 *     local task = hs.task.new(cmd, function() pool[task] = nil end)
 *
 * reads perfectly and binds nil: at call time `pool[nil] = nil` raises "table
 * index is nil". The fix is always the two-line split —
 * `local task` then `task = hs.task.new(…)` — plus a nil check in the callback.
 *
 * WHY IT KEEPS COMING BACK, AND WHY A GREP IS NOT ENOUGH:
 * hs.task and ShellRunner invoke completion callbacks inside a pcall, so the
 * throw is swallowed and never reaches the file logger. The whole callback body
 * aborts on its first line and the driver simply does nothing. Recurrence 1 was
 * `api_ollama`'s `os.remove(tmp_path)` — Ollama predictions silently stopped
 * appearing; recurrence 2 the F10 download fix; recurrence 3 (F-CRIT-2) left
 * self-update completely dead. Each time a test existed and stayed green,
 * because each only grepped that the using line was PRESENT.
 *
 * Every site is fixed today, so this lands at zero. It is a pure ratchet against
 * the fourth recurrence. Slug: project_lua_closure_before_local_nil_global.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');

// All three Lua trees. The trap is a property of the language, not of a driver,
// and _shared/lua is consumed by two of them.
const TREES = [
	{ name: 'macos', dir: path.join(DRIVERS, 'macos') },
	{ name: 'linux', dir: path.join(DRIVERS, 'linux') },
	{ name: '_shared', dir: path.join(DRIVERS, '_shared', 'lua') },
];

// Third-party source is not ours to fix, and tests may construct the shape on
// purpose to prove a guard works.
const EXCLUDED = ['/vendor/', '/tests/'];

// ==================================================
// ==================================================
// ======= 1/ Walking the trees =====================
// ==================================================
// ==================================================

/**
 * @param {string} dir Directory to walk.
 * @param {string[]} acc Accumulator.
 * @returns {string[]} Absolute paths of production .lua files.
 */
function collectLua(dir, acc) {
	if (!fs.existsSync(dir)) return acc;
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		const posix = full.replace(/\\/g, '/');
		if (EXCLUDED.some((skip) => posix.includes(skip))) continue;
		if (entry.isDirectory()) collectLua(full, acc);
		else if (entry.name.endsWith('.lua')) acc.push(full);
	}
	return acc;
}

/**
 * Strips `--` comments and string literals so an identifier mentioned in prose
 * or inside a message cannot be mistaken for a reference. Long-bracket strings
 * are left alone; they carry no code either way.
 * @param {string} line One source line.
 * @returns {string} The line with comments and quoted spans blanked out.
 */
function codeOnly(line) {
	return line
		.replace(/"(?:[^"\\]|\\.)*"/g, '""')
		.replace(/'(?:[^'\\]|\\.)*'/g, "''")
		.replace(/--.*$/, '');
}

// ==================================================
// ==================================================
// ======= 2/ Detecting the shape ===================
// ==================================================
// ==================================================

/**
 * Finds every `local NAME = <expr>` whose own initialiser contains a function
 * literal that references NAME.
 *
 * The statement is followed until bracket depth returns to zero, so a callback
 * spanning twenty lines is still read as one initialiser. Only the initialiser
 * is examined: `local t = {}` followed later by `t.f = function() … t … end` is
 * correct code, because by then the declaration has completed.
 * @param {string} file Absolute path, for reporting.
 * @param {string} src File content.
 * @returns {Array<{file: string, line: number, name: string, text: string}>} Findings.
 */
function findSelfCapturingLocals(file, src) {
	const out = [];
	const lines = src.split(/\r?\n/);

	for (let i = 0; i < lines.length; i++) {
		const head = codeOnly(lines[i]);
		// `local function f()` declares f BEFORE its body — that form is the
		// documented way to write a recursive function and is never this bug.
		const m = head.match(/^\s*local\s+([A-Za-z_]\w*)\s*=\s*(.*)$/);
		if (!m) continue;
		const [, name, rest] = m;

		let depth = 0;
		const countDepth = (text) => {
			for (const ch of text) {
				if (ch === '(' || ch === '{' || ch === '[') depth += 1;
				else if (ch === ')' || ch === '}' || ch === ']') depth -= 1;
			}
		};
		countDepth(rest);

		const collected = [rest];
		let j = i;
		// A one-line initialiser that already balances still counts: `local f =
		// function() return f end` is the same bug in a single line.
		while (depth > 0 && j + 1 < lines.length && j - i < 60) {
			j += 1;
			const next = codeOnly(lines[j]);
			collected.push(next);
			countDepth(next);
		}

		const initialiser = collected.join('\n');
		if (!/\bfunction\b/.test(initialiser)) continue;
		// A bare reference to the name being declared — not a field access on
		// something else (`self.task`), and not a longer identifier.
		const reference = new RegExp(`(^|[^\\w.:])${name}(?![\\w])`);
		if (!reference.test(initialiser)) continue;

		out.push({
			file: path.relative(ROOT, file).replace(/\\/g, '/'),
			line: i + 1,
			name,
			text: lines[i].trim().slice(0, 120),
		});
	}
	return out;
}

// ==================================
// ==================================
// ======= 3/ Report ================
// ==================================
// ==================================

const findings = [];
let scanned = 0;
for (const tree of TREES) {
	for (const file of collectLua(tree.dir, [])) {
		scanned += 1;
		findings.push(...findSelfCapturingLocals(file, fs.readFileSync(file, 'utf8')));
	}
}

// A walk that finds no files reports no findings and reads exactly like success.
if (scanned < 100) {
	console.error(`\x1b[31m[ERROR] scanned only ${scanned} Lua file(s) — the walk is broken, not the code.\x1b[0m`);
	process.exit(1);
}

if (findings.length > 0) {
	console.error(
		`\x1b[31m[ERROR] ${findings.length} closure(s) capture a local that does not exist yet.\x1b[0m`
	);
	console.error(
		'  In Lua the scope of `local x = <expr>` starts AFTER the statement, so inside <expr> the\n' +
			'  name is the nil global. hs.task and ShellRunner run callbacks inside a pcall, so the\n' +
			'  resulting "table index is nil" is swallowed and the whole callback body aborts on its\n' +
			'  first line, silently. Split the declaration:\n' +
			'      local task\n' +
			'      task = hs.task.new(cmd, function() if task then pool[task] = nil end end)\n'
	);
	for (const f of findings) console.error(`    ${f.file}:${f.line}  captures "${f.name}"  —  ${f.text}`);
	process.exit(1);
}

console.log(`\x1b[32m[OK] No closure binds a not-yet-declared local (${scanned} Lua file(s)).\x1b[0m`);
