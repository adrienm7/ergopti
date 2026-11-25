// tools/test/lib/target-size.cjs

/**
 * ==============================================================================
 * MODULE: Enhanced Target Size
 * DESCRIPTION:
 * Measures WCAG 2.5.5 Target Size (Enhanced, level AAA): every pointer target
 * is at least 44 by 44 CSS pixels. axe-core's target-size rule stops at the
 * 24 px of 2.5.8 (AA), so the site and app window gates count this one
 * themselves, under TARGET_SIZE_RULE, in their ratchets.
 *
 * targetSizeProblems runs in the page (page.evaluate), so it uses nothing from
 * this module's scope. It reads every visible, enabled control (links,
 * buttons, form fields, summaries, elements with a control role or a
 * tabindex) and applies the exceptions of the criterion that a page can
 * show:
 * 1. Inline: a link inside a sentence (laid out inline, in a block that holds
 *    text of its own) is sized by the line it sits in.
 * 2. Equivalent: a form field's labels are part of its target, as a click on
 *    a label activates its field; the box measured is the field and its
 *    labels together.
 * 3. User agent: a range or colour field the page leaves unstyled keeps the
 *    browser's size; it is still counted when the page sized it.
 * The « essential » exception needs a person's judgement and is left to the
 * manual audit (docs/audits/accessibility/aaa-criteria.md). Targets are
 * counted once per kind (tag, classes, role and type): a style rule to
 * fix, not a row of the page's data.
 * ==============================================================================
 */

'use strict';

// The rule name under which the gates count targets below 44 px.
const TARGET_SIZE_RULE = 'target-size-enhanced';
// WCAG 2.5.5: 44 by 44 CSS pixels.
const MINIMUM_PX = 44;

/**
 * Lists the pointer targets of the document below the minimum size, as
 * « tag#id «label» w×h » strings, once per kind of target (tag, classes,
 * role and type), the first one met standing for the others.
 * @param {number} minimum - The side in CSS pixels (44 for WCAG 2.5.5).
 * @returns {string[]}
 */
function targetSizeProblems(minimum) {
	const CONTROLS = [
		'a[href]',
		'button',
		'input:not([type="hidden"])',
		'select',
		'textarea',
		'summary',
		'[role="button"]',
		'[role="link"]',
		'[role="checkbox"]',
		'[role="radio"]',
		'[role="switch"]',
		'[role="tab"]',
		'[role="menuitem"]',
		'[role="option"]',
		'[role="slider"]',
		'[tabindex]:not([tabindex="-1"])'
	].join(',');
	const BLOCKS = /^(block|flex|grid|list-item|table|table-cell|flow-root)$/;
	const visible = (element) => {
		const rect = element.getBoundingClientRect();
		const style = getComputedStyle(element);
		return (
			rect.width > 0 &&
			rect.height > 0 &&
			style.visibility !== 'hidden' &&
			!element.closest('[hidden], [aria-hidden="true"], [inert]')
		);
	};
	const disabled = (element) =>
		element.disabled === true || element.getAttribute('aria-disabled') === 'true';
	// Inline: a link laid out inline whose nearest block holds text of its own
	// (not the text of other controls) sits in a sentence.
	const inSentence = (element) => {
		if (getComputedStyle(element).display !== 'inline') return false;
		if (element.tagName !== 'A' && element.getAttribute('role') !== 'link') return false;
		let block = element.parentElement;
		while (block && !BLOCKS.test(getComputedStyle(block).display)) block = block.parentElement;
		if (!block) return false;
		const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
		for (let node = walker.nextNode(); node; node = walker.nextNode())
			if (node.textContent.trim() && !node.parentElement.closest(CONTROLS)) return true;
		return false;
	};
	// A browser-drawn control the page did not size keeps the browser's size.
	const userAgentSized = (element) => {
		if (element.tagName !== 'INPUT' || !/^(range|color)$/.test(element.type)) return false;
		return !element.style.width && !element.style.height;
	};
	const box = (element) => {
		const parts = [element, ...Array.from(element.labels || []).filter(visible)];
		const rects = parts.map((part) => part.getBoundingClientRect());
		const left = Math.min(...rects.map((rect) => rect.left));
		const top = Math.min(...rects.map((rect) => rect.top));
		const right = Math.max(...rects.map((rect) => rect.right));
		const bottom = Math.max(...rects.map((rect) => rect.bottom));
		return { width: right - left, height: bottom - top };
	};
	// One problem per kind of target: the same tag, classes, role and type are
	// one style rule to fix, however many rows of data the page draws with it,
	// so a page that lists one more layout does not move the count. The size
	// stays out of the kind: text drawn in another machine's fonts must not
	// split one rule into two.
	const kinds = new Map();
	const seen = new Set();
	for (const element of document.querySelectorAll(CONTROLS)) {
		if (seen.has(element) || !visible(element) || disabled(element)) continue;
		seen.add(element);
		if (inSentence(element) || userAgentSized(element)) continue;
		const { width, height } = box(element);
		// Half a pixel of rounding: a 43.6 px box is drawn on 44 device pixels.
		if (width + 0.5 >= minimum && height + 0.5 >= minimum) continue;
		const label = (
			element.getAttribute('aria-label') ||
			element.textContent ||
			element.getAttribute('title') ||
			element.getAttribute('placeholder') ||
			''
		)
			.replace(/\s+/g, ' ')
			.trim()
			.slice(0, 30);
		const tag = element.tagName.toLowerCase();
		const size = `${Math.round(width)}×${Math.round(height)}`;
		const kind = [
			tag,
			Array.from(element.classList).sort().join('.'),
			element.getAttribute('role') || '',
			element.getAttribute('type') || ''
		].join('|');
		const known = kinds.get(kind);
		if (known) known.count++;
		else
			kinds.set(kind, {
				first: `${tag}${element.id ? '#' + element.id : ''} «${label}» ${size}`,
				count: 1
			});
	}
	return Array.from(kinds.values(), ({ first, count }) =>
		count > 1 ? `${first} (and ${count - 1} more alike)` : first
	);
}

/**
 * The selectors of the controls targetSizeProblems measures, read from its
 * own source: the page function cannot import them, and a second list here
 * could drift from the one the gates run.
 * @returns {string[]} Each selector with single quotes, as a stylesheet writes it.
 */
function controlSelectors() {
	const source = targetSizeProblems.toString();
	const list = source.slice(source.indexOf('const CONTROLS = ['), source.indexOf('].join('));
	return Array.from(list.matchAll(/'([^']+)'/g), (match) => match[1].replace(/"/g, "'"));
}

/**
 * Splits a selector list at its top-level commas.
 * @param {string} list - The text between a :where( and its closing parenthesis.
 * @returns {string[]}
 */
function splitSelectors(list) {
	const parts = [];
	let depth = 0;
	let start = 0;
	for (let index = 0; index < list.length; index++) {
		if (list[index] === '(') depth++;
		else if (list[index] === ')') depth--;
		else if (list[index] === ',' && depth === 0) {
			parts.push(list.slice(start, index).trim());
			start = index + 1;
		}
	}
	parts.push(list.slice(start).trim());
	return parts.filter(Boolean);
}

/**
 * What a stylesheet lacks to give every measured control the 44 px minimum:
 * its token set to MINIMUM_PX, one zero-specificity rule over every control
 * selector giving both minimum sides from that token (a text field may leave
 * out the checkbox and the radio button), and the rule that gives those two
 * their label's 44 px instead, as a native mark drawn at 44 px is a giant.
 * @param {string} css - The stylesheet's text.
 * @param {string} token - The custom property holding the minimum.
 * @returns {string[]} The problems, empty when the stylesheet holds the minimum.
 */
function stylesheetTargetProblems(css, token) {
	const problems = [];
	const code = css.replace(/\/\*[\s\S]*?\*\//g, '');
	const declared = code.match(new RegExp(`${token}:\\s*([^;]+);`));
	if (!declared || declared[1].trim() !== `${MINIMUM_PX}px`)
		problems.push(`${token} is not ${MINIMUM_PX}px`);
	const sizes = (body) =>
		body.includes(`min-block-size: var(${token})`) &&
		body.includes(`min-inline-size: var(${token})`);
	const rules = Array.from(code.matchAll(/:where\(([^{]*)\)\s*\{([^}]*)\}/g), (match) => ({
		selectors: splitSelectors(match[1]),
		body: match[2]
	})).filter((rule) => sizes(rule.body));
	const controls = rules.find((rule) => rule.selectors.includes('button'));
	if (!controls) problems.push('no :where() rule gives the controls both minimum sides');
	else
		for (const selector of controlSelectors()) {
			const field = selector.startsWith('input:not(');
			const found = field
				? controls.selectors.some((written) => written.startsWith(selector.slice(0, -1)))
				: controls.selectors.includes(selector);
			if (!found) problems.push(`the minimum misses ${selector}`);
		}
	if (!rules.some((rule) => rule.selectors.some((written) => /^label:has\(/.test(written))))
		problems.push('no rule gives a checkbox or radio button its label as a 44 px target');
	return problems;
}

module.exports = {
	TARGET_SIZE_RULE,
	MINIMUM_PX,
	targetSizeProblems,
	controlSelectors,
	stylesheetTargetProblems
};
