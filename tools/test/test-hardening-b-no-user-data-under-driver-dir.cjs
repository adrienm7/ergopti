// tools/test/test-hardening-b-no-user-data-under-driver-dir.cjs

/**
 * ==============================================================================
 * MODULE: No User Data Under The Driver Folder (hardening-b-installed-layout)
 * DESCRIPTION:
 * Installed, the macOS driver runs from inside the signed application bundle
 * (hs.configdir is Contents/Resources/static/ergopti_plus/macos) and the Linux
 * driver from its install prefix. Both are the package: read-only, replaced by
 * every update. A path a production module builds from the driver folder must
 * therefore name something the package ships; the user's files belong in the
 * configuration folder (infra/config_paths), caches in the user's cache folder.
 *
 * ROOT CAUSE ENCODED (incident of 2026-09-30):
 * The macOS apps dashboard read its category overrides from
 * hs.configdir .. "/data" .. "/app_categories.json": inside the bundle, a file
 * nothing ships. Every read failed and « Temps sur les applications » showed
 * nothing (982f2b801). The same scan found the TOML hotstring cache created
 * inside the bundle at every boot, and four gesture actions opening
 * config.toml, personal_info.toml and the personal shortcuts from there.
 *
 * FEATURES & RATIONALE:
 * 1. Anchors: hs.configdir, Paths.shared(...), Paths.shared_root() and the
 *    Linux Paths.driver_root(). The literal a path appends to an anchor, also
 *    through one `local NAME = <anchor> .. "x"` alias, must resolve to a file or
 *    folder the repository tracks under that root: shipped assets pass, user
 *    data fails, whatever the exact spelling of the concatenation.
 * 2. Comments are stripped first, so prose naming a path cannot fail or satisfy
 *    the scan; floors on the number of anchors keep it from passing vacuously.
 * 3. An allowlist entry names one exact source line and why it is not a read or
 *    a write of user data; an entry whose line is gone fails, so it cannot rot.
 * 4. A self-check runs the pre-fix shape of the incident through the scanner.
 * 5. `--rev <commit>` scans a committed revision straight from Git, to prove the
 *    guard red on the revision before a fix without checking anything out.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const {
	generatedNativeRecipe,
	isGeneratedLinuxAsset
} = require('./generated-linux-native-artifacts.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const revArg = process.argv.indexOf('--rev');
const REV = revArg > 0 ? process.argv[revArg + 1] : null;
// The package root: the macOS bundle ships Contents/Resources/static, whose
// ergopti_plus/<driver> folder is hs.configdir.
const STATIC = 'static';
const SP = 'static/ergopti_plus';

// Sites that build a path from a driver anchor without reading or writing
// user data there. Each entry must still match its exact line.
const ALLOWED = [
	{
		file: 'macos/ui/menu/init.lua',
		line: '{ (hs.configdir or ".") .. "/cache" },',
		why:
			'a watcher exclusion: a source checkout may still hold the cache older builds wrote ' +
			'there, and its changes must not reload the driver; nothing reads or writes it'
	}
];

/** Every tracked path under static/, as a set of files and folders. */
function trackedTree() {
	const listing = REV
		? execFileSync('git', ['ls-tree', '-r', '--name-only', REV, '--', STATIC], {
				cwd: ROOT,
				encoding: 'utf8',
				maxBuffer: 64 * 1024 * 1024
			})
		: execFileSync('git', ['ls-files', '--', STATIC], {
				cwd: ROOT,
				encoding: 'utf8',
				maxBuffer: 64 * 1024 * 1024
			});
	const entries = new Set();
	for (const file of listing.split('\n').filter(Boolean)) {
		const rel = file.slice(STATIC.length + 1);
		entries.add(rel);
		const parts = rel.split('/');
		for (let i = 1; i < parts.length; i++) entries.add(parts.slice(0, i).join('/'));
	}
	return entries;
}

/**
 * Production Lua of one driver, tests, vendor code and launcher sources
 * excluded: [{ rel, content }] with rel relative to static/ergopti_plus.
 */
function driverSources(driver) {
	const keep = (rel) => rel.endsWith('.lua') && !/\/(tests|vendor|launcher)\//.test(`/${rel}`);
	if (!REV) {
		const out = [];
		const walk = (dir) => {
			for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
				const full = path.join(dir, entry.name);
				if (entry.isDirectory()) walk(full);
				else {
					const rel = path.relative(path.join(ROOT, SP), full).replace(/\\/g, '/');
					if (keep(rel)) out.push({ rel, content: fs.readFileSync(full, 'utf8') });
				}
			}
		};
		walk(path.join(ROOT, SP, driver));
		return out;
	}
	const names = execFileSync(
		'git',
		['ls-tree', '-r', '--name-only', REV, '--', `${SP}/${driver}`],
		{
			cwd: ROOT,
			encoding: 'utf8'
		}
	)
		.split('\n')
		.filter(Boolean)
		.map((file) => file.slice(SP.length + 1))
		.filter(keep);
	return names.map((rel) => ({
		rel,
		content: execFileSync('git', ['show', `${REV}:${SP}/${rel}`], {
			cwd: ROOT,
			encoding: 'utf8',
			maxBuffer: 64 * 1024 * 1024
		})
	}));
}

/** Blanks Lua comments, keeping line numbers and string literals. */
function stripLuaComments(src) {
	let out = '';
	let i = 0;
	while (i < src.length) {
		const c = src[i];
		if (c === '"' || c === "'") {
			let j = i + 1;
			while (j < src.length && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1;
			out += src.slice(i, j + 1);
			i = j + 1;
		} else if (src.startsWith('--', i)) {
			const block = src.slice(i).match(/^--\[(=*)\[/);
			let end;
			if (block) {
				const close = src.indexOf(`]${block[1]}]`, i);
				end = close < 0 ? src.length : close + block[1].length + 2;
			} else {
				end = src.indexOf('\n', i);
				if (end < 0) end = src.length;
			}
			out += src.slice(i, end).replace(/[^\n]/g, ' ');
			i = end;
		} else {
			out += c;
			i++;
		}
	}
	return out;
}

// An anchor expression and the tree root its literals are relative to.
const ANCHORS = [
	{
		re: /\(\s*hs\.configdir\s+or\s+"[^"]*"\s*\)|hs\.configdir/g,
		root: (d) => `ergopti_plus/${d}`,
		name: 'hs.configdir'
	},
	{
		re: /Paths\.driver_root\(\)|require\("infra\.paths"\)\.driver_root\(\)/g,
		root: (d) => `ergopti_plus/${d}`,
		name: 'driver_root()'
	},
	{ re: /Paths\.shared_root\(\)/g, root: () => 'ergopti_plus/_shared', name: 'shared_root()' }
];

/**
 * The literals concatenated right after position `at`, joined: `.. "a" .. "b"`.
 * Returns null when the next operand is not a literal (a runtime name).
 */
function literalTail(code, at) {
	let rest = code.slice(at);
	let joined = '';
	let matched = false;
	for (;;) {
		const m = rest.match(/^\s*\.\.\s*(["'])([^"'\n]*)\1/);
		if (!m) break;
		joined += m[2];
		rest = rest.slice(m[0].length);
		matched = true;
	}
	return matched ? joined : null;
}

/** Normalises `root` + `tail` into a tree-relative path, or null when it escapes. */
function resolve(root, tail) {
	const parts = [];
	for (const part of `${root}/${tail}`.split('/')) {
		if (part === '' || part === '.') continue;
		if (part === '..') {
			if (parts.length === 0) return null;
			parts.pop();
		} else parts.push(part);
	}
	return parts.join('/');
}

/**
 * Every path one source builds from a driver anchor: { line, text, target }.
 * @param {string} code Comment-free source.
 * @param {string} driver 'macos' or 'linux'.
 */
function anchoredPaths(code, driver) {
	const found = [];
	const lineOf = (index) => code.slice(0, index).split('\n').length;
	const lineText = (index) => code.split('\n')[lineOf(index) - 1].trim();
	const aliases = new Map();
	for (const anchor of ANCHORS) {
		for (const m of code.matchAll(anchor.re)) {
			const tail = literalTail(code, m.index + m[0].length);
			if (tail === null) continue;
			const target = resolve(anchor.root(driver), tail);
			found.push({ line: lineOf(m.index), text: lineText(m.index), target, anchor: anchor.name });
			const alias = code
				.slice(code.lastIndexOf('\n', m.index) + 1, m.index)
				.match(/local\s+([A-Za-z_]\w*)\s*=\s*$/);
			if (alias) aliases.set(alias[1], target);
		}
	}
	for (const m of code.matchAll(/Paths\.shared\(\s*(["'])([^"'\n]*)\1\s*\)/g)) {
		found.push({
			line: lineOf(m.index),
			text: lineText(m.index),
			target: resolve('ergopti_plus/_shared', m[2]),
			anchor: 'Paths.shared()'
		});
	}
	for (const [name, base] of aliases) {
		const use = new RegExp(`(?<![\\w.])${name}(?![\\w])`, 'g');
		for (const m of code.matchAll(use)) {
			const tail = literalTail(code, m.index + m[0].length);
			if (tail === null || base === null) continue;
			found.push({
				line: lineOf(m.index),
				text: lineText(m.index),
				target: resolve(base, tail),
				anchor: `${name} (alias)`
			});
		}
	}
	return found;
}

function isAllowed(file, text) {
	return ALLOWED.some((entry) => entry.file === file && text.includes(entry.line));
}

const tree = trackedTree();
// Native generated assets have their own complete tracked source recipe; the
// tracked tree remains untouched and historical revisions keep their own recipe.
const generatedNative = generatedNativeRecipe(ROOT, REV).artifacts;
const errors = [];
const counts = { macos: 0, linux: 0 };
const allowedSeen = new Set();

// ── Self-check: the incident's pre-fix shape is caught, a shipped asset is not ──
{
	const fixture = [
		'local CONFIG_DIR      = hs.configdir .. "/data"',
		'local CATEGORIES_FILE = CONFIG_DIR .. "/app_categories.json"',
		'-- hs.configdir .. "/ignored_in_a_comment.json"',
		'local logo = hs.configdir .. "/../../img/logo/"',
		'local ok = Paths.shared("modules/hotstrings/_index.toml")'
	].join('\n');
	const shipped = new Set([
		'ergopti_plus/macos/data',
		'img/logo',
		'ergopti_plus/_shared/modules/hotstrings/_index.toml'
	]);
	const bad = anchoredPaths(stripLuaComments(fixture), 'macos').filter(
		(p) => p.target === null || !shipped.has(p.target)
	);
	const got = bad.map((p) => p.target).join(', ');
	const want = 'ergopti_plus/macos/data/app_categories.json';
	if (got !== want) {
		errors.push(`self-check: the scanner flagged [${got}], expected [${want}]`);
	}
}

for (const driver of ['macos', 'linux']) {
	for (const { rel, content } of driverSources(driver)) {
		const code = stripLuaComments(content);
		for (const p of anchoredPaths(code, driver)) {
			counts[driver]++;
			if (p.target !== null && tree.has(p.target)) continue;
			if (driver === 'linux' && isGeneratedLinuxAsset(p.target, generatedNative)) continue;
			if (isAllowed(rel, p.text)) {
				allowedSeen.add(`${rel}|${p.text}`);
				continue;
			}
			errors.push(
				`${rel}:${p.line} builds ${p.target === null ? 'a path above the package' : `'${p.target}'`} ` +
					`from ${p.anchor}, which the package does not ship: \`${p.text}\`. The driver folder is ` +
					'read-only once installed; keep user data in the configuration folder (infra/config_paths) ' +
					"and caches in the user's cache folder."
			);
		}
	}
}

for (const entry of ALLOWED) {
	const seen = [...allowedSeen].some((key) => key.startsWith(`${entry.file}|`));
	if (!seen) errors.push(`allowlist entry for ${entry.file} no longer matches any line: remove it`);
}
if (counts.macos < 40)
	errors.push(`only ${counts.macos} anchored macOS path(s) found: the scan lost its anchors`);
if (counts.linux < 10)
	errors.push(`only ${counts.linux} anchored Linux path(s) found: the scan lost its anchors`);

if (errors.length > 0) {
	for (const e of errors) console.error(`  FAIL  ${e}`);
	console.error(`\n[hardening-b-no-user-data-under-driver-dir] ${errors.length} problem(s).`);
	process.exit(1);
}
console.log(
	`[hardening-b-no-user-data-under-driver-dir] ${counts.macos} macOS and ${counts.linux} Linux ` +
		'anchored path(s): every one names a shipped file or folder.'
);
