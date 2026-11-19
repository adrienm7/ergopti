// tools/test/browser/site-reading.cjs

/**
 * ==============================================================================
 * MODULE: Site Reading Checks
 * DESCRIPTION:
 * What a reader who enlarges or spaces the text needs, measured in the page
 * (TODO « Full accessibility », « Dyslexia and reading »): no text clipped by
 * a box that hides its overflow and no two texts drawn over each other once
 * the WCAG 1.4.12 spacing and 200 % text apply, no justified prose (its
 * uneven word gaps make rivers that dyslexic readers lose their line in,
 * WCAG 1.4.8), and prose lines of at most MAX_LINE_CHARACTERS characters
 * (WCAG 1.4.8 asks for 80 at most; 45 to 80 reads best). Nothing placed
 * under the sticky header (the table of contents, the narrow-screen banner)
 * may slide under it once the header grows with the text.
 *
 * The measuring function runs inside the page (page.evaluate), so it only
 * uses what it receives as arguments. site-accessibility.playwright.cjs runs
 * it on every audited page and ratchets its counts.
 * ==============================================================================
 */

'use strict';

// WCAG 1.4.8 (AAA, cheap at AA): no more than 80 characters per line.
const MAX_LINE_CHARACTERS = 80;
// A paragraph shorter than this cannot show a long line worth measuring.
const MIN_MEASURED_CHARACTERS = 120;
// Two text lines overlap when they share at least this share of the shorter
// line's height (a descender touching the next line's ascender is not an
// overlap) and more than OVERLAP_MIN_WIDTH_PX horizontally.
const OVERLAP_MIN_SHARE = 0.25;
const OVERLAP_MIN_WIDTH_PX = 2;
// Sub-pixel rounding of text boxes against their container.
const CLIP_TOLERANCE_PX = 1;
// The site header (Header.svelte), sticky at the top of the window.
const SITE_HEADER_SELECTOR = '#page > header';

// The user style sheet of the WCAG 1.4.12 test (the « text spacing »
// bookmarklet): a reader's own spacing, which the site must not break.
const TEXT_SPACING_CSS = [
	'* { line-height: 1.5 !important; letter-spacing: 0.12em !important;',
	'word-spacing: 0.16em !important; }',
	'p { margin-bottom: 2em !important; }'
].join(' ');

/**
 * The reading conditions each page is measured in. « zoom » is a 200 % browser
 * zoom of the CI window (half the CSS pixels) with the 1.4.12 style sheet;
 * « text » is the site's own settings at their largest, 200 % text and wide
 * spacing, in the full window; « default » is an unchanged visit, where
 * justification and line length are measured.
 */
const READING_MODES = Object.freeze({
	default: Object.freeze({
		viewport: Object.freeze({ width: 1440, height: 900 }),
		deviceScaleFactor: 1,
		preferences: null,
		styleSheet: null,
		checks: Object.freeze(['justified-text', 'line-length'])
	}),
	zoom: Object.freeze({
		viewport: Object.freeze({ width: 720, height: 450 }),
		deviceScaleFactor: 2,
		preferences: null,
		styleSheet: TEXT_SPACING_CSS,
		checks: Object.freeze(['text-clipped', 'text-overlap', 'justified-text', 'header-cover'])
	}),
	text: Object.freeze({
		viewport: Object.freeze({ width: 1440, height: 900 }),
		deviceScaleFactor: 1,
		preferences: Object.freeze({ text: '200', spacing: 'wide' }),
		styleSheet: null,
		checks: Object.freeze(['text-clipped', 'text-overlap', 'justified-text', 'header-cover'])
	})
});

/**
 * Measure the reading problems of the document it runs in. Self-contained:
 * Playwright serializes it into the page.
 * @param {{checks: string[], maxLine: number, minMeasured: number, overlapShare: number,
 *   overlapWidth: number, clipTolerance: number}} options
 * @returns {Object<string, string[]>} Per check, a short description of each offending element.
 */
function measureReading(options) {
	const describe = (element) => {
		const parts = [];
		for (
			let node = element;
			node && node !== document.body && parts.length < 3;
			node = node.parentElement
		) {
			let part = node.tagName.toLowerCase();
			if (node.id) part += '#' + node.id;
			else if (typeof node.className === 'string' && node.className.trim())
				part += '.' + node.className.trim().split(/\s+/).slice(0, 2).join('.');
			parts.unshift(part);
		}
		const text = (element.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 40);
		return parts.join(' > ') + ' « ' + text + ' »';
	};
	const visible = (element) =>
		element.checkVisibility({ opacityProperty: true, visibilityProperty: true }) &&
		element.getClientRects().length > 0;
	// Elements read by screen readers only, clipped to one pixel on purpose
	// (.visually-hidden). A 0×0 box alone proves nothing: a `display: contents`
	// wrapper has one.
	const screenReaderOnly = (element) => {
		for (let node = element; node; node = node.parentElement) {
			const box = node.getBoundingClientRect();
			if (box.width > 2 || box.height > 2) continue;
			const style = getComputedStyle(node);
			if (style.overflow !== 'visible' || style.clipPath !== 'none' || style.clip !== 'auto')
				return true;
		}
		return false;
	};
	// Elements holding text of their own, outside SVG drawings.
	const textElements = [];
	const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
	const seen = new Set();
	for (let node = walker.nextNode(); node; node = walker.nextNode()) {
		const parent = node.parentElement;
		if (!parent || seen.has(parent) || !node.data.trim()) continue;
		if (parent.closest('svg, script, style, noscript, template')) continue;
		seen.add(parent);
		if (visible(parent) && !screenReaderOnly(parent)) textElements.push(parent);
	}
	const lineRects = (element) => {
		const rects = [];
		for (const child of element.childNodes) {
			if (child.nodeType !== Node.TEXT_NODE || !child.data.trim()) continue;
			const range = document.createRange();
			range.selectNodeContents(child);
			for (const rect of range.getClientRects())
				if (rect.width > 0 && rect.height > 0) rects.push(rect);
		}
		return rects;
	};
	// The ancestors that cut what overflows them, innermost first, each with
	// its padding box (what it keeps) and whether it scrolls (what it cuts can
	// still be scrolled to) or hides, per axis.
	const clippers = (element) => {
		const found = [];
		for (let box = element; box && box !== document.documentElement; box = box.parentElement) {
			const style = getComputedStyle(box);
			if (style.overflowX === 'visible' && style.overflowY === 'visible') continue;
			const outer = box.getBoundingClientRect();
			const left = outer.left + box.clientLeft;
			const top = outer.top + box.clientTop;
			found.push({
				left,
				top,
				right: left + box.clientWidth,
				bottom: top + box.clientHeight,
				x: style.overflowX,
				y: style.overflowY
			});
		}
		return found;
	};
	const found = {};
	if (options.checks.includes('text-clipped')) {
		const clipped = [];
		const tolerance = options.clipTolerance;
		for (const element of textElements) {
			const rects = lineRects(element);
			let hit = false;
			// Up to the first box that scrolls: past it, the text is reached by scrolling.
			for (const box of clippers(element)) {
				const hidesX = /hidden|clip/.test(box.x);
				const hidesY = /hidden|clip/.test(box.y);
				hit = rects.some(
					(rect) =>
						(hidesX && (rect.left < box.left - tolerance || rect.right > box.right + tolerance)) ||
						(hidesY && (rect.top < box.top - tolerance || rect.bottom > box.bottom + tolerance))
				);
				if (hit || /auto|scroll/.test(box.x + box.y)) break;
			}
			if (hit) clipped.push(describe(element));
		}
		found['text-clipped'] = clipped;
	}
	if (options.checks.includes('text-overlap')) {
		// A rotated line's client rect is its upright bounding box, far larger
		// than the line (the site's corner banner is turned 40°): such text is
		// left out rather than reported for overlapping its own box.
		const rotated = (element) => {
			for (let node = element; node; node = node.parentElement) {
				const matrix = /^matrix\(([^)]+)\)$/.exec(getComputedStyle(node).transform);
				if (matrix) {
					const [, b, c] = matrix[1].split(',').map(Number);
					if (b !== 0 || c !== 0) return true;
				}
			}
			return false;
		};
		// Only the part of each line its scrolling or clipping ancestors show.
		const lines = [];
		for (const element of textElements) {
			if (rotated(element)) continue;
			const boxes = clippers(element);
			for (const line of lineRects(element)) {
				const rect = { left: line.left, top: line.top, right: line.right, bottom: line.bottom };
				for (const box of boxes) {
					if (box.x !== 'visible') {
						rect.left = Math.max(rect.left, box.left);
						rect.right = Math.min(rect.right, box.right);
					}
					if (box.y !== 'visible') {
						rect.top = Math.max(rect.top, box.top);
						rect.bottom = Math.min(rect.bottom, box.bottom);
					}
				}
				rect.height = rect.bottom - rect.top;
				// The full line height judges the share, not the part left visible.
				rect.lineHeight = line.height;
				if (rect.right - rect.left > 0 && rect.height > 0) lines.push({ element, rect });
			}
		}
		lines.sort((a, b) => a.rect.top - b.rect.top);
		// One entry per pair of elements, so a report names both sides.
		const overlapping = new Map();
		for (let i = 0; i < lines.length; i++) {
			const a = lines[i];
			for (let j = i + 1; j < lines.length && lines[j].rect.top < a.rect.bottom; j++) {
				const b = lines[j];
				if (a.element === b.element) continue;
				if (a.element.contains(b.element) || b.element.contains(a.element)) continue;
				const height = Math.min(a.rect.bottom, b.rect.bottom) - Math.max(a.rect.top, b.rect.top);
				const width = Math.min(a.rect.right, b.rect.right) - Math.max(a.rect.left, b.rect.left);
				const shorter = Math.min(a.rect.lineHeight, b.rect.lineHeight);
				if (height >= shorter * options.overlapShare && width > options.overlapWidth) {
					const pair = [describe(a.element), describe(b.element)].sort().join(' ↔ ');
					overlapping.set(pair, true);
				}
			}
		}
		found['text-overlap'] = Array.from(overlapping.keys()).sort();
	}
	// Justification is laid out by blocks: an inline element only inherits it.
	if (options.checks.includes('justified-text'))
		found['justified-text'] = textElements
			.filter((element) => {
				const style = getComputedStyle(element);
				return /justify/.test(style.textAlign) && !/^(inline|contents)/.test(style.display);
			})
			.map(describe);
	if (options.checks.includes('line-length')) {
		const long = [];
		for (const element of document.querySelectorAll(
			'main :is(p, li, dd, blockquote, figcaption)'
		)) {
			if (!visible(element) || screenReaderOnly(element)) continue;
			if ((element.textContent || '').trim().length < options.minMeasured) continue;
			// The words laid out in this block's own lines (not those of a nested list).
			const lines = new Map();
			const words = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
			for (let node = words.nextNode(); node; node = words.nextNode()) {
				const block = node.parentElement.closest('p, li, dd, blockquote, figcaption, ul, ol, div');
				// A hidden tooltip's words are not on the paragraph's lines.
				if (block !== element || !visible(node.parentElement)) continue;
				for (const match of node.data.matchAll(/\S+/g)) {
					const range = document.createRange();
					range.setStart(node, match.index);
					range.setEnd(node, match.index + match[0].length);
					const rect = range.getBoundingClientRect();
					if (rect.width === 0) continue;
					const key = Math.round(rect.top + rect.height / 2);
					const line = Array.from(lines.keys()).find(
						(top) => Math.abs(top - key) < rect.height / 2
					);
					const at = line === undefined ? key : line;
					// A word and the space after it.
					lines.set(at, (lines.get(at) || 0) + match[0].length + 1);
				}
			}
			const longest = Math.max(0, ...Array.from(lines.values(), (count) => count - 1));
			if (longest > options.maxLine) long.push(describe(element) + ' ' + longest + ' characters');
		}
		found['line-length'] = long;
	}
	return found;
}

/**
 * The boxes the sticky site header covers (« header-cover »): each element
 * positioned sticky or fixed at a nonzero `top`, so meant to sit under the
 * header, whose box starts above the header's bottom edge while beside it.
 * A sticky box is measured where it starts to hold its place: the window is
 * scrolled to the top of its parent. Self-contained: Playwright serializes
 * it into the page.
 * @param {{headerSelector: string, clipTolerance: number}} options
 * @returns {Promise<string[]>} A description of each covered element, with the overlap in pixels.
 */
async function measureHeaderCover(options) {
	const header = document.querySelector(options.headerSelector);
	if (!header) throw new Error('No site header: ' + options.headerSelector);
	const frames = () =>
		new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
	const describe = (element) => {
		const parts = [];
		for (
			let node = element;
			node && node !== document.body && parts.length < 3;
			node = node.parentElement
		) {
			let part = node.tagName.toLowerCase();
			if (node.id) part += '#' + node.id;
			else if (typeof node.className === 'string' && node.className.trim())
				part += '.' + node.className.trim().split(/\s+/).slice(0, 2).join('.');
			parts.unshift(part);
		}
		return parts.join(' > ');
	};
	const placed = [];
	for (const element of document.body.querySelectorAll('*')) {
		if (header.contains(element) || element.contains(header)) continue;
		const style = getComputedStyle(element);
		if (style.position !== 'sticky' && style.position !== 'fixed') continue;
		if (!(parseFloat(style.top) > 0)) continue;
		if (!element.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
		placed.push(element);
	}
	const covered = [];
	for (const element of placed) {
		const sticky = getComputedStyle(element).position === 'sticky';
		if (sticky) {
			const parent = element.parentElement.getBoundingClientRect();
			window.scrollTo(0, window.scrollY + parent.top);
			await frames();
		}
		const box = element.getBoundingClientRect();
		const bar = header.getBoundingClientRect();
		if (box.width === 0 || box.height === 0) continue;
		// A sticky box at the end of its parent is pushed up by it: it scrolls
		// away with the content, as it should, instead of holding its place.
		const end = element.parentElement.getBoundingClientRect().bottom;
		if (sticky && box.bottom >= end - options.clipTolerance) continue;
		const beside = box.left < bar.right && box.right > bar.left;
		const under = bar.bottom - box.top;
		if (beside && box.top < bar.bottom - options.clipTolerance && box.bottom > bar.top)
			covered.push(describe(element) + ' ' + Math.round(under) + ' px under the header');
	}
	window.scrollTo(0, 0);
	await frames();
	return covered;
}

/**
 * The measuring options for one reading mode.
 * @param {string} mode - A key of READING_MODES.
 */
function optionsFor(mode) {
	const settings = READING_MODES[mode];
	if (!settings) throw new Error('Unknown reading mode: ' + mode);
	return {
		checks: [...settings.checks],
		maxLine: MAX_LINE_CHARACTERS,
		minMeasured: MIN_MEASURED_CHARACTERS,
		overlapShare: OVERLAP_MIN_SHARE,
		overlapWidth: OVERLAP_MIN_WIDTH_PX,
		clipTolerance: CLIP_TOLERANCE_PX,
		headerSelector: SITE_HEADER_SELECTOR
	};
}

module.exports = {
	MAX_LINE_CHARACTERS,
	READING_MODES,
	SITE_HEADER_SELECTOR,
	TEXT_SPACING_CSS,
	measureHeaderCover,
	measureReading,
	optionsFor
};
