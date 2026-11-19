// tools/test/test-studio-semantic-html.cjs

/**
 * ==============================================================================
 * MODULE: Studio Semantic HTML Gate
 * DESCRIPTION:
 * The Ergopti Studio's markup says what it is (maintainer request of
 * 2026-11-19: « no non-semantic tag, no span or div if possible », counted in
 * the pages' HTML and in the DOM their scripts build). The Studio scope of the
 * shared judgement (lib/semantic-markup.cjs, the site's gate is
 * test-site-semantic-html.cjs): lib/studio-markup.cjs reads every page file of
 * the Comparer and its panels, the editor and its app window, the Optimiser,
 * the layout manager, the composer and the layer editor, and
 * studio-semantic-html-allowlist.json justifies each div and span left.
 *
 * WHAT IS CHECKED:
 * 1. Every div and span, in an HTML start tag, a template string or a builder
 *    call (createElement('div'), el('span', …)), matches an entry: file,
 *    element (tag and first static class, or #id, or « (none) »), exact
 *    count, kind and reason. An unlisted one fails; a count above or below
 *    its entry fails until the entry follows, so the list only shrinks by
 *    review.
 * 2. None is interactive: no pointer handler (addEventListener, on… property
 *    or attribute, an on… key of a builder's attributes), no interactive role,
 *    no role computed at run time, no tabindex other than -1.
 * 3. The reader finds each form on a sample and the judgement refuses each
 *    failure, so the gate cannot pass vacuously.
 * Run with --inventory to print the current elements as rows.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const reader = require('./lib/studio-markup.cjs');
const semantic = require('./lib/semantic-markup.cjs');

const ALLOWLIST_PATH = path.join(__dirname, 'studio-semantic-html-allowlist.json');

/** The generic elements of one Studio file. */
function inventoryOf(file, text) {
	return semantic.inventoryOf(reader.descriptorsOf(file, text), file);
}

/** Measure every Studio file. */
function measureStudio(root = reader.ROOT) {
	const measured = new Map();
	const interactive = [];
	const files = reader.studioFiles(root);
	for (const file of files) {
		const inventory = inventoryOf(file, fs.readFileSync(path.join(root, file), 'utf8'));
		if (inventory.counts.size) measured.set(file, inventory.counts);
		interactive.push(...inventory.interactive);
	}
	return { files, measured, interactive };
}

/** The reader sees each form and the judgement refuses each failure. */
function checkTheChecker() {
	const keys = (file, text) => [...inventoryOf(file, text).counts];
	assert.deepEqual(
		keys(
			'a.html',
			'<!-- <div class="no"> --><main><div id="box"><span class="y z">a</span><span></span></div></main>'
		),
		[
			['div#box', 1],
			['span.y', 1],
			['span (none)', 1]
		],
		'HTML start tags, comments left out'
	);
	assert.deepEqual(
		keys(
			'a.js',
			[
				"// el('div', 'commented')",
				'const MARKUP = `<section><div class="la-top ${x}"></div></section>`;',
				"const box = el('div', 'la-box');",
				"const node = document.createElement('span');",
				"node.className = 'la-node';",
				"const bare = document.createElement('div');",
				"const tab = el('div', { class: 'le-tab', id: 'le-tab-1' });",
				"const pick = el(\n\t'span',\n\t{ class: `le-pick ${x}` }\n);",
				"root.querySelectorAll('div').forEach(() => {});"
			].join('\n')
		),
		[
			['div.la-top', 1],
			['div.la-box', 1],
			['span.la-node', 1],
			['div (none)', 1],
			['div.le-tab', 1],
			['span.le-pick', 1]
		],
		'template strings and every builder form; selectors and comments are not elements'
	);
	const refused = (text, pattern) =>
		assert.ok(
			inventoryOf('a.js', text).interactive.some((problem) => pattern.test(problem)),
			`refused: ${text}`
		);
	refused('const a = `<div class="a" onclick="go()"></div>`;', /click handler/);
	refused('const a = `<span class="a" role="button"></span>`;', /role="button"/);
	refused("const b = el('div', 'b');\nb.addEventListener('click', go);", /click handler/);
	refused("const c = el('span', 'c');\nc.setAttribute('role', 'tab');", /role="tab"/);
	refused("const c = el('span', 'c');\nc.setAttribute('role', kind);", /computed role/);
	refused("const d = el('div', { class: 'd', onclick: go });", /click handler/);
	refused("const f = el('div', 'f');\nf.onpointerdown = go;", /pointerdown handler/);
	refused("const g = el('div', 'g');\ng.tabIndex = 0;", /focusable/);
	assert.deepEqual(
		inventoryOf(
			'a.js',
			[
				"const t = el('div', { class: 't', role: 'tablist' });",
				"const p = el('div', 'p');\np.addEventListener('keydown', close);",
				"const r = el('div', 'r');\nconst r = 1;\nr.addEventListener('click', go);"
			].join('\n')
		).interactive,
		[],
		'a tablist container, a key listener of a container and a name declared again pass'
	);
	const entry = (count) => ({
		elements: [
			{
				file: 'a.js',
				element: 'div.grid',
				count,
				kind: 'layout',
				reason: 'The two-column grid of the cards, no meaning of its own.'
			}
		],
		svelteIgnores: []
	});
	const measured = new Map([['a.js', new Map([['div.grid', 2]])]]);
	assert.deepEqual(semantic.compareWithAllowlist(measured, entry(2)), []);
	assert.match(semantic.compareWithAllowlist(measured, entry(1))[0], /more than the 1 justified/);
	assert.match(semantic.compareWithAllowlist(measured, entry(3))[0], /lower the entry/);
	assert.match(semantic.compareWithAllowlist(new Map(), entry(2))[0], /listed but gone/);
}

function main(args = process.argv.slice(2)) {
	checkTheChecker();
	const { files, measured, interactive } = measureStudio();
	if (args.includes('--inventory')) {
		for (const [file, counts] of measured)
			for (const [element, count] of counts) console.log(`${file}\t${element}\t${count}`);
		return;
	}
	const allowlist = JSON.parse(fs.readFileSync(ALLOWLIST_PATH, 'utf8'));
	assert.deepEqual(semantic.allowlistProblems(allowlist), [], 'the justified list is well formed');
	assert.deepEqual(allowlist.svelteIgnores, [], 'the Studio has no Svelte file');
	assert.ok(files.length > 20, 'the Studio files are found');
	assert.deepEqual(interactive, [], 'no div or span of the Studio is interactive');
	assert.deepEqual(
		semantic.compareWithAllowlist(measured, allowlist),
		[],
		'every div and span of the Studio is justified'
	);
	const total = allowlist.elements.reduce((sum, item) => sum + item.count, 0);
	console.log(
		`PASS test-studio-semantic-html (${files.length} files, ${total} justified div or span)`
	);
}

if (require.main === module) main();

module.exports = { measureStudio, inventoryOf };
