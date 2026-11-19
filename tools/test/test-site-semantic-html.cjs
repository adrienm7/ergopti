// tools/test/test-site-semantic-html.cjs

/**
 * ==============================================================================
 * MODULE: Site Semantic HTML Gate
 * DESCRIPTION:
 * The site's markup says what it is (maintainer request of 2026-11-19: « no
 * non-semantic tag: main, section, aside, nav…, no span or div if
 * possible »). A div or a span is allowed only where no element has the
 * meaning, and each one is justified in a reviewed list.
 *
 * WHAT IS CHECKED, in every Svelte file under src/:
 * 1. Every div and span matches an entry of site-semantic-html-allowlist.json:
 *    its file, its element (tag and first static class, or #id, or « (none) »)
 *    and its exact count, with a kind from a closed list and a reason. An
 *    unlisted element fails (use the element that has the meaning, or add a
 *    reviewed entry); a count above the entry fails; a count below it fails
 *    too until the entry is lowered, so the list can only shrink by review.
 * 2. No div or span is interactive: no event handler (onclick, on:click,
 *    onmousedown…), no interactive role (button, link, tab…) and no tabindex
 *    other than -1. A native button, link or input is the only answer; the
 *    allowlist cannot excuse it (WCAG 2.1.1, 4.1.2).
 * 3. No Svelte accessibility warning (a11y_*) in any file, and every
 *    svelte-ignore of one is listed with its reason in the same file.
 * 4. The checker refuses each of those failures on a sample and accepts a
 *    justified one, so it cannot pass vacuously.
 *
 * The judgement is shared with the other scopes (lib/semantic-markup.cjs);
 * this file is the site's scope: its reader (lib/svelte-markup.cjs) and its
 * reviewed list. Run with --inventory to print the current elements as rows.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const markup = require('./lib/svelte-markup.cjs');
const semantic = require('./lib/semantic-markup.cjs');
const { allowlistProblems, compareWithAllowlist, ignoreProblems } = semantic;

const ALLOWLIST_PATH = path.join(__dirname, 'site-semantic-html-allowlist.json');

/** The generic elements of one Svelte source (the shared judgement on its descriptors). */
function inventoryOf(source, file) {
	return semantic.inventoryOf(markup.descriptorsOf(source, file), file);
}

/** Measure the whole site. */
function measureSite(root = markup.ROOT) {
	const measured = new Map();
	const interactive = [];
	const warnings = [];
	const ignores = new Map();
	for (const file of markup.svelteFiles(root)) {
		const source = fs.readFileSync(path.join(root, file), 'utf8');
		const inventory = inventoryOf(source, file);
		if (inventory.counts.size) measured.set(file, inventory.counts);
		interactive.push(...inventory.interactive);
		for (const warning of markup.a11yWarnings(source, file))
			warnings.push(`${file}:${warning.line} ${warning.code}: ${warning.message}`);
		ignores.set(file, markup.svelteIgnores(source, file));
	}
	return { measured, interactive, warnings, ignores };
}

/** The checker refuses each failure it exists for. */
function checkTheChecker() {
	const sample = (body) => inventoryOf(body, 'sample.svelte');
	assert.match(sample('<div onclick={go}>x</div>').interactive[0], /click handler/);
	assert.match(sample('<span on:mousedown={go}>x</span>').interactive[0], /mousedown handler/);
	assert.match(sample('<div onmouseenter={show}>x</div>').interactive[0], /mouseenter handler/);
	// A popup panel catching Escape from its controls is not operated itself.
	assert.deepEqual(
		sample('<div onkeydown={closeOnEscape}><button>x</button></div>').interactive,
		[]
	);
	assert.match(sample('<div role="button">x</div>').interactive[0], /role="button"/);
	assert.match(sample('<span tabindex="0">x</span>').interactive[0], /focusable/);
	assert.deepEqual(sample('<div id="target" tabindex="-1"></div>').interactive, []);
	assert.deepEqual(sample('<div class="mode-tabs" role="tablist"></div>').interactive, []);
	assert.deepEqual(sample('<button onclick={go}>x</button>').interactive, []);
	// Elements inside blocks are seen, keyed by class, id or (none).
	const keys = sample(
		'{#if a}<div class="grid {b}">{#each c as d}<span>{d}</span>{/each}</div>{/if}<div id="x"></div>'
	).counts;
	assert.deepEqual(
		[...keys],
		[
			['div.grid', 1],
			['span (none)', 1],
			['div#x', 1]
		]
	);
	const entry = (count) => ({
		elements: [
			{
				file: 'a.svelte',
				element: 'div.grid',
				count,
				kind: 'layout',
				reason: 'The two-column grid of the cards, no meaning of its own.'
			}
		],
		svelteIgnores: []
	});
	const measured = new Map([['a.svelte', new Map([['div.grid', 2]])]]);
	assert.deepEqual(compareWithAllowlist(measured, entry(2)), []);
	assert.match(compareWithAllowlist(measured, entry(1))[0], /more than the 1 justified/);
	assert.match(compareWithAllowlist(measured, entry(3))[0], /lower the entry/);
	assert.match(
		compareWithAllowlist(new Map([['a.svelte', new Map([['span.x', 1]])]]), entry(2))[0],
		/is not justified/
	);
	assert.match(compareWithAllowlist(new Map(), entry(2))[0], /listed but gone/);
	assert.match(
		allowlistProblems({ ...entry(1), elements: [{ ...entry(1).elements[0], kind: 'misc' }] })[0],
		/unknown kind/
	);
	assert.match(
		allowlistProblems({
			...entry(1),
			elements: [{ ...entry(1).elements[0], reason: 'layout' }]
		})[0],
		/reason/
	);
	assert.match(
		ignoreProblems('a.svelte', [{ codes: ['a11y_autofocus'], line: 3 }], { svelteIgnores: [] })[0],
		/not justified/
	);
	assert.deepEqual(
		markup
			.a11yWarnings('<div onclick={() => 1}>x</div>', 'sample.svelte')
			.map((w) => w.code)
			.sort(),
		['a11y_click_events_have_key_events', 'a11y_no_static_element_interactions']
	);
}

function main(args = process.argv.slice(2)) {
	const site = measureSite();
	if (args.includes('--inventory')) {
		const rows = [];
		for (const [file, counts] of site.measured)
			for (const [element, count] of counts) rows.push({ file, element, count });
		console.log(JSON.stringify(rows, null, '\t'));
		return;
	}
	checkTheChecker();
	const allowlist = JSON.parse(fs.readFileSync(ALLOWLIST_PATH, 'utf8'));
	const problems = [
		...allowlistProblems(allowlist),
		...site.interactive,
		...site.warnings,
		...[...site.ignores].flatMap(([file, ignores]) => ignoreProblems(file, ignores, allowlist)),
		...compareWithAllowlist(site.measured, allowlist)
	];
	if (problems.length) {
		for (const problem of problems) console.error('  ' + problem);
		throw new Error(problems.length + ' semantic HTML problem(s) in the site');
	}
	const total = allowlist.elements.reduce((sum, entry) => sum + entry.count, 0);
	console.log(
		`Site semantic HTML: ${site.measured.size} files, ${total} justified div/span, no interactive one, no Svelte a11y warning`
	);
}

if (require.main === module) main();

module.exports = { inventoryOf, measureSite };
