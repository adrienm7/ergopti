// tools/lint/audit-file-headers.cjs

/**
 * ==============================================================================
 * MODULE: File-Path Header Lint
 * DESCRIPTION:
 * Enforces convention 3 (copilot-instructions.md): the first comment line of
 * every source file is its own path. The two in-driver suites
 * (test_file_headers.ahk / .lua) only WARN on a mismatch and only cover the AHK
 * and HS drivers' lib/modules/ui — so stale headers (the static/drivers ->
 * static/ergopti_plus reorg left ``drivers/autohotkey/...`` / ``drivers/_shared/...``
 * prefixes, and some headers never tracked a file's move into a sub-dir) and
 * full-path variants slipped through silently.
 *
 * Canonical form (matches the in-driver tests' ``rel = abs - DRIVER_ROOT``):
 *   - under windows/ , macos/ , linux/  → path relative to that driver root
 *     (e.g. ``infra/window_utils.ahk``, ``ui/menu/init.lua``).
 *   - under _shared/                    → ``_shared/<rest>`` (it is shared by all
 *     drivers, so the header keeps the _shared/ identifier).
 *
 * SAFETY:
 * Only a first comment line that already ends with the file's own basename is
 * treated as a path header and rewritten; anything else is reported as a missing
 * header and never overwritten, so a non-path opening comment is never clobbered.
 *
 * USAGE: node tools/lint/audit-file-headers.cjs [--fix]
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const BASE = path.join(ROOT, 'static', 'ergopti_plus');
const FIX = process.argv.includes('--fix');

// Source trees to validate, and the file extensions that carry a path header.
const TREES = [
	'windows/infra', 'windows/modules', 'windows/ui', 'windows/adapters',
	'macos/infra', 'macos/modules', 'macos/ui', 'macos/adapters',
	'linux/modules', 'linux/adapters', 'linux/infra', 'linux/bin', 'linux/ui',
	// _shared/core (the port specs) and _shared/modules were outside the audit,
	// and had drifted to a repo-relative header (`static/ergopti_plus/_shared/…`)
	// where every other tree under _shared/ uses the BASE-relative form.
	'_shared/lua', '_shared/ui', '_shared/core', '_shared/modules'
];
const EXTS = new Set(['.ahk', '.lua', '.js', '.cjs', '.mjs', '.py', '.sh', '.swift', '.toml']);
const SKIP_DIR = new Set(['tests', 'vendor', '_generated', 'node_modules']);

// Comment marker the fixer emits per extension (Lua uses three dashes per §3).
function markerFor(ext, base) {
	if (ext === '.lua') return '---';
	if (ext === '.ahk') return ';';
	if (ext === '.py' || ext === '.sh' || ext === '.toml') return '#';
	if (ext === '.js' || ext === '.cjs' || ext === '.mjs' || ext === '.swift') return '//';
	// extensionless executables (e.g. linux/bin/ergopti-hotstrings) are shell scripts
	if (ext === '') return '#';
	return null;
}

// Strip a leading comment marker and surrounding whitespace from a line.
function commentBody(line) {
	const m = line.match(/^\s*(;+|#+|\/\/+|-{2,})\s*(.*?)\s*$/);
	return m ? m[2] : null;
}

// Expected header path for an absolute file path, or null when out of scope.
function expectedRel(absPosix) {
	const m = absPosix.replace(/\\/g, '/').match(/static\/ergopti_plus\/(.+)$/);
	if (!m) return null;
	const after = m[1];
	const top = after.split('/')[0];
	if (top === 'windows' || top === 'macos' || top === 'linux') {
		return after.split('/').slice(1).join('/');
	}
	if (top === '_shared') return after;
	return null;
}

function walk(dir, out = []) {
	let entries;
	try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
	for (const e of entries) {
		if (e.isDirectory()) {
			if (!SKIP_DIR.has(e.name) && !e.name.endsWith('.app')) walk(path.join(dir, e.name), out);
		} else if (e.isFile()) {
			const ext = path.extname(e.name);
			// Accept known extensions, plus extensionless files under bin/.
			if (EXTS.has(ext) || (ext === '' && /[/\\]bin[/\\]/.test(path.join(dir, e.name)))) {
				out.push(path.join(dir, e.name));
			}
		}
	}
	return out;
}

const mismatches = [];
const missing = [];
let checked = 0;

for (const tree of TREES) {
	for (const abs of walk(path.join(BASE, tree.replace('/', path.sep)))) {
		const ext = path.extname(abs);
		const base = path.basename(abs);
		const rel = expectedRel(abs);
		if (!rel) continue;
		const marker = markerFor(ext, base);
		if (!marker) continue;

		const buf = fs.readFileSync(abs);
		const hasBom = buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf;
		const text = buf.slice(hasBom ? 3 : 0).toString('utf8');
		const eol = text.includes('\r\n') ? '\r\n' : '\n';
		const lines = text.split(/\r?\n/);

		// The header is line 0 unless line 0 is a shebang or a swift-tools directive.
		let idx = 0;
		if (/^#!/.test(lines[0] || '')) idx = 1;
		else if (/^\/\/\s*swift-tools-version/.test(lines[0] || '')) idx = 1;

		checked++;

		// Resolve the header line and its current path, handling both single-line
		// comments and JSDoc block headers (``/**`` then `` * <path>``).
		let body, fixIdx, rewrite;
		if ((lines[idx] || '').trim() === '/**') {
			const next = lines[idx + 1] || '';
			const bm = next.match(/^(\s*\*\s*)(.*?)\s*$/);
			if (bm && bm[2].endsWith(base)) {
				body = bm[2];
				fixIdx = idx + 1;
				rewrite = (p) => `${bm[1]}${p}`;
			} else {
				body = null; // block opens but its first line is not a path
			}
		} else {
			const cb = commentBody(lines[idx] || '');
			if (cb !== null && cb.endsWith(base)) {
				body = cb;
				fixIdx = idx;
				rewrite = (p) => `${marker} ${p}`;
			} else {
				body = null;
			}
		}

		if (body === null) {
			missing.push({ abs: path.relative(ROOT, abs).replace(/\\/g, '/'), line: lines[idx] || '' });
			continue;
		}
		if (body === rel) continue; // already canonical

		mismatches.push({
			abs: path.relative(ROOT, abs).replace(/\\/g, '/'),
			actual: body, expected: rel
		});

		if (FIX) {
			lines[fixIdx] = rewrite(rel);
			const outBuf = Buffer.concat([
				hasBom ? Buffer.from([0xef, 0xbb, 0xbf]) : Buffer.alloc(0),
				Buffer.from(lines.join(eol), 'utf8')
			]);
			fs.writeFileSync(abs, outBuf);
		}
	}
}

for (const m of mismatches) {
	console.log(`${FIX ? 'FIXED' : 'STALE'}  ${m.abs}\n   header: ${m.actual}\n   expect: ${m.expected}`);
}
for (const m of missing) {
	console.log(`MISSING ${m.abs}\n   first comment is not a path header: ${m.line}`);
}

console.log(`\nChecked ${checked} file(s): ${mismatches.length} ${FIX ? 'fixed' : 'stale'}, ${missing.length} missing/unrecognized.`);

if (!FIX && (mismatches.length > 0 || missing.length > 0)) {
	console.error('\x1b[31m[ERROR] File-path headers diverge from convention 3. Run: node tools/lint/audit-file-headers.cjs --fix\x1b[0m');
	process.exit(1);
}
if (mismatches.length === 0 && missing.length === 0) {
	console.log('\x1b[32m[OK] Every source file header matches its path (convention 3).\x1b[0m');
}
