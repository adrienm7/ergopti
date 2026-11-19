// tools/test/test-app-windows-accessibility-ratchet.cjs

/**
 * ==============================================================================
 * MODULE: App Windows Accessibility Ratchet Contract
 * DESCRIPTION:
 * The browser scan of the Ergopti+ WebView windows
 * (tools/test/browser/app-windows-accessibility.playwright.cjs) runs in CI in
 * Chromium; this check runs everywhere, without a browser, and proves what a
 * passing scan cannot: the ratchet refuses a new or higher count, the
 * committed baseline is well formed, every window page under _shared/ui/ is
 * audited unless a stated reason exempts it, and each fixture posts to the
 * bridge its page really uses, so the fake host answers the right messages.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const scan = require('./browser/app-windows-accessibility.playwright.cjs');
const { WINDOWS } = require('./browser/app-windows-fixtures.cjs');

const UI = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');
const MANIFEST = JSON.parse(fs.readFileSync(path.join(UI, 'apps.manifest.json'), 'utf8'));

// Pages under _shared/ui/ that are not app windows of their own, or are
// audited by another gate, each with the reason.
const NOT_AUDITED_HERE = Object.freeze({
	// The Studio pages the site frames: site-accessibility.playwright.cjs scans
	// them and studio-keyboard.playwright.cjs walks them.
	layout_editor: 'Studio page, scanned and walked by the site gates',
	layout_analysis: 'Studio page, scanned and walked by the site gates',
	layout_optimizer: 'Studio page, scanned and walked by the site gates',
	// The app's Studio window frames the same three pages under one host page.
	layout_editor_window: 'Studio window, its pages are the Studio pages above'
});

/** The ratchet: new rows and higher counts fail, lower counts are reported. */
function checkComparison() {
	const baseline = { 'a | light | filled | rule': 3, 'b | dark | open | rule': 1 };
	assert.deepEqual(scan.compareWithBaseline({ ...baseline }, baseline), {
		regressions: [],
		improvements: []
	});
	const worse = scan.compareWithBaseline({ ...baseline, 'a | light | filled | rule': 4 }, baseline);
	assert.equal(worse.regressions.length, 1, 'A higher count is a regression');
	const added = scan.compareWithBaseline({ ...baseline, 'c | light | filled | new': 1 }, baseline);
	assert.equal(added.regressions.length, 1, 'A rule absent from the baseline is a regression');
	const walk = scan.compareWithBaseline(
		{ ...baseline, ['a | light | filled | ' + scan.WALK_RULE]: 1 },
		baseline
	);
	assert.equal(walk.regressions.length, 1, 'A keyboard-walk problem is a regression');
	// The scan reads each window's outline and counts its problems under their own rule.
	assert.equal(scan.OUTLINE_RULE, 'heading-landmarks', 'The outline has its counted rule');
	assert.match(
		fs.readFileSync(
			path.join(__dirname, 'browser', 'app-windows-accessibility.playwright.cjs'),
			'utf8'
		),
		/outlineProblems\(await page\.evaluate\(collectOutline\)\)/,
		'The scan judges every window state by its outline'
	);
	const outline = scan.compareWithBaseline(
		{ ...baseline, ['a | light | filled | ' + scan.OUTLINE_RULE]: 1 },
		baseline
	);
	assert.equal(outline.regressions.length, 1, 'A heading or landmark problem is a regression');
	const better = scan.compareWithBaseline({ 'a | light | filled | rule': 2 }, baseline);
	assert.deepEqual(better.regressions, []);
	assert.equal(better.improvements.length, 2, 'A lower or vanished count asks to lower it');
	assert.deepEqual(
		scan.countsOf([
			{ window: 'b', scheme: 'dark', state: 'filled', rule: 'r', nodes: 2 },
			{ window: 'a', scheme: 'light', state: 'filled', rule: 'r', nodes: 5 }
		]),
		{ 'a | light | filled | r': 5, 'b | dark | filled | r': 2 }
	);
}

/** The committed baseline only names audited windows, known schemes and states. */
function checkBaseline() {
	const baseline = scan.readBaseline();
	for (const key of Object.keys(baseline)) {
		const [id, , state] = key.split(' | ');
		const target = WINDOWS.find((each) => each.id === id);
		const states = ['filled', ...(target.states || []).map((each) => each.name)];
		assert.ok(states.includes(state), 'Baseline names an unknown state: ' + key);
	}
	assert.deepEqual([...scan.COLOR_SCHEMES], ['light', 'dark']);
}

/** Every window page is audited once, or named above with its reason. */
function checkCoverage() {
	const pages = fs
		.readdirSync(UI, { withFileTypes: true })
		.filter(
			(entry) => entry.isDirectory() && fs.existsSync(path.join(UI, entry.name, 'index.html'))
		)
		.map((entry) => entry.name);
	assert.ok(pages.length >= 20, 'The page walk found the windows');
	const audited = WINDOWS.map((target) => target.id);
	assert.equal(new Set(audited).size, audited.length, 'A window is audited twice');
	for (const page of pages) {
		const exempt = Object.hasOwn(NOT_AUDITED_HERE, page);
		assert.ok(
			exempt !== audited.includes(page),
			page + (exempt ? ' is both exempt and audited' : ' is missing from the app windows audit')
		);
	}
	for (const id of audited) {
		assert.ok(pages.includes(id), 'Audited window without a page: ' + id);
		const target = WINDOWS.find((each) => each.id === id);
		assert.ok(
			MANIFEST.apps[id] ? !target.size : target.size,
			id +
				': the size comes from apps.manifest.json, or from the fixture when the page has no window'
		);
	}
}

/** Each fixture is well formed and posts to the bridge name its page's scripts use. */
function checkFixtures() {
	for (const target of WINDOWS) {
		assert.equal(typeof target.ready, 'string', target.id + ': ready selector');
		assert.ok(
			target.host || target.fill || target.seed,
			target.id + ': a fixture fills the window'
		);
		if (target.host) {
			const source = target.host.toString();
			assert.match(
				source,
				/^(async )?function\b/,
				target.id + ': host must be a function expression'
			);
		}
		const names = (target.states || []).map((state) => state.name);
		assert.equal(new Set(names).size, names.length, target.id + ': state names are unique');
		assert.ok(!names.includes('filled'), target.id + ': « filled » is the base state');
		const scripts = fs
			.readdirSync(path.join(UI, target.id))
			.filter((name) => name.endsWith('.js'))
			.map((name) => fs.readFileSync(path.join(UI, target.id, name), 'utf8'))
			.join('\n');
		const used = [...scripts.matchAll(/makeHostBridge\('([^']+)'\)/g)].map((match) => match[1]);
		if (used.length)
			assert.ok(
				used.includes(target.bridge),
				target.id + ' posts to ' + used.join(', ') + ', not ' + target.bridge
			);
		else
			assert.ok(
				new RegExp('\\b' + target.bridge + '\\b').test(scripts),
				target.id + ': its scripts never name the bridge ' + target.bridge
			);
	}
}

checkComparison();
checkBaseline();
checkCoverage();
checkFixtures();
console.log('PASS app windows accessibility ratchet contract');
