// tools/test/test-site-accessibility-ratchet.cjs

/**
 * ==============================================================================
 * MODULE: Site Accessibility Ratchet Contract
 * DESCRIPTION:
 * The browser scan (tools/test/browser/site-accessibility.playwright.cjs) runs
 * in CI on the built site; this check runs everywhere, without a browser, and
 * proves the parts a passing scan cannot: the ratchet refuses a new or higher
 * count, the committed baseline is well formed, and every real page of the
 * site is audited.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const scan = require('./browser/site-accessibility.playwright.cjs');

const ROOT = path.resolve(__dirname, '../..');

/** The ratchet: new rows and higher counts fail, lower counts are reported. */
function checkComparison() {
	const baseline = { 'a | light | page | rule': 3, 'b | dark | page | rule': 1 };
	assert.deepEqual(scan.compareWithBaseline({ ...baseline }, baseline), {
		regressions: [],
		improvements: []
	});
	const worse = scan.compareWithBaseline({ ...baseline, 'a | light | page | rule': 4 }, baseline);
	assert.equal(worse.regressions.length, 1, 'A higher count is a regression');
	const added = scan.compareWithBaseline({ ...baseline, 'c | light | page | new': 1 }, baseline);
	assert.equal(added.regressions.length, 1, 'A rule absent from the baseline is a regression');
	const better = scan.compareWithBaseline({ 'a | light | page | rule': 2 }, baseline);
	assert.deepEqual(better.regressions, []);
	assert.equal(
		better.improvements.length,
		2,
		'A lower or vanished count asks to lower the baseline'
	);
	assert.deepEqual(
		scan.countsOf([
			{ route: 'b', scheme: 'dark', frame: 'page', rule: 'r', nodes: 2 },
			{ route: 'a', scheme: 'light', frame: 'page', rule: 'r', nodes: 5 }
		]),
		{ 'a | light | page | r': 5, 'b | dark | page | r': 2 }
	);
}

/** The committed baseline only names audited pages, both schemes and positive counts. */
function checkBaseline() {
	const baseline = scan.readBaseline();
	for (const key of Object.keys(baseline)) {
		const [route, scheme] = key.split(' | ');
		assert.ok(scan.AUDITED_ROUTES.includes(route), 'Baseline names an unaudited page: ' + key);
		assert.ok(scan.COLOR_SCHEMES.includes(scheme), 'Baseline names an unknown scheme: ' + key);
	}
	assert.deepEqual([...scan.COLOR_SCHEMES], ['light', 'dark']);
	assert.ok(scan.WCAG_TAGS.includes('wcag22aa'), 'The target is WCAG 2.2 AA');
}

/** Every page of src/routes is audited, except the former addresses that redirect. */
function checkRouteCoverage() {
	const routesRoot = path.join(ROOT, 'src/routes');
	const pages = [];
	const walk = (directory) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (entry.name === '+page.svelte') pages.push(full);
		}
	};
	walk(routesRoot);
	assert.ok(pages.length >= 15, 'The route walk found the site pages');
	for (const file of pages) {
		if (fs.readFileSync(file, 'utf8').includes('LegacyRedirect')) continue;
		const route = '/' + path.relative(routesRoot, path.dirname(file)).split(path.sep).join('/');
		const normalized = route === '/' ? '/' : route.replace(/\/$/, '');
		assert.ok(
			scan.AUDITED_ROUTES.includes(normalized),
			'Page missing from the accessibility audit: ' + normalized
		);
	}
}

checkComparison();
checkBaseline();
checkRouteCoverage();
console.log('ok - site accessibility ratchet, baseline and page coverage');
