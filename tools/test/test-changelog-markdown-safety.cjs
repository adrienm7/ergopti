// tools/test/test-changelog-markdown-safety.cjs

/**
 * ==============================================================================
 * MODULE: Changelog Markdown Safety Test
 * DESCRIPTION:
 * Pins the externally loaded Markdown renderer and sanitizer to immutable SRI
 * assets, then executes the real release-body renderer to prove that remote
 * Markdown HTML cannot reach innerHTML without sanitization.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const UI_DIR = 'static/ergopti_plus/_shared/ui/changelog';
const HTML_PATH = path.join(ROOT, UI_DIR, 'index.html');
const SCRIPT_PATH = path.join(ROOT, UI_DIR, 'script.js');
const HTML = fs.readFileSync(HTML_PATH, 'utf8');
const SCRIPT = fs.readFileSync(SCRIPT_PATH, 'utf8');

const EXPECTED_EXTERNAL_SCRIPTS = [
	{
		src: 'https://cdn.jsdelivr.net/npm/dompurify@3.4.14/dist/purify.min.js',
		integrity: 'sha384-46dPGH1XlTmj7bc50bqLjTdORXs/3EP2QpA/6EWbelYWOY9VGp+87RT61S3Mcslb',
		crossorigin: 'anonymous'
	},
	{
		src: 'https://cdn.jsdelivr.net/npm/marked@18.0.11/lib/marked.umd.js',
		integrity: 'sha384-N2BlPYJH0HRuJRIZOGNTL/ymqHb++FCViUqW4rdB5/7fH+KvFTqyCvPPQ8X4nElj',
		crossorigin: 'anonymous'
	}
];

function parseAttributes(source) {
	const attributes = {};
	for (const match of source.matchAll(/([:\w-]+)\s*=\s*"([^"]*)"/g)) {
		attributes[match[1].toLowerCase()] = match[2];
	}
	return attributes;
}

function externalScripts(html) {
	return [...html.matchAll(/<script\b([^>]*)><\/script>/g)]
		.map((match) => ({ index: match.index, ...parseAttributes(match[1]) }))
		.filter((script) => /^https:\/\//.test(script.src || ''));
}

function extractFunction(source, name) {
	const start = source.indexOf(`function ${name}(`);
	assert.notStrictEqual(start, -1, `${name} must exist`);
	const bodyStart = source.indexOf('{', start);
	let depth = 0;
	let quote = null;
	let escaped = false;
	let regex = false;
	let regexClass = false;
	let lineComment = false;
	let blockComment = false;
	let previousSignificant = '';
	for (let i = bodyStart; i < source.length; i++) {
		const ch = source[i];
		const next = source[i + 1];
		if (lineComment) {
			if (ch === '\n') lineComment = false;
			continue;
		}
		if (blockComment) {
			if (ch === '*' && next === '/') {
				blockComment = false;
				i++;
			}
			continue;
		}
		if (regex) {
			if (escaped) escaped = false;
			else if (ch === '\\') escaped = true;
			else if (ch === '[') regexClass = true;
			else if (ch === ']') regexClass = false;
			else if (ch === '/' && !regexClass) regex = false;
			continue;
		}
		if (quote) {
			if (escaped) escaped = false;
			else if (ch === '\\') escaped = true;
			else if (ch === quote) quote = null;
			continue;
		}
		if (ch === '/' && next === '/') {
			lineComment = true;
			i++;
			continue;
		}
		if (ch === '/' && next === '*') {
			blockComment = true;
			i++;
			continue;
		}
		if (ch === '/' && /[=(,:!&|?{};\[]/.test(previousSignificant)) {
			regex = true;
			regexClass = false;
			continue;
		}
		if (ch === "'" || ch === '"' || ch === '`') {
			quote = ch;
			continue;
		}
		if (ch === '{') depth++;
		else if (ch === '}' && --depth === 0) return source.slice(start, i + 1);
		if (!/\s/.test(ch)) previousSignificant = ch;
	}
	assert.fail(`unterminated ${name} function`);
}

function compileRenderer(overrides = {}) {
	const context = { ...overrides };
	vm.createContext(context);
	vm.runInContext(
		[
			extractFunction(SCRIPT, '_escHtml'),
			extractFunction(SCRIPT, '_plainTextReleaseBody'),
			extractFunction(SCRIPT, '_renderReleaseBody')
		].join('\n'),
		context,
		{ filename: `${UI_DIR}/script.js` }
	);
	return context._renderReleaseBody;
}

const scripts = externalScripts(HTML);
assert.deepStrictEqual(
	scripts.map(({ src, integrity, crossorigin }) => ({ src, integrity, crossorigin })),
	EXPECTED_EXTERNAL_SCRIPTS,
	'the changelog must load only exact-version CDN assets with their SHA-384 SRI hashes'
);
const localScriptIndex = HTML.indexOf('<script src="script.js"></script>');
assert.notStrictEqual(localScriptIndex, -1, 'the local changelog script must remain loaded');
assert.ok(
	scripts.every((script) => script.index < localScriptIndex),
	'the sanitizer and Markdown renderer must load before the changelog script'
);

const maliciousMarkdown = '<img src=x onerror="window.webkit.messageHandlers.changelog_bridge.postMessage(1)">';
const renderedAttack = '<img src="x" onerror="OWNED"><script>OWNED()</script><p>safe</p>';
const sanitizedHtml = '<img src="x"><p>safe</p>';
let parseCalls = 0;
let sanitizeCalls = 0;
const renderSanitized = compileRenderer({
	marked: {
		setOptions(options) {
			assert.deepStrictEqual(JSON.parse(JSON.stringify(options)), { breaks: true, gfm: true });
		},
		parse(raw) {
			parseCalls++;
			assert.strictEqual(raw, maliciousMarkdown);
			return renderedAttack;
		}
	},
	DOMPurify: {
		sanitize(html, options) {
			sanitizeCalls++;
			assert.strictEqual(html, renderedAttack, 'marked output must be the sanitizer input');
			assert.deepStrictEqual(JSON.parse(JSON.stringify(options)), { USE_PROFILES: { html: true } });
			return sanitizedHtml;
		}
	}
});
assert.strictEqual(renderSanitized(maliciousMarkdown), sanitizedHtml);
assert.strictEqual(parseCalls, 1, 'the Markdown renderer must run exactly once');
assert.strictEqual(sanitizeCalls, 1, 'the sanitizer must run exactly once');

let unguardedParseCalls = 0;
const renderWithoutSanitizer = compileRenderer({
	marked: {
		setOptions() {},
		parse() {
			unguardedParseCalls++;
			return renderedAttack;
		}
	}
});
const fallback = renderWithoutSanitizer(maliciousMarkdown);
assert.strictEqual(unguardedParseCalls, 0, 'marked output must never be produced without a sanitizer');
assert.ok(fallback.startsWith('<pre '), 'missing sanitizer must use the plain-text fallback');
assert.ok(fallback.includes('&lt;img'), 'the plain-text fallback must escape remote markup');
assert.ok(!fallback.includes('<img'), 'the plain-text fallback must not expose executable markup');

const renderAfterSanitizerFailure = compileRenderer({
	marked: {
		setOptions() {},
		parse() {
			return renderedAttack;
		}
	},
	DOMPurify: {
		sanitize() {
			throw new Error('sanitizer unavailable');
		}
	}
});
assert.strictEqual(
	renderAfterSanitizerFailure(maliciousMarkdown),
	fallback,
	'a sanitizer failure must fall back to escaped text rather than raw marked output'
);

console.log('changelog markdown safety: 7/7 checks passed');
