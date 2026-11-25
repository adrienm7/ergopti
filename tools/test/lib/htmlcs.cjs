// tools/test/lib/htmlcs.cjs

/**
 * ==============================================================================
 * MODULE: HTML_CodeSniffer Scan
 * DESCRIPTION:
 * Runs HTML_CodeSniffer's WCAG2AAA standard in a page or frame the
 * accessibility gates already opened for axe-core, beside it. The maintainer
 * added it to the AAA audit on 2026-11-24 (docs/memory/maintainer-decisions.md,
 * « Agent decisions reviewed on 2026-11-24 »). Its bundle is read from the
 * pinned npm package on disk, never from the network. Only its errors are
 * gated, per code, in a ratchet of their own: its warnings and notices ask a
 * person to judge (reading level, abbreviations, sign language) and are
 * listed in the gates' reports, not counted.
 *
 * An error on an element the page does not render (checkVisibility() false:
 * inside a hidden screen, a closed dialog or a folded panel) is listed in
 * the report too, not counted: HTML_CodeSniffer judges such markup as if it
 * were shown, so an empty heading a script fills when its screen opens read
 * as a failure, while axe-core skips it. The state that shows the screen is
 * scanned with it rendered, and its errors count there.
 *
 * HTML_CodeSniffer 2.5.1 parses only integer rgb() and hex colours. Chromium
 * computes color-mix() and the oklch() tokens as color(srgb …) or oklab(…),
 * which it read as NaN, so it reported a contrast « of NaN:1 » for nearly
 * every element of the pages, and a real failure hid among them. Its parser
 * is therefore given the browser's own conversion (resolveColours): a colour
 * the browser accepts is painted on a one-pixel canvas and read back as the
 * sRGB bytes the screen shows. A string the browser does not accept as a
 * colour keeps HTML_CodeSniffer's own parser, and an error that still reads
 * NaN is counted under its code suffixed with UNMEASURED_SUFFIX, apart from
 * a measured ratio below 7:1. So is a contrast error on SVG text: its glyphs
 * are painted with their fill over sibling shapes (a heatmap's keys), while
 * HTML_CodeSniffer compares the CSS colour with the parents' backgrounds.
 *
 * The bundle is a UMD module: a page that defines an AMD loader or a global
 * « exports » would swallow it, so it is evaluated with both shadowed and
 * its exports copied onto window.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');

// The standard run: WCAG 2.x level AAA, which holds the A and AA checks too.
const HTMLCS_STANDARD = 'WCAG2AAA';
// Prefix of a counted row's rule, so an HTML_CodeSniffer code never reads as an axe rule.
const HTMLCS_RULE_PREFIX = 'htmlcs:';
// HTML_CodeSniffer's message types (HTMLCS.ERROR, WARNING and NOTICE).
const MESSAGE_TYPES = Object.freeze({ 1: 'error', 2: 'warning', 3: 'notice' });
// The suffix of a contrast error whose ratio HTML_CodeSniffer could not compute.
const UNMEASURED_SUFFIX = '.Unmeasured';
// The contrast techniques (1.4.3 and 1.4.6, G17 and G18) whose message carries the ratio.
const CONTRAST_CODE = /\.1_4_[36]\.G1[78]\b/;
// The report type of an error on an element the page does not render (inside
// a hidden screen or a closed panel): no user perceives it there, and the
// state that shows it is scanned with it rendered.
const UNRENDERED_TYPE = 'unrendered-error';
// Elements described per code in a report row; the count holds them all.
const TARGETS_PER_ROW = 5;

/**
 * The bundle, wrapped to install HTMLCS and its standards on window whatever
 * module loader the page defines.
 * @returns {string} A script for page.evaluate or frame.evaluate.
 */
function htmlcsSource() {
	const bundle = fs.readFileSync(require.resolve('html_codesniffer/build/HTMLCS.js'), 'utf8');
	return (
		'(function (define, exports, module) {\n' +
		bundle +
		'\n}).call(window, undefined, undefined, undefined);\n(' +
		resolveColours.toString() +
		')();'
	);
}

/**
 * Hands HTML_CodeSniffer the colours the screen shows. Runs in the page once
 * the bundle is installed, so it uses nothing from this module's scope.
 * 1. Its parser receives every colour the browser accepts, converted by the
 *    browser itself: painted on a one-pixel canvas and read back as sRGB bytes.
 * 2. Its style reader receives, for a translucent background or text colour,
 *    that colour composited over the backgrounds behind it (the page's canvas
 *    colour at the root), as axe-core does: HTML_CodeSniffer 2.5.1 gives up on
 *    any alpha below 1 and reports « NaN:1 », which hid every measured ratio
 *    of the washes the themes draw. A fully transparent background still reads
 *    rgba(0, 0, 0, 0), so its own walk up to the parents' backgrounds and
 *    background images is unchanged. A translucent layer over a background
 *    image or gradient is left as it is: no single colour stands for what
 *    shows through, so it stays unmeasured.
 * @returns {void}
 */
function resolveColours() {
	const util = window.HTMLCS.util;
	const parse = util.colourStrToRGB;
	const readStyle = util.style;
	// The forms HTML_CodeSniffer's own parser reads: integer rgb()/rgba() and hex.
	const native = /^(rgba?\(\s*\d+,\s*\d+,\s*\d+[^)]*\)|#[0-9a-f]{3,8})$/i;
	const canvas = document.createElement('canvas');
	canvas.width = 1;
	canvas.height = 1;
	const context = canvas.getContext('2d', { willReadFrequently: true });
	const toBytes = (text) => {
		context.clearRect(0, 0, 1, 1);
		context.fillStyle = text;
		context.fillRect(0, 0, 1, 1);
		const [red, green, blue, alpha] = context.getImageData(0, 0, 1, 1).data;
		return { red, green, blue, alpha: alpha / 255 };
	};
	util.colourStrToRGB = function (colour) {
		const text = String(colour).trim();
		if (native.test(text) || !CSS.supports('color', text)) return parse(colour);
		const bytes = toBytes(text);
		return {
			red: bytes.red / 255,
			green: bytes.green / 255,
			blue: bytes.blue / 255,
			alpha: bytes.alpha
		};
	};
	let pageCanvas = null;
	// The colour the page is painted on below every background: the
	// browser's Canvas colour in the page's colour scheme.
	const canvasColour = () => {
		if (pageCanvas) return pageCanvas;
		const probe = document.createElement('div');
		probe.style.backgroundColor = 'Canvas';
		document.documentElement.appendChild(probe);
		pageCanvas = toBytes(getComputedStyle(probe).backgroundColor);
		probe.remove();
		return pageCanvas;
	};
	const over = (top, below) => ({
		red: Math.round(top.alpha * top.red + (1 - top.alpha) * below.red),
		green: Math.round(top.alpha * top.green + (1 - top.alpha) * below.green),
		blue: Math.round(top.alpha * top.blue + (1 - top.alpha) * below.blue),
		alpha: 1
	});
	// What is painted behind an element: null when an image or a gradient
	// shows through, which no single colour stands for.
	const behind = (element) => {
		const parent = element.parentElement;
		return parent ? backdrop(parent) : canvasColour();
	};
	// The opaque colour an element's own background paints, with what is behind it.
	const backdrop = (element) => {
		const style = getComputedStyle(element);
		const own = toBytes(style.backgroundColor);
		if (own.alpha === 1) return own;
		if (style.backgroundImage !== 'none') return null;
		const below = behind(element);
		return below && over(own, below);
	};
	const serialise = (bytes) => 'rgb(' + bytes.red + ', ' + bytes.green + ', ' + bytes.blue + ')';
	util.style = function (element, pseudo) {
		const style = readStyle.call(util, element, pseudo);
		if (!style || pseudo || element.nodeType !== 1) return style;
		const background = toBytes(style.backgroundColor);
		const text = toBytes(style.color);
		if (background.alpha === 1 && text.alpha === 1) return style;
		const below = behind(element);
		// An image or a gradient shows through: left to HTML_CodeSniffer, which
		// cannot measure it either and reports it unmeasured.
		if (!below || (background.alpha > 0 && style.backgroundImage !== 'none')) return style;
		const paint = background.alpha === 0 ? null : over(background, below);
		const overrides = {
			backgroundColor: paint ? serialise(paint) : 'rgba(0, 0, 0, 0)',
			color: text.alpha === 1 ? style.color : serialise(over(text, paint || below))
		};
		return new Proxy(style, {
			get(target, property) {
				if (Object.prototype.hasOwnProperty.call(overrides, property)) return overrides[property];
				const value = target[property];
				return typeof value === 'function' ? value.bind(target) : value;
			}
		});
	};
}

/**
 * Runs the standard on the document and groups the messages by type and
 * code. Runs in the page, so it uses nothing from this module's scope.
 * @param {{standard: string, types: Object<number, string>, perRow: number, contrastCode: string, unmeasured: string, unrendered: string}} options
 * @returns {Promise<Array<{type: string, code: string, help: string, nodes: number, targets: string[]}>>}
 */
function runHtmlcs({ standard, types, perRow, contrastCode, unmeasured, unrendered }) {
	const contrast = new RegExp(contrastCode);
	const describe = (element) => {
		if (!element || element.nodeType !== 1) return '(document)';
		const id = element.id ? '#' + element.id : '';
		const classes = [...element.classList]
			.slice(0, 2)
			.map((name) => '.' + name)
			.join('');
		return element.tagName.toLowerCase() + id + classes;
	};
	return new Promise((resolve, reject) => {
		window.HTMLCS.process(
			standard,
			document,
			() => {
				const rows = new Map();
				for (const message of window.HTMLCS.getMessages()) {
					const type = types[message.type];
					if (!type) return reject(new Error('Unknown HTML_CodeSniffer type ' + message.type));
					const element = message.element;
					const shown = !element || element.nodeType !== 1 || element.checkVisibility();
					const kind = type === 'error' && !shown ? unrendered : type;
					// SVG text is painted by its fill over sibling shapes, which
					// HTML_CodeSniffer's walk up the parents' backgrounds never sees.
					const code =
						contrast.test(message.code) &&
						(message.msg.includes('NaN:1') || message.element instanceof SVGElement)
							? message.code + unmeasured
							: message.code;
					const key = kind + ' ' + code;
					if (!rows.has(key))
						rows.set(key, { type: kind, code, help: message.msg, nodes: 0, targets: [] });
					const row = rows.get(key);
					row.nodes += 1;
					if (row.targets.length < perRow) row.targets.push(describe(message.element));
				}
				resolve([...rows.values()]);
			},
			() => reject(new Error('HTML_CodeSniffer could not load ' + standard))
		);
	});
}

/**
 * Injects the bundle into one frame and runs the standard there.
 * @param {object} frame - A Playwright page or frame.
 * @param {string} source - htmlcsSource(), read once per run.
 * @returns {Promise<{errors: object[], others: object[]}>} errors: rows counted
 *   under « htmlcs:<code> »; others: the warnings, the notices and the errors
 *   on unrendered elements (UNRENDERED_TYPE), for the report.
 */
async function scanHtmlcs(frame, source) {
	await frame.evaluate(source);
	const rows = await frame.evaluate(runHtmlcs, {
		standard: HTMLCS_STANDARD,
		types: MESSAGE_TYPES,
		perRow: TARGETS_PER_ROW,
		contrastCode: CONTRAST_CODE.source,
		unmeasured: UNMEASURED_SUFFIX,
		unrendered: UNRENDERED_TYPE
	});
	const errors = [];
	const others = [];
	for (const row of rows)
		if (row.type === 'error')
			errors.push({
				rule: HTMLCS_RULE_PREFIX + row.code,
				impact: 'error',
				help: row.help,
				nodes: row.nodes,
				targets: row.targets
			});
		else others.push(row);
	return { errors, others };
}

module.exports = {
	HTMLCS_STANDARD,
	HTMLCS_RULE_PREFIX,
	MESSAGE_TYPES,
	UNMEASURED_SUFFIX,
	UNRENDERED_TYPE,
	CONTRAST_CODE,
	htmlcsSource,
	resolveColours,
	runHtmlcs,
	scanHtmlcs
};
