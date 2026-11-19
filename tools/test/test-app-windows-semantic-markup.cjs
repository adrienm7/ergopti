// tools/test/test-app-windows-semantic-markup.cjs

/**
 * ==============================================================================
 * MODULE: App Windows Semantic Markup Gate
 * DESCRIPTION:
 * Blocks, in every Ergopti+ WebView window and the shared helpers they load:
 * 1. a div or span that no allowlist entry justifies. Each window has its
 *    list in tools/test/app-windows-semantic-markup/<window>.json, one entry
 *    per kind of generic element that stays, with the part of its opening
 *    tag (or call line) that finds it, its exact count and the reason no
 *    element carries its meaning. A new div needs its own reason; a removed
 *    one lowers its count in the same change, so the lists can only shrink;
 * 2. a div or span with an interactive role or a pointer handler, whatever
 *    the list says: the native element (button, link, form control) is the
 *    one the keyboard reaches and activates;
 * 3. an img without alt, and an svg neither hidden from assistive technology
 *    nor named as an image.
 * The maintainer asked on 2026-11-19 for windows with no non-semantic tag
 * and for blocking tests. The scan is static and reads every branch of the
 * pages' scripts; app-windows-accessibility.playwright.cjs checks the
 * rendered windows (names, keyboard, images drawn at run time).
 *
 * Usage: node tools/test/test-app-windows-semantic-markup.cjs [--report]
 * --report prints every occurrence with its context, to write a list.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const scanner = require('./lib/semantic-markup.cjs');

const UI = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');
const LISTS = path.join(__dirname, 'app-windows-semantic-markup');
// The shared helpers' list, for the files under _shared/ui/ itself.
const SHARED_LIST = '_shared';

// Pages under _shared/ui/ outside this gate, each with its reason.
const NOT_COVERED_HERE = Object.freeze({
	layout_analysis: 'Studio page; its semantic pass belongs to the Studio campaign',
	layout_editor: 'Studio page; its semantic pass belongs to the Studio campaign',
	layout_editor_window: 'Studio window; its semantic pass belongs to the Studio campaign',
	layout_manager: 'Studio page; its semantic pass belongs to the Studio campaign',
	layout_optimizer: 'Studio page; its semantic pass belongs to the Studio campaign'
});

/** Self-checks: each refusal on a small example, so a passing gate is not a blind one. */
function checkScanner() {
	const html = '<main><!-- <div> in a comment --><div class="a">x</div><span>y</span></main>';
	const found = scanner.genericOccurrences(html, 'html');
	assert.deepEqual(
		found.map((each) => each.tag),
		['div', 'span'],
		'Markup occurrences, comments left out'
	);
	const js = [
		"const url = 'https://example.org/x'; // <div> named in a comment",
		"const box = document.createElement('div');",
		'box.innerHTML = `<span class="n">${\'<b>\'}</span>`;',
		"const item = el('span', 'cls');"
	].join('\n');
	assert.deepEqual(
		scanner.genericOccurrences(js, 'js').map((each) => each.tag + '@' + each.line),
		['div@2', 'span@3', 'span@4'],
		'Script occurrences: calls and templates, not comments'
	);
	const reason = 'The grid cell only places its children; no element names a position.';
	const entries = [{ tag: 'div', where: 'class="a"', count: 1, reason }];
	assert.deepEqual(
		scanner.matchAllowlist([{ tag: 'div', line: 1, context: '<div class="a">' }], entries, 'f'),
		[],
		'A listed div with a reason passes'
	);
	assert.equal(
		scanner.matchAllowlist(
			[
				{ tag: 'div', line: 1, context: '<div class="a">' },
				{ tag: 'div', line: 2, context: '<div class="a">' }
			],
			entries,
			'f'
		).length,
		1,
		'A div past its entry count is unjustified'
	);
	assert.equal(
		scanner.matchAllowlist([{ tag: 'span', line: 1, context: '<span>' }], [], 'f').length,
		1,
		'An unlisted span fails'
	);
	assert.equal(scanner.matchAllowlist([], entries, 'f').length, 1, 'A stale count fails');
	assert.equal(
		scanner.matchAllowlist(
			[{ tag: 'div', line: 1, context: '<div class="a">' }],
			[{ tag: 'div', where: 'class="a"', count: 1, reason: 'layout' }],
			'f'
		).length,
		1,
		'A reason that says nothing fails'
	);
	assert.deepEqual(
		scanner.matchAllowlist(
			[{ tag: 'div', line: 1, context: '<div>' }],
			[{ tag: 'div', count: 1, pending: true }],
			'f'
		),
		[],
		'A pending count holds a window not yet reviewed'
	);
	assert.equal(scanner.interactiveTag('<div role="button" tabindex="0">'), 'role="button"');
	assert.equal(scanner.interactiveTag('<span onclick="go()">'), 'onclick');
	assert.equal(scanner.interactiveTag('<div role="region" tabindex="0">'), null);
	assert.equal(
		scanner.interactiveCalls(
			"const row = document.createElement('div');\nrow.addEventListener('click', go);"
		).length,
		1,
		'A created div with a click listener fails'
	);
	assert.equal(
		scanner.interactiveCalls("const tip = el('span');\ntip.setAttribute('role', 'tab');").length,
		1,
		'A created span given an interactive role fails'
	);
	assert.equal(
		scanner.interactiveCalls(
			"const row = document.createElement('div');\nconst row = document.createElement('button');\nrow.onclick = go;"
		).length,
		0,
		'A redeclared name is another element'
	);
	assert.equal(scanner.imageProblems('<img src="a.png">', 'html').length, 1, 'img without alt');
	assert.equal(scanner.imageProblems('<img src="a.png" alt="">', 'html').length, 0);
	assert.equal(scanner.imageProblems('<svg viewBox="0 0 1 1">', 'html').length, 1, 'bare svg');
	assert.equal(scanner.imageProblems('<svg aria-hidden="true">', 'html').length, 0);
	assert.equal(scanner.imageProblems('<svg role="img" aria-label="Logo">', 'html').length, 0);
	assert.equal(
		scanner.imageProblems("const icon = document.createElement('img');\nicon.src = x;", 'js')
			.length,
		1,
		'A created img without alt fails'
	);
	assert.equal(
		scanner.imageProblems(
			"const s = document.createElementNS(NS, 'svg');\ns.setAttribute('aria-hidden', 'true');",
			'js'
		).length,
		0
	);
}

/** The window folders: every folder under _shared/ui/ with an index.html. */
function windowFolders() {
	return fs
		.readdirSync(UI, { withFileTypes: true })
		.filter(
			(entry) => entry.isDirectory() && fs.existsSync(path.join(UI, entry.name, 'index.html'))
		)
		.map((entry) => entry.name)
		.sort();
}

/** The HTML and script files of one window folder, generated output left out. */
function windowFiles(folder) {
	const files = [];
	const visit = (relative) => {
		for (const entry of fs.readdirSync(path.join(UI, folder, relative), { withFileTypes: true })) {
			const child = path.posix.join(relative, entry.name);
			if (entry.isDirectory()) {
				if (entry.name !== '_generated') visit(child);
			} else if (/\.(html|js)$/.test(entry.name)) files.push(child);
		}
	};
	visit('');
	return files.sort();
}

/**
 * The helpers directly under _shared/ui/ that a covered window loads: its own
 * script tags' `../name.js`, vendored and generated files left out.
 */
function sharedHelpers(covered) {
	const helpers = new Set();
	for (const folder of covered) {
		const html = fs.readFileSync(path.join(UI, folder, 'index.html'), 'utf8');
		for (const match of html.matchAll(/<script[^>]*\bsrc="\.\.\/([a-z_]+\.js)"/g))
			helpers.add(match[1]);
	}
	return [...helpers].sort();
}

/** Reads one list file; a malformed one fails, a missing one is an empty list. */
function readList(name) {
	const file = path.join(LISTS, name + '.json');
	assert.ok(
		fs.existsSync(file),
		'Missing semantic markup list: ' + path.relative(process.cwd(), file)
	);
	const list = JSON.parse(fs.readFileSync(file, 'utf8'));
	assert.ok(
		list && typeof list.files === 'object' && !Array.isArray(list.files),
		name + ': {files: {...}}'
	);
	const keys = Object.keys(list).filter((key) => key !== 'pendingProblems');
	assert.deepEqual(keys, ['files'], name + ': a files map and an optional pendingProblems count');
	if (Object.hasOwn(list, 'pendingProblems'))
		assert.ok(
			Number.isSafeInteger(list.pendingProblems) && list.pendingProblems > 0,
			name + ': pendingProblems'
		);
	return list;
}

/**
 * Scans one group of files against its list.
 * @returns {{problems: string[], counts: Object<string, number>}}
 */
function scanGroup(name, root, files, report) {
	const list = readList(name);
	const listed = list.files;
	const problems = [];
	// Controls and images found before this window's pass, held by an exact
	// count until the pass fixes them.
	const held = [];
	const counts = {};
	for (const key of Object.keys(listed))
		if (!files.includes(key))
			problems.push(`${name}: the list names ${key}, which the gate does not scan`);
	for (const file of files) {
		const source = fs.readFileSync(path.join(root, file), 'utf8');
		const kind = file.endsWith('.html') ? 'html' : 'js';
		const where = `${name}/${file}`;
		const occurrences = scanner.genericOccurrences(source, kind);
		counts[file] = occurrences.length;
		if (report)
			for (const each of occurrences)
				console.log(
					`${where}:${each.line} ${each.tag} ${each.context.replace(/\s+/g, ' ').slice(0, 160)}`
				);
		problems.push(...scanner.matchAllowlist(occurrences, listed[file] || [], where));
		for (const each of occurrences) {
			const control = scanner.interactiveTag(each.context);
			if (control)
				held.push(`${where}:${each.line}: <${each.tag}> with ${control}: use the native element`);
		}
		if (kind === 'js')
			for (const each of scanner.interactiveCalls(source))
				held.push(`${where}:${each.line}: ${each.problem}`);
		for (const each of scanner.imageProblems(source, kind))
			held.push(`${where}:${each.line}: ${each.problem}`);
	}
	const pending = list.pendingProblems || 0;
	if (held.length !== pending)
		problems.push(
			`${name}: ${held.length} control or image problem(s), ${pending} pending listed` +
				(held.length > pending ? ':\n  ' + held.join('\n  ') : '; lower pendingProblems')
		);
	return { problems, counts };
}

function main(args = process.argv.slice(2)) {
	for (const flag of args) assert.ok(flag === '--report', 'Unknown argument ' + flag);
	const report = args.includes('--report');
	checkScanner();
	const folders = windowFolders();
	assert.ok(folders.length >= 20, 'The page walk found the windows');
	const covered = folders.filter((folder) => !Object.hasOwn(NOT_COVERED_HERE, folder));
	for (const folder of Object.keys(NOT_COVERED_HERE))
		assert.ok(folders.includes(folder), 'Exempt page without a folder: ' + folder);
	const lists = fs
		.readdirSync(LISTS)
		.filter((name) => name.endsWith('.json'))
		.map((name) => name.slice(0, -'.json'.length))
		.sort();
	assert.deepEqual(
		lists,
		[SHARED_LIST, ...covered].sort(),
		'One list per covered window and one for the helpers'
	);
	const problems = [];
	const totals = [];
	for (const folder of covered) {
		const { problems: found, counts } = scanGroup(
			folder,
			path.join(UI, folder),
			windowFiles(folder),
			report
		);
		problems.push(...found);
		totals.push(`${folder} ${Object.values(counts).reduce((sum, n) => sum + n, 0)}`);
	}
	const shared = scanGroup(SHARED_LIST, UI, sharedHelpers(covered), report);
	problems.push(...shared.problems);
	totals.push(`${SHARED_LIST} ${Object.values(shared.counts).reduce((sum, n) => sum + n, 0)}`);
	assert.deepEqual(problems, [], 'Semantic markup of the app windows');
	console.log('div/span per window: ' + totals.join(', '));
	console.log(
		`PASS app windows semantic markup (${covered.length} windows and their shared helpers)`
	);
}

module.exports = { NOT_COVERED_HERE, windowFolders, windowFiles, sharedHelpers, main };
if (require.main === module) main();
