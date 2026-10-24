// tools/test/test-shared-ui-no-platform-branches.cjs

/**
 * ==============================================================================
 * MODULE: Shared Pages Branch On Host Capabilities, Never On Platform Names
 * DESCRIPTION:
 * The shared pages (_shared/ui) run unchanged in the WebView2, WKWebView and
 * WebKitGTK hosts. A page that compared a platform or driver name to decide
 * what to show (`driver === 'windows'`, `platform === 'linux'`, the Linux
 * `__ergopti_host` marker) duplicated a host fact in every page and drifted
 * from it: the host now states what it can do (a capability flag, a value
 * such as the shortcut menu file, or catalogue data) and the page reads that.
 * This gate fails on every comparison of a string to a platform or driver
 * name in shared page code, so the count stays at zero.
 *
 * FEATURES & RATIONALE:
 * 1. Every page script: each .js file and each inline <script> of each .html
 *    file under _shared/ui, generated data included; only vendored libraries
 *    are skipped. A floor on the files read keeps the walk from passing empty.
 * 2. Every comparison shape: ===, !==, == and != with the name on either side,
 *    `case 'name':`, user-agent sniffing and the retired host marker.
 * 3. A table keyed by a platform (OS_KEY_GLYPHS[os]) is data, not a branch,
 *    and stays allowed: the page still holds no rule about one platform.
 * 4. Self-test: each shape is fed to the detector first, so the gate cannot
 *    pass because its patterns stopped matching.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const UI_ROOT = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');

// Platform and driver names as the hosts and the manifest spell them.
const PLATFORM_NAMES = ['windows', 'macos', 'linux', 'ahk', 'hs', 'win', 'mac', 'darwin', 'win32'];

// Fewer files means the walk lost the tree; the tree holds well over this.
const MIN_FILES_READ = 70;

const NAME = `(['"\`])(?:${PLATFORM_NAMES.join('|')})\\1`;
const COMPARE = '(?:===|!==|==|!=)';
const PATTERNS = [
	{ id: 'platform-name comparison', regex: new RegExp(`${COMPARE}\\s*${NAME}`) },
	{ id: 'platform-name comparison', regex: new RegExp(`${NAME}\\s*${COMPARE}`) },
	{ id: 'platform-name switch case', regex: new RegExp(`\\bcase\\s+${NAME}\\s*:`) },
	{ id: 'user-agent sniffing', regex: /\bnavigator\.(?:platform|userAgent|userAgentData)\b/ },
	{ id: 'retired host marker', regex: /\b__ergopti_host\b(?!_)/ }
];

/**
 * The violations of one source text, comment lines left out.
 * @param {string} text
 * @returns {{line: number, id: string, text: string}[]}
 */
function violations(text) {
	const found = [];
	text.split('\n').forEach((line, index) => {
		const code = line.trim();
		if (code.startsWith('//') || code.startsWith('*') || code.startsWith('/*')) return;
		for (const pattern of PATTERNS) {
			if (pattern.regex.test(line)) found.push({ line: index + 1, id: pattern.id, text: code });
		}
	});
	return found;
}

/**
 * The script text of a page file: a .js file whole, an .html file's inline
 * scripts with their line numbers kept.
 * @param {string} file
 * @returns {string}
 */
function scriptText(file) {
	const text = fs.readFileSync(file, 'utf8');
	if (file.endsWith('.js')) return text;
	const kept = text.split('\n').map(() => '');
	for (const match of text.matchAll(/<script\b(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)) {
		const first = text.slice(0, match.index + match[0].indexOf(match[1])).split('\n').length - 1;
		match[1].split('\n').forEach((line, offset) => {
			kept[first + offset] = line;
		});
	}
	return kept.join('\n');
}

/** Every page script under the shared UI tree, vendored libraries skipped. */
function pageFiles(dir) {
	const out = [];
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (entry.name !== 'vendor' && entry.name !== 'node_modules') out.push(...pageFiles(full));
		} else if (/\.(js|html)$/.test(entry.name)) {
			out.push(full);
		}
	}
	return out;
}

// ===========================
// ===========================
// ======= 1/ Self-test =======
// ===========================
// ===========================

const errors = [];
const SHOULD_FAIL = [
	"var supported = state.snapshot.driver === 'windows';",
	"if ('linux' !== platform) return;",
	'const primary = hostPlatform == "hs";',
	'case `macos`:',
	"if (window.__ergopti_host === 'linux') return true;",
	'const mac = /Mac/.test(navigator.platform);'
];
const SHOULD_PASS = [
	'const own = OS_KEY_GLYPHS[view.os] || {};',
	"if (hostHasCapability('document_bridge')) return true;",
	'window.__ergopti_host_capabilities = { document_bridge: true };',
	"// A comment may say platform === 'windows' when it explains history.",
	"if (state.phase === 'linuxish') return;"
];
for (const snippet of SHOULD_FAIL)
	if (violations(snippet).length === 0) errors.push(`self-test: the gate misses ${snippet}`);
for (const snippet of SHOULD_PASS)
	if (violations(snippet).length !== 0) errors.push(`self-test: the gate flags ${snippet}`);

// ==========================
// ==========================
// ======= 2/ The scan =======
// ==========================
// ==========================

const files = pageFiles(UI_ROOT);
if (files.length < MIN_FILES_READ)
	errors.push(`only ${files.length} page files read under ${UI_ROOT} (floor ${MIN_FILES_READ})`);
for (const file of files) {
	for (const found of violations(scriptText(file))) {
		errors.push(`${path.relative(UI_ROOT, file)}:${found.line}: ${found.id}: ${found.text}`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] shared pages branch on a platform name:\x1b[0m');
	for (const error of errors) console.error('  - ' + error);
	console.error(
		'  Have the host state the capability or the value (init payload, catalogue data) and read that.'
	);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] ${files.length} shared page files compare no string to a platform name.\x1b[0m`
);
