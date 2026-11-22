// tools/test/browser/studio-operability.cjs

/**
 * ==============================================================================
 * MODULE: Studio Keyboard Operability
 * DESCRIPTION:
 * What studio-keyboard.playwright.cjs checks on a Studio page after its Tab
 * walk (maintainer request of 2026-11-19: everything operable by keyboard,
 * nothing by mouse only, every image hidden or named):
 * 1. every element a mouse can use, the keyboard can use too, and every
 *    disclosure, popup and composite widget answers Enter, Escape and the
 *    arrow keys: the shared judgement of lib/keyboard-operability.cjs and
 *    the widget driver of keyboard-operability.playwright.cjs, as the site
 *    and the app windows are held;
 * 2. every stop of the walk shows a focus indicator of its own (2.4.7);
 * 3. every image is hidden as decoration or named (lib/page-images.cjs);
 * 4. the Studio's tab lists keep one Tab stop and answer Home and End too,
 *    beyond the shared check's one arrow key (the ARIA tabs pattern);
 * 5. nothing shows on hover alone (WCAG 1.4.13, 2.1.1, since 2026-11-22):
 *    an element with a hover listener takes the focus, holds a control that
 *    does, or follows the focus too, and a drawing keeps no value in the
 *    hover titles of its marks only; the app windows' checks
 *    (lib/app-window-checks.cjs), whose listener record
 *    studio-keyboard.playwright.cjs installs before the page's scripts.
 * ==============================================================================
 */

'use strict';

const operability = require('../lib/keyboard-operability.cjs');
const { exerciseWidgets } = require('./keyboard-operability.playwright.cjs');
const appChecks = require('../lib/app-window-checks.cjs');
const { collectImages, imageProblems } = require('../lib/page-images.cjs');

/**
 * Moves through each visible tab list with the arrow keys.
 * @returns {Promise<string[]>}
 */
async function tablistProblems(page, label) {
	const problems = [];
	const count = await page.evaluate(() => document.querySelectorAll('[role="tablist"]').length);
	for (let index = 0; index < count; index++) {
		// The tabs of this list that are shown, and where the focus is among them.
		const read = () =>
			page.evaluate((at) => {
				const list = document.querySelectorAll('[role="tablist"]')[at];
				if (!list || list.getClientRects().length === 0) return null;
				const tabs = Array.from(list.querySelectorAll('[role="tab"]')).filter(
					(tab) => tab.closest('[role="tablist"]') === list && tab.getClientRects().length > 0
				);
				return {
					name: list.getAttribute('aria-label') || list.id || list.className,
					count: tabs.length,
					focused: tabs.indexOf(document.activeElement),
					selected: Math.max(
						0,
						tabs.findIndex((tab) => tab.getAttribute('aria-selected') === 'true')
					),
					stops: tabs.filter((tab) => tab.tabIndex >= 0).length
				};
			}, index);
		const start = await read();
		if (!start || start.count < 2) continue;
		const where = `${label}: the tab list « ${start.name} »`;
		if (start.stops !== 1) problems.push(`${where} offers ${start.stops} Tab stops instead of one`);
		await page.evaluate(
			([at, selected]) => {
				const list = document.querySelectorAll('[role="tablist"]')[at];
				const tabs = Array.from(list.querySelectorAll('[role="tab"]')).filter(
					(tab) => tab.closest('[role="tablist"]') === list && tab.getClientRects().length > 0
				);
				tabs[selected].focus();
			},
			[index, start.selected]
		);
		const expect = [
			['ArrowRight', (start.selected + 1) % start.count],
			['ArrowLeft', start.selected],
			['End', start.count - 1],
			['Home', 0]
		];
		for (const [key, wanted] of expect) {
			await page.keyboard.press(key);
			const now = await read();
			if (!now || now.focused !== wanted) {
				problems.push(
					`${where}: ${key} moves the focus to tab ${now ? now.focused + 1 : '?'}, not ${wanted + 1}`
				);
				break;
			}
		}
		// Back to the tab the page opened with, so the walk after sees the same page.
		await page.evaluate(
			([at, selected]) => {
				const list = document.querySelectorAll('[role="tablist"]')[at];
				const tabs = Array.from(list.querySelectorAll('[role="tab"]')).filter(
					(tab) => tab.closest('[role="tablist"]') === list
				);
				if (tabs[selected]) tabs[selected].click();
			},
			[index, start.selected]
		);
	}
	return problems;
}

/**
 * What only a hovering pointer reaches: an element with a hover listener that
 * the keyboard cannot reach, and a drawing's values in hover titles only.
 * @param {import('playwright').Page} page
 * @returns {Promise<string[]>}
 */
async function hoverProblems(page) {
	const operable = await page.evaluate(appChecks.operabilityProblems);
	const images = await page.evaluate(appChecks.imageProblems);
	return operable
		.filter((problem) => problem.startsWith('mouse only (hover)'))
		.concat(images.filter((problem) => problem.endsWith('in hover titles only')));
}

/**
 * Every operability problem of a page after its Tab walk.
 * @param {import('playwright').Page} page
 * @param {string} label
 * @param {{indicated: boolean, id: string, key: string}[]} stops - The forward walk.
 * @returns {Promise<{problems: string[], controls: number, images: number, markup: {div: number, span: number}}>}
 */
async function operabilityProblems(page, label, stops) {
	const rows = await page.evaluate(operability.collectOperability, {
		pointer: operability.POINTER_EVENTS,
		keys: operability.KEY_EVENTS,
		roles: operability.INTERACTIVE_ROLES
	});
	const images = await page.evaluate(collectImages);
	const problems = operability
		.operabilityProblems(rows)
		.concat(imageProblems(images))
		.concat(await hoverProblems(page))
		.map((problem) => `${label}: ${problem}`);
	const unmarked = new Set();
	for (const stop of stops)
		if (!stop.indicated && !unmarked.has(stop.key)) {
			unmarked.add(stop.key);
			problems.push(`${label}: ${stop.id} shows no focus indicator`);
		}
	problems.push(...(await tablistProblems(page, label)));
	problems.push(
		...(await exerciseWidgets(page.mainFrame(), page)).map((problem) => `${label}: ${problem}`)
	);
	const markup = await page.evaluate(() => ({
		div: document.getElementsByTagName('div').length,
		span: document.getElementsByTagName('span').length
	}));
	return { problems, controls: rows.length, images: images.length, markup };
}

module.exports = { operabilityProblems, tablistProblems, hoverProblems };
