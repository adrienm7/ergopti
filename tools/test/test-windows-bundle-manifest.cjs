// tools/test/test-windows-bundle-manifest.cjs

/**
 * ==============================================================================
 * MODULE: Windows Bundle Completeness Gate
 * DESCRIPTION:
 * The compiled ErgoptiPlus.exe reads its data files from the zip that
 * tools/build/build_static_bundle.py assembles from windows_bundle_manifest.json,
 * while a source run reads the checkout. A file the manifest leaves out therefore
 * breaks only the shipped exe, and no source-run test can see it. This gate asks
 * the builder for the exact selection CI embeds and fails when a path the Windows
 * sources, web pages or data files reference is not shipped, or when a group that
 * never runs on Windows (test corpora, Lua, documentation, developer scripts, test
 * vectors, machine-specific caches, compile-time sources) is.
 *
 * FEATURES & RATIONALE:
 * 1. The builder's selection: `build_static_bundle.py --list` is the one
 *    implementation of the manifest's globs, so this gate checks what ships.
 * 2. Independent oracle: references come from the sources, never from the
 *    manifest: comment-stripped AutoHotkey literals naming a file, concatenations
 *    anchored on a runtime root global (_SharedDir, _StaticDir, _VendorDir...),
 *    the src/href/import/url() closure of every page, and file names in shipped
 *    JSON/TOML data.
 * 3. Dynamic paths: a concatenation with a runtime part becomes a pattern, and
 *    every tracked file it can reach ships (locales, flags, hotstring packs,
 *    dashboards, LLM data read by file name).
 * 4. Can fail: every check runs again on selections with one needed file removed
 *    or one forbidden file added, and must report each of them.
 * ==============================================================================
 */

'use strict';

// The release selection gate also proves every native flag's authoritative pixels.
require('./test-native-menu-flags.cjs');

const fs = require('fs');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { scriptTokens } = require('../lib/script-source.cjs');
const { SHARED_REL } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BUILDER = path.join(ROOT, 'tools', 'build', 'build_static_bundle.py');
const MANIFEST = path.join(ROOT, 'tools', 'build', 'windows_bundle_manifest.json');
const REQUIRED_RUNTIME_ASSETS = JSON.parse(fs.readFileSync(MANIFEST, 'utf8')).required;
const DRIVER_REL = 'static/ergopti_plus/windows';
const ENTRY_REL = `${DRIVER_REL}/ErgoptiPlus.ahk`;
const VENDOR_REL = `${DRIVER_REL}/vendor`;
const LAYOUT_DEFAULTS_REL = `${SHARED_REL}/modules/layouts/defaults.json`;

// python3 first (ubuntu CI), then the Windows launcher and python.
const PY_CANDIDATES = [
	['python3', []],
	['py', ['-3']],
	['python', []]
];

// File types a runtime path can name. A token must end with one to count.
const PATH_EXTENSIONS =
	'json|toml|html?|js|css|sql|png|bmp|ico|jpe?g|svg|dll|ps1|keylayout|ahk|lua|md|py|sh|txt|tsv|atom';
const PATH_TOKEN = new RegExp(
	`(^|[\\\\/])?((?:[A-Za-z0-9_.-]+[\\\\/])*[A-Za-z0-9_-][A-Za-z0-9_.-]*\\.(?:${PATH_EXTENSIONS}))(?![A-Za-z0-9_])`,
	'g'
);

// Licence notices ship even though they are Markdown.
const LICENSE_NOTICES = new Set([`${SHARED_REL}/ui/vendor/LICENSES.md`]);

// Categories no Windows code can need at run time, judged by what the file is,
// not by what the manifest says. A reference into one of them is itself a failure.
const NEVER_RUNTIME = [
	['shared test corpora', (arc) => arc.startsWith(`${SHARED_REL}/tests/`)],
	['Python driver runtime', (arc) => arc.startsWith(`${SHARED_REL}/python/`)],
	['native compile sources', (arc) => arc.startsWith(`${SHARED_REL}/native/`)],
	['Go compile sources', (arc) => arc.startsWith(`${SHARED_REL}/go/`)],
	[
		'macOS native Ollama catalogue',
		(arc) =>
			/^managed_ollama_(?:runtime|release)\.json$/.test(
				arc.slice(`${SHARED_REL}/modules/llm/`.length)
			) && arc.startsWith(`${SHARED_REL}/modules/llm/`)
	],
	[
		'macOS Python bootstrap catalogue',
		(arc) => arc === `${SHARED_REL}/modules/llm/managed_python_release.json`
	],
	['Lua sources', (arc) => arc.startsWith(`${SHARED_REL}/lua/`) || arc.endsWith('.lua')],
	['documentation', (arc) => arc.endsWith('.md') && !LICENSE_NOTICES.has(arc)],
	['developer scripts', (arc) => /\.(?:py|sh)$/.test(arc)],
	['test vectors', (arc) => /(?:^|\/)(?:test_vectors|[^/]*_vectors)\.(?:json|toml)$/.test(arc)],
	['JS specifications', (arc) => arc.endsWith('.spec.js')]
];

// Files that must never ship whatever the manifest says: state a development run
// writes next to the sources, and libraries Ahk2Exe already compiled in.
const NEVER_SHIPPED = [
	['machine-specific stub', (arc) => /(?:^|\/)(?:personal_shortcuts\.ahk|paths\.toml)$/.test(arc)],
	['runtime cache', (arc) => /(?:^|\/)prefetch[^/]*\.json$/.test(arc) || arc.endsWith('.tsv')],
	[
		'compile-time library',
		(arc) => /^vendor\/[^/]*\.ahk$/.test(arc) && arc !== 'vendor/ergopti_user_hotstrings.ahk'
	]
];

const errors = [];

/**
 * Returns the category name when `arc` can never be a Windows runtime read.
 * @param {string} arc - Path inside the bundle.
 * @returns {string|null} Category, or null.
 */
function neverRuntime(arc) {
	const hit = NEVER_RUNTIME.find(([, test]) => test(arc));
	return hit ? hit[0] : null;
}

/**
 * Normalises a forward-slash path: drops empty and "." segments, applies "..".
 * @param {string} p - Path to normalise.
 * @returns {string|null} The path, or null when ".." climbs above its start.
 */
function normalise(p) {
	const out = [];
	for (const seg of p.split('/')) {
		if (seg === '' || seg === '.') continue;
		if (seg === '..') {
			if (out.length === 0) return null;
			out.pop();
		} else out.push(seg);
	}
	return out.join('/');
}

/**
 * Escapes a string for a regular expression.
 * @param {string} s - Text.
 * @returns {string} Escaped text.
 */
function escapeRegex(s) {
	return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// ========================================
// ========================================
// ======= 1/ The Shipped Selection =======
// ========================================
// ========================================

let python = null;

/**
 * Runs the builder with the first interpreter that answers --version (the
 * Windows Store python3 shim exists but refuses to run anything).
 * @param {string[]} args - Builder arguments.
 * @returns {import('child_process').SpawnSyncReturns<string>} The finished run.
 */
function runBuilder(args) {
	python =
		python ||
		PY_CANDIDATES.find(
			([command, prefix]) =>
				spawnSync(command, [...prefix, '--version'], { encoding: 'utf8' }).status === 0
		);
	if (!python) {
		throw new Error(
			`no Python interpreter found (tried ${PY_CANDIDATES.map((c) => c[0]).join(', ')})`
		);
	}
	const [command, prefix] = python;
	return spawnSync(command, [...prefix, BUILDER, ...args], {
		cwd: ROOT,
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024
	});
}

/**
 * The selection CI embeds, from the builder's --list mode.
 * @returns {{files: {source: string, arcname: string}[], excluded: Object<string, number>}}
 */
function builderSelection() {
	const run = runBuilder(['--list']);
	if (run.status !== 0) {
		throw new Error(
			`build_static_bundle.py --list exited ${run.status}: ${(run.stderr || '').trim()}`
		);
	}
	return JSON.parse(run.stdout);
}

/**
 * Runs the builder on fixture repositories: the glob semantics this gate relies
 * on, and a refusal for each manifest state that must stop a release build.
 * @returns {string[]} Problems.
 */
function builderContract() {
	const problems = [];
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-bundle-'));
	const write = (rel, text) => {
		fs.mkdirSync(path.dirname(path.join(fixture, rel)), { recursive: true });
		fs.writeFileSync(path.join(fixture, rel), text);
	};
	const manifestWith = (overrides) => ({
		schema_version: 1,
		include: [{ source: 'tree', dest: 'static/tree', why: 'fixture' }],
		exclude: [
			{ name: 'docs', globs: ['**/*.md'], except: ['tree/keep/NOTICE.md'], why: 'fixture' },
			{ name: 'top', globs: ['tree/*.tmp'], why: 'fixture' }
		],
		not_shipped: [],
		required: [{ source: 'tree/a.json', dest: 'static/tree/a.json' }],
		...overrides
	});
	try {
		for (const rel of [
			'tree/a.json',
			'tree/README.md',
			'tree/deep/er/GUIDE.md',
			'tree/keep/NOTICE.md',
			'tree/x.tmp',
			'tree/deep/y.tmp'
		])
			write(rel, '{}');
		const list = (manifest) => {
			write('tools/build/windows_bundle_manifest.json', JSON.stringify(manifest));
			return runBuilder(['--repo-root', fixture, '--list']);
		};
		const ok = list(manifestWith({}));
		const shippedFixture = ok.status === 0 ? JSON.parse(ok.stdout).files.map((f) => f.arcname) : [];
		const expected = ['static/tree/a.json', 'static/tree/deep/y.tmp', 'static/tree/keep/NOTICE.md'];
		if (JSON.stringify(shippedFixture.sort()) !== JSON.stringify(expected))
			problems.push(
				`builder glob semantics: expected ${expected.join(', ')}, got ${shippedFixture.join(', ') || ok.stderr}`
			);
		write('tree/a.json', Buffer.from([0, 255, 13, 10, 1]));
		const archivePath = path.join(fixture, 'build/static_bundle.zip');
		const built = runBuilder(['--repo-root', fixture, '--output', archivePath]);
		assert.equal(built.status, 0, built.stdout + built.stderr);
		const inventoryBytes = fs.readFileSync(path.join(fixture, 'build/bundle_inventory.ahk'));
		assert.deepEqual([...inventoryBytes.subarray(0, 3)], [239, 187, 191]);
		const inventorySource = inventoryBytes.toString('utf8');
		assert.equal(inventorySource.includes('\r'), false, 'generated AHK requires LF');
		const rows = [
			...inventorySource.matchAll(/^\s*\["([^"]+)", (\d+), "([0-9a-f]{64})"\],?$/gm)
		].map((match) => [match[1], Number(match[2]), match[3]]);
		assert.deepEqual(
			rows.map((row) => row[0]).sort(),
			expected,
			'the inventory must contain every selected file and no excluded file'
		);
		const zipContents = spawnSync(
			python[0],
			[
				...python[1],
				'-c',
				'import base64,json,sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); print(json.dumps({n:base64.b64encode(z.read(n)).decode() for n in z.namelist()}))',
				archivePath
			],
			{ encoding: 'utf8' }
		);
		assert.equal(zipContents.status, 0, zipContents.stderr);
		const archived = JSON.parse(zipContents.stdout);
		assert.deepEqual(Object.keys(archived).sort(), expected);
		for (const row of rows) {
			const bytes = Buffer.from(archived[row[0]], 'base64');
			assert.equal(bytes.length, row[1]);
			assert.equal(
				crypto.createHash('sha256').update(bytes).digest('hex'),
				row[2],
				'the compiled digest must describe the exact ZIP bytes'
			);
		}
		for (const [label, manifest, message] of [
			[
				'a missing include source',
				manifestWith({ include: [{ source: 'gone', dest: 'static/gone' }] }),
				/does not exist/
			],
			[
				'a missing required asset',
				manifestWith({ required: [{ source: 'tree/none.json', dest: 'static/tree/none.json' }] }),
				/required asset/
			],
			[
				'an excluded required asset',
				manifestWith({
					exclude: [{ name: 'json', globs: ['**/*.json'], why: 'fixture' }]
				}),
				/is not shipped at/
			],
			['an unknown manifest key', manifestWith({ extra: true }), /unknown key/],
			[
				'a shipped not_shipped path',
				manifestWith({ not_shipped: [{ path: 'tree/deep', why: 'fixture' }] }),
				/not_shipped/
			]
		]) {
			const run = list(manifest);
			if (run.status === 0 || !message.test(run.stderr || ''))
				problems.push(
					`builder accepts ${label} (exit ${run.status}): ${(run.stderr || '').trim()}`
				);
		}
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
	return problems;
}

// ==============================================
// ==============================================
// ======= 2/ The Trees the Runtime Reads =======
// ==============================================
// ==============================================

// The audit runs once per self-check mutation; each file is read once.
const readCache = new Map();

/**
 * Reads a repository file.
 * @param {string} rel - Repo-relative path.
 * @returns {string} Content without a BOM.
 */
function read(rel) {
	if (!readCache.has(rel))
		readCache.set(rel, fs.readFileSync(path.join(ROOT, rel), 'utf8').replace(/^\uFEFF/, ''));
	return readCache.get(rel);
}

/**
 * Lists tracked files under repo-relative prefixes.
 * @param {string[]} prefixes - Paths to list.
 * @returns {string[]} Repo-relative paths.
 */
function tracked(prefixes) {
	const run = spawnSync('git', ['ls-files', '-z', '--', ...prefixes], {
		cwd: ROOT,
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024
	});
	if (run.status !== 0) throw new Error(`git ls-files failed: ${(run.stderr || '').trim()}`);
	return run.stdout.split('\0').filter(Boolean);
}

/**
 * The bundle path a tracked file would have: the compiled driver resolves
 * _VendorDir to <bundle>\vendor and _StaticDir to <bundle>\static, and a source
 * run resolves them to windows\vendor and the checkout's static folder.
 * @param {string} rel - Repo-relative path.
 * @returns {string} Path inside the bundle.
 */
function arcnameOf(rel) {
	return rel.startsWith(`${VENDOR_REL}/`) ? `vendor/${rel.slice(VENDOR_REL.length + 1)}` : rel;
}

const entry = read(ENTRY_REL);
for (const [label, pattern] of [
	['compiled _StaticDir', /_StaticDir := _BundleDir \. "\\static"/],
	['compiled _VendorDir', /_VendorDir := _BundleDir \. "\\vendor"/],
	['source-run _VendorDir', /_VendorDir := A_ScriptDir \. "\\vendor"/]
]) {
	if (!pattern.test(entry)) {
		errors.push(`${ENTRY_REL} no longer assigns the ${label} this gate maps bundle paths with.`);
	}
}

// Every tree a runtime root global reaches: _SharedDir, _ExtensionsDir, the
// registry folder, _StaticDir's img/ (tray icons, flags, the onboarding assets
// host) and favicon.ico, _VendorDir, and _DriverDir's generated files. Chains
// that reach anywhere else are reported below instead of passing silently.
const registryFolder = JSON.parse(read(LAYOUT_DEFAULTS_REL)).registry.folder;
const UNIVERSE_PREFIXES = [
	SHARED_REL,
	'static/ergopti_plus/extensions',
	registryFolder,
	'static/img',
	'static/favicon.ico',
	VENDOR_REL,
	`${DRIVER_REL}/_generated`
];
const universe = new Map(tracked(UNIVERSE_PREFIXES).map((rel) => [arcnameOf(rel), rel]));
const universeArcs = [...universe.keys()];

// =================================================
// =================================================
// ======= 3/ References From the AutoHotkey =======
// =================================================
// =================================================

/**
 * Walks the runtime AutoHotkey sources (everything the exe compiles in).
 * @returns {string[]} Repo-relative paths.
 */
function runtimeAhkFiles() {
	return tracked([DRIVER_REL]).filter(
		(rel) => rel.endsWith('.ahk') && !rel.startsWith(`${DRIVER_REL}/tests/`)
	);
}

/**
 * Skips a balanced bracket group starting at tokens[i].
 * @param {object[]} tokens - Script tokens.
 * @param {number} i - Index of the opening bracket.
 * @returns {number} Index after the closing bracket.
 */
function skipGroup(tokens, i) {
	const open = tokens[i].value;
	const close = open === '(' ? ')' : ']';
	let depth = 0;
	for (; i < tokens.length; i++) {
		if (tokens[i].kind !== 'symbol') continue;
		if (tokens[i].value === open) depth++;
		else if (tokens[i].value === close && --depth === 0) return i + 1;
	}
	return i;
}

/**
 * Decodes the actual values of AHK string spans for filesystem classification.
 * The shared scanner preserves literal boundaries but strips the backtick from
 * escape pairs; treating a newline reuse-key separator as "n" invents a path.
 * @param {string} source - AutoHotkey source.
 * @returns {object[]} Code tokens with a decoded pathValue on string spans.
 */
function ahkPathTokens(source) {
	const controls = { a: '\x07', b: '\b', f: '\f', n: '\n', r: '\r', t: '\t', v: '\v' };
	return scriptTokens(source, '.ahk').map((token) => {
		if (token.kind !== 'string') return token;
		const raw = source.slice(token.start + 1, token.end - 1);
		let value = '';
		for (let at = 0; at < raw.length; at++) {
			if (raw[at] === '`' && at + 1 < raw.length) {
				const escaped = raw[++at];
				value += Object.hasOwn(controls, escaped) ? controls[escaped] : escaped;
			} else value += raw[at];
		}
		return { ...token, pathValue: value };
	});
}

/**
 * Extracts the AutoHotkey references.
 * @returns {{literals: object[], chains: object[]}} Path tokens found in string
 *   literals, and concatenations anchored on a runtime root global.
 */
function ahkReferences() {
	const files = runtimeAhkFiles();
	const sources = files.map((rel) => ({ rel, text: read(rel) }));
	const tokenised = sources.map(({ rel, text }) => ({
		rel,
		text,
		tokens: ahkPathTokens(text)
	}));

	// Globals bound to one string literal resolve like the literal.
	const constants = new Map();
	for (const { tokens } of tokenised) {
		for (let i = 0; i + 3 < tokens.length; i++) {
			if (
				tokens[i].value === 'global' &&
				tokens[i + 1].kind === 'identifier' &&
				tokens[i + 2].value === ':=' &&
				tokens[i + 3].kind === 'string' &&
				!(tokens[i + 4] && tokens[i + 4].value === '.')
			) {
				constants.set(tokens[i + 1].value, tokens[i + 3].pathValue);
			}
		}
	}

	// Root globals: _BundleDir and the two directories the compiled entry assigns
	// from it, then every global derived from a root and one literal (_SharedDir,
	// _ExtensionsDir, _LogoDir...).
	const roots = new Map([
		['_BundleDir', ''],
		['_StaticDir', 'static'],
		['_VendorDir', 'vendor']
	]);
	for (let grew = true; grew; ) {
		grew = false;
		for (const { tokens } of tokenised) {
			for (let i = 0; i + 5 < tokens.length; i++) {
				const [g, name, assign, root, dot, lit] = tokens.slice(i, i + 6);
				if (
					g.value === 'global' &&
					name.kind === 'identifier' &&
					assign.value === ':=' &&
					roots.has(root.value) &&
					dot.value === '.' &&
					lit.kind === 'string' &&
					!roots.has(name.value)
				) {
					const next = tokens[i + 6];
					if (next && next.value === '.') continue;
					if (/[\x00-\x1f]/.test(lit.pathValue)) continue;
					const joined = normalise(`${roots.get(root.value)}/${lit.pathValue.replace(/\\/g, '/')}`);
					if (joined !== null) {
						roots.set(name.value, joined);
						grew = true;
					}
				}
			}
		}
	}

	// Runtime data a dynamic operand is known to hold.
	const knownOperands = [[/LayoutRegistry_Settings\(\)\["folder"\]/, registryFolder]];

	const literals = [];
	const chains = [];
	for (const { rel, text, tokens } of tokenised) {
		const lineStarts = [0];
		for (let k = text.indexOf('\n'); k >= 0; k = text.indexOf('\n', k + 1)) lineStarts.push(k + 1);
		const lineOf = (offset) => lineStarts.filter((start) => start <= offset).length;
		// Variables this file lists as a directory: `Loop Files Var ...` and
		// `FSListDirectory[Strict](Var ...)`. Every file under a listed tree matters.
		const listed = new Set();
		for (let i = 0; i + 2 < tokens.length; i++) {
			const a = tokens[i];
			const b = tokens[i + 1];
			if (/^loop$/i.test(a.value) && /^files$/i.test(b.value)) {
				const arg = tokens[i + 2].value === ',' ? tokens[i + 3] : tokens[i + 2];
				if (arg && arg.kind === 'identifier') listed.add(arg.value);
			} else if (/^FSListDirectory(?:Strict)?$/.test(a.value) && b.value === '(') {
				if (tokens[i + 2].kind === 'identifier') listed.add(tokens[i + 2].value);
			}
		}
		for (const token of tokens) {
			if (token.kind !== 'string') continue;
			// A literal with whitespace is a message that mentions a file; one
			// without is a path or a path fragment.
			const prose = /\s/.test(token.value);
			for (const m of token.value.matchAll(PATH_TOKEN)) {
				literals.push({
					where: `${rel}:${lineOf(token.start)}`,
					token: m[2].replace(/\\/g, '/'),
					prose
				});
			}
		}
		for (let i = 0; i < tokens.length; i++) {
			const t = tokens[i];
			if (t.kind !== 'identifier' || !roots.has(t.value)) continue;
			if (i > 0 && tokens[i - 1].value === '.' && !/\s/.test(text[tokens[i - 1].start - 1]))
				continue;
			const assignedTo =
				i > 1 && tokens[i - 1].value === ':=' && tokens[i - 2].kind === 'identifier'
					? tokens[i - 2].value
					: null;
			const definesRoot = assignedTo !== null && roots.has(assignedTo);
			const parts = [];
			let j = i + 1;
			// A concatenation dot has whitespace before it; member access does not.
			while (
				j + 1 < tokens.length &&
				tokens[j].value === '.' &&
				/\s/.test(text[tokens[j].start - 1] || '')
			) {
				const op = tokens[j + 1];
				let end;
				if (op.kind === 'string') {
					parts.push({ lit: op.pathValue });
					j += 2;
					continue;
				}
				if (op.kind === 'identifier') {
					end = j + 2;
					for (;;) {
						const nt = tokens[end];
						if (!nt) break;
						if (nt.value === '(' || nt.value === '[') end = skipGroup(tokens, end);
						else if (nt.value === '.' && !/\s/.test(text[nt.start - 1]) && tokens[end + 1])
							end += 2;
						else break;
					}
				} else if (op.value === '(') end = skipGroup(tokens, j + 1);
				else break;
				const slice = text.slice(op.start, tokens[end - 1].end);
				const known = knownOperands.find(([re]) => re.test(slice));
				if (known) parts.push({ lit: known[1] });
				else if (op.kind === 'identifier' && end === j + 2 && constants.has(op.value))
					parts.push({ lit: constants.get(op.value) });
				else parts.push({ dyn: slice });
				j = end;
			}
			if (parts.length === 0) continue;
			chains.push({
				where: `${rel}:${lineOf(t.start)}`,
				root: t.value,
				base: roots.get(t.value),
				parts,
				definesRoot,
				listed: assignedTo !== null && listed.has(assignedTo)
			});
		}
	}
	return { literals, chains, roots };
}

// ===========================================================
// ===========================================================
// ======= 4/ References From Web Pages and Data Files =======
// ===========================================================
// ===========================================================

const PAGE_REF_PATTERNS = {
	'.html': [/\b(?:src|href)\s*=\s*["']([^"']+)["']/g],
	'.js': [
		/\bimport\s+(?:[^'";]*?\s+from\s+)?["'](\.{0,2}\/[^"']+)["']/g,
		/\bimport\(\s*["'](\.{0,2}\/[^"']+)["']\s*\)/g,
		/\bnew\s+Worker\(\s*["'](\.{0,2}\/[^"']+)["']/g,
		/\bimportScripts\(\s*["'](\.{0,2}\/[^"']+)["']/g,
		/\bfetch\(\s*["'](\.{0,2}\/[^"']+)["']/g
	],
	'.css': [/url\(\s*["']?([^"')]+)["']?\s*\)/g, /@import\s+["']([^"']+)["']/g]
};

/**
 * Resolves a page reference to a bundle path. WebView hosts map the virtual
 * host root onto _SharedDir (the onboarding wizard onto _SharedDir\ui).
 * @param {string} fromArc - Referencing file.
 * @param {string} ref - Raw reference.
 * @returns {string|null|undefined} Bundle path, null when unresolvable, or
 *   undefined for an external URL, fragment or data URI.
 */
function resolvePageRef(fromArc, ref) {
	if (/^(?:[a-z][a-z0-9+.-]*:|#|\/\/)/i.test(ref) || ref.trim() === '') return undefined;
	const clean = ref.replace(/[?#].*$/, '');
	if (clean.startsWith('/')) {
		for (const base of [SHARED_REL, `${SHARED_REL}/ui`]) {
			const candidate = normalise(`${base}/${clean}`);
			if (candidate && universe.has(candidate)) return candidate;
		}
		return null;
	}
	return normalise(`${path.posix.dirname(fromArc)}/${clean}`);
}

/**
 * Extracts page references from every shipped page, script and style sheet.
 * Third-party bundles under ui/vendor/ are leaves and are not scanned.
 * @param {Set<string>} shipped - Bundle paths that ship.
 * @returns {{from: string, ref: string, target: string|null}[]} References.
 */
function pageReferences(shipped) {
	const refs = [];
	for (const arc of shipped) {
		const ext = path.posix.extname(arc);
		if (!PAGE_REF_PATTERNS[ext] || !arc.startsWith(`${SHARED_REL}/ui/`)) continue;
		if (arc.startsWith(`${SHARED_REL}/ui/vendor/`)) continue;
		const text = read(universe.get(arc));
		for (const re of PAGE_REF_PATTERNS[ext]) {
			for (const m of text.matchAll(re)) {
				const target = resolvePageRef(arc, m[1]);
				if (target !== undefined) refs.push({ from: arc, ref: m[1], target });
			}
		}
	}
	return refs;
}

/**
 * String values of shipped JSON and TOML data that are a file path, resolved
 * against the data file's folder (the registry index names its .keylayout files
 * this way). Prose that mentions a file, and pointers to a test vector or a
 * validator, are documentation rather than reads.
 * @param {Set<string>} shipped - Bundle paths that ship.
 * @returns {{from: string, target: string}[]} References that resolve to a tracked file.
 */
function dataReferences(shipped) {
	const refs = [];
	const wholePath = new RegExp(`^${PATH_TOKEN.source}$`);
	for (const arc of shipped) {
		if (!/\.(?:json|toml)$/.test(arc)) continue;
		// The audit rejects every foreign/compile-only payload independently.
		// Such mutation inputs are not Windows data and may have no source file.
		if (neverRuntime(arc)) continue;
		const text = read(universe.get(arc));
		for (const quoted of text.matchAll(/"((?:[^"\\\n]|\\.)*)"|'([^'\n]*)'/g)) {
			const value = (quoted[1] !== undefined ? quoted[1] : quoted[2]).trim();
			const m = wholePath.exec(value);
			if (!m) continue;
			const target = normalise(`${path.posix.dirname(arc)}/${m[2].replace(/\\/g, '/')}`);
			if (target && universe.has(target) && !neverRuntime(target)) refs.push({ from: arc, target });
		}
	}
	return refs;
}

// =============================
// =============================
// ======= 5/ The Checks =======
// =============================
// =============================

/**
 * Turns a root-anchored chain into a bundle path pattern.
 * @param {object} chain - Chain from ahkReferences().
 * @returns {{text: string, dynamic: boolean, directory: boolean}|null} Pattern
 *   text (NUL marks a runtime part), or null when ".." climbs out of the bundle.
 */
function chainPattern(chain) {
	// Win32 filenames cannot contain literal control characters. A root joined
	// with a newline or tab is a reuse key or message, not an asset path.
	if (chain.parts.some((part) => 'lit' in part && /[\x00-\x1f]/.test(part.lit))) return null;
	const raw = chain.parts.map((p) => ('lit' in p ? p.lit : '\0')).join('');
	const joined = `${chain.base}/${raw.replace(/\\/g, '/')}`;
	const text = normalise(joined);
	if (text === null || text === '') return null;
	return { text, dynamic: text.includes('\0'), directory: joined.endsWith('/') };
}

// Independent AHK spelling controls keep non-path reuse keys separate from
// real native source references; no production filename is allowlisted.
for (const [raw, expected, nonPath] of [
	['`a', '\x07', true],
	['`b', '\b', true],
	['`f', '\f', true],
	['`n', '\n', true],
	['`r', '\r', true],
	['`t', '\t', true],
	['`v', '\v', true],
	['``n', '`n', false],
	['\\native\\network\\pac_runtime.c', '\\native\\network\\pac_runtime.c', false],
	['\\native\\network\\pac_runtime.h', '\\native\\network\\pac_runtime.h', false],
	['\\data\\locales\\fr.json', '\\data\\locales\\fr.json', false]
]) {
	const source = '_SharedDir . "' + raw + '" . Locale';
	const literal = ahkPathTokens(source).find((token) => token.kind === 'string');
	assert.equal(literal.pathValue, expected, 'AHK literal spelling retains its actual path value');
	const pattern = chainPattern({
		base: SHARED_REL,
		parts: [{ lit: literal.pathValue }, { dyn: 'Locale' }]
	});
	assert.equal(
		pattern === null,
		nonPath,
		'only actual control-valued literals refuse filesystem classification'
	);
	if (!nonPath)
		assert.equal(pattern.dynamic, true, 'real root-anchored dynamic path coverage remains active');
}

/**
 * Runs every check against one selection.
 * @param {Set<string>} shipped - Bundle paths of the selection.
 * @param {object} refs - Extracted references.
 * @returns {string[]} Problems; empty when the selection is complete and clean.
 */
function audit(shipped, refs) {
	const problems = [];
	const need = (arc, why) => {
		if (!shipped.has(arc)) problems.push(`${arc} is not shipped but ${why}`);
	};

	// Separately executed workers can be named through an external command
	// boundary. The manifest's required runtime contract also applies to every
	// selection mutation, independently of the source-reference extractor.
	for (const asset of REQUIRED_RUNTIME_ASSETS)
		need(asset.dest, 'the bundle manifest declares it a required runtime asset');

	// Literal file names in the AutoHotkey sources.
	for (const lit of refs.literals) {
		// "..\x" climbs from a runtime folder the gate cannot know; the suffix
		// still names the file.
		const token = normalise(lit.token.replace(/^(?:\.{1,2}\/)+/, ''));
		if (!token) continue;
		const matches = universeArcs.filter((arc) => arc === token || arc.endsWith(`/${token}`));
		if (matches.length === 0) continue;
		const runtime = matches.filter((arc) => !neverRuntime(arc));
		if (runtime.length === 0) {
			if (lit.prose) continue;
			problems.push(
				`${lit.where} names "${lit.token}", which only matches ${neverRuntime(matches[0])} (${matches[0]})`
			);
			continue;
		}
		for (const arc of runtime) need(arc, `${lit.where} names "${lit.token}"`);
	}

	// Concatenations anchored on a runtime root global. A pattern that names
	// files needs every runtime file it matches; one that names directories needs
	// each of them to exist in the bundle, and, when the code lists it, every
	// runtime file below it.
	for (const chain of refs.chains) {
		const pattern = chainPattern(chain);
		if (!pattern) continue;
		const where = `${chain.where} builds ${chain.root}${chain.parts
			.map((p) => ('lit' in p ? ` . "${p.lit}"` : ` . ${p.dyn}`))
			.join('')}`;
		const re = new RegExp(`^${pattern.text.split('\0').map(escapeRegex).join('[^/]*')}$`);
		const files = pattern.directory ? [] : universeArcs.filter((arc) => re.test(arc));
		for (const arc of files) {
			if (!neverRuntime(arc)) need(arc, where);
			else if (!pattern.dynamic) problems.push(`${where}, a ${neverRuntime(arc)} file`);
		}
		if (files.length > 0) continue;
		const dirs = new Set(
			universeArcs
				.map((arc) => arc.split('/'))
				.flatMap((segs) => segs.slice(0, -1).map((_, k) => segs.slice(0, k + 1).join('/')))
				.filter((dir) => re.test(dir))
		);
		// Defining a directory root global reads nothing; the chains built on it
		// do (_DriverDir has none).
		if (chain.definesRoot) continue;
		for (const dir of dirs) {
			const below = universeArcs.filter((arc) => arc.startsWith(`${dir}/`));
			if (chain.listed) {
				for (const arc of below.filter((a) => !neverRuntime(a)))
					need(arc, `${where} and lists that directory`);
			} else if (!below.some((arc) => shipped.has(arc))) {
				problems.push(`${where}, and nothing under ${dir}/ ships`);
			}
		}
		const outside =
			dirs.size === 0 &&
			!pattern.dynamic &&
			/^static\/./.test(pattern.text) &&
			!UNIVERSE_PREFIXES.some((p) => pattern.text === p || pattern.text.startsWith(`${p}/`)) &&
			!UNIVERSE_PREFIXES.some((p) => p.startsWith(`${pattern.text}/`));
		if (outside) problems.push(`${where}, outside every tree this gate models`);
	}

	// Every page is navigable (the WebView host opens ui/<app id>/index.html by
	// convention), and everything a shipped page, script or sheet loads ships.
	for (const arc of universeArcs) {
		if (arc.startsWith(`${SHARED_REL}/ui/`) && arc.endsWith('.html'))
			need(arc, 'every WebView page can be opened');
	}
	for (const ref of pageReferences(shipped)) {
		if (ref.target === null || !universe.has(ref.target))
			problems.push(`${ref.from} loads "${ref.ref}", which resolves to no tracked file`);
		else need(ref.target, `${ref.from} loads "${ref.ref}"`);
	}
	for (const ref of dataReferences(shipped)) need(ref.target, `${ref.from} names it`);

	// Groups that never run on Windows, and machine or compile-time files.
	for (const arc of shipped) {
		const category = neverRuntime(arc);
		if (category) problems.push(`${arc} ships but is ${category}`);
		for (const [label, test] of NEVER_SHIPPED) {
			if (test(arc)) problems.push(`${arc} ships but is a ${label}`);
		}
		if (!/^(?:static|vendor)\//.test(arc))
			problems.push(`${arc} ships outside static/ and vendor/`);
	}
	return problems;
}

// =================================================
// =================================================
// ======= 6/ Self-Check, Hygiene and Report =======
// =================================================
// =================================================

let selection;
let refs;
try {
	selection = builderSelection();
	refs = ahkReferences();
} catch (err) {
	errors.push(err.message);
}

if (selection && refs) {
	const shipped = new Set(selection.files.map((f) => f.arcname));
	for (const f of selection.files) {
		if (arcnameOf(f.source) !== f.arcname || !universe.has(f.arcname))
			errors.push(
				`${f.source} ships as ${f.arcname}, which is not its runtime path under a modelled tree`
			);
	}

	// The extractors must still see the shapes they were written for.
	const pages = pageReferences(shipped);
	const data = dataReferences(shipped);
	const dynamicChains = refs.chains.filter((c) => chainPattern(c)?.dynamic);
	for (const [label, count, floor] of [
		['file names in AutoHotkey literals', refs.literals.length, 100],
		['root-anchored concatenations', refs.chains.length, 60],
		['dynamic root-anchored concatenations', dynamicChains.length, 8],
		['page references', pages.length, 80],
		['data-file references', data.length, 5],
		['root globals', refs.roots.size, 6]
	]) {
		if (count < floor)
			errors.push(
				`extracted only ${count} ${label} (expected at least ${floor}): an extractor drifted`
			);
	}

	errors.push(...audit(shipped, refs));
	errors.push(...builderContract());

	// Each check must still be able to fail: drop one file every rule needs, or
	// add one forbidden file, and require the audit to name it.
	const sharedTest = universeArcs.find((arc) => arc.startsWith(`${SHARED_REL}/tests/`));
	const mutations = [
		['drop', `${SHARED_REL}/modules/llm/models.json`, 'a file name passed to a helper'],
		['drop', 'vendor/sqlite3.dll', 'a root-anchored file'],
		['drop', 'vendor/ergopti_user_hotstrings.ahk', 'the separately executed user callback worker'],
		[
			'drop',
			'static/layouts/registry/ergopti/hotstrings/suffixes_a.toml',
			'the shipped French suffix pack'
		],
		[
			'drop',
			'static/layouts/registry/ergopti/hotstrings/magickeyreplace.toml',
			'the shipped MagicKey replacement metadata'
		],
		['drop', `${SHARED_REL}/data/locales/fr.json`, 'a dynamic locale path'],
		['drop', 'static/img/flags/de.png', 'a dynamic flag path'],
		['drop', 'static/img/flags/de.bmp', 'a native language flag path'],
		['drop', `${SHARED_REL}/modules/hotstrings/french/magickey.toml`, 'a language-pack TOML'],
		['drop', `${SHARED_REL}/ui/host_bridge.js`, 'a script a page loads'],
		[
			'drop',
			'static/ergopti_plus/extensions/ergopti-demo/hotstrings/demo-phrases.toml',
			'a file of a directory the driver lists'
		],
		['drop', `${registryFolder}/ergol/ergol.keylayout`, 'a file the registry index names'],
		['add', sharedTest, 'a shared test corpus'],
		['add', `${SHARED_REL}/python/network_proxy_policy.py`, 'a Python driver source'],
		[
			'add',
			`${SHARED_REL}/python/__pycache__/network_proxy_policy.cpython-313.pyc`,
			'a generated Python driver runtime cache'
		],
		['add', `${SHARED_REL}/python/runtime.bin`, 'an arbitrary Python driver runtime asset'],
		['add', `${SHARED_REL}/native/network/pac_runtime.c`, 'a native compile source'],
		['add', `${SHARED_REL}/native/network/pac_runtime.h`, 'a native compile header'],
		['add', `${SHARED_REL}/go/native_http/transport.go`, 'a Go compile source'],
		[
			'add',
			`${SHARED_REL}/modules/llm/managed_ollama_runtime.json`,
			'the macOS native Ollama source catalogue'
		],
		[
			'add',
			`${SHARED_REL}/modules/llm/managed_ollama_release.json`,
			'the macOS native Ollama produced catalogue'
		],
		[
			'add',
			`${SHARED_REL}/modules/llm/managed_python_release.json`,
			'the macOS Python bootstrap catalogue'
		],
		['add', 'vendor/UIA.ahk', 'a compile-time library'],
		...REQUIRED_RUNTIME_ASSETS.map((asset) => [
			'drop',
			asset.dest,
			'a declared required runtime asset'
		])
	];
	for (const [kind, arc, label] of mutations) {
		if (!arc || (kind === 'drop' && !shipped.has(arc))) {
			errors.push(`self-check "${label}" is stale: ${arc} is not in the real selection`);
			continue;
		}
		const mutated = new Set(shipped);
		if (kind === 'drop') mutated.delete(arc);
		else mutated.add(arc);
		const reported = audit(mutated, refs).filter((p) => p.includes(arc));
		if (reported.length === 0)
			errors.push(`self-check: removing or adding ${arc} (${label}) is not reported`);
	}

	// An exclude group that removes nothing is stale unless it only guards
	// against development leftovers.
	const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
	for (const group of manifest.exclude) {
		if (!group.may_be_empty && !(selection.excluded[group.name] > 0))
			errors.push(`exclude group "${group.name}" removes no file: delete it or fix its globs`);
	}

	if (errors.length === 0) {
		const removed = Object.values(selection.excluded).reduce((a, b) => a + b, 0);
		console.log(
			`\x1b[32m[OK] the Windows bundle ships ${shipped.size} files (${removed} excluded by ` +
				`${Object.keys(selection.excluded).length} groups); ${refs.literals.length} literal file ` +
				`names, ${refs.chains.length} root-anchored paths (${dynamicChains.length} dynamic), ` +
				`${pages.length} page and ${data.length} data references all resolve to shipped files; ` +
				`${mutations.length} self-checks fail as they must.\x1b[0m`
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] Windows bundle manifest:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}
