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
 * HTML_CodeSniffer 2.5.1 parses only rgb() and hex colours. Chromium
 * computes color-mix() and the oklch() tokens as color(srgb …) or oklab(…),
 * which it reads as NaN, and it then reports a contrast « of NaN:1 » as an
 * error. Such an error is counted under its code suffixed with
 * UNMEASURED_SUFFIX: it stays gated, but a real contrast failure (a measured
 * ratio below 7:1) keeps a row of its own instead of hiding among them.
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
		'\n}).call(window, undefined, undefined, undefined);'
	);
}

/**
 * Runs the standard on the document and groups the messages by type and
 * code. Runs in the page, so it uses nothing from this module's scope.
 * @param {{standard: string, types: Object<number, string>, perRow: number, contrastCode: string, unmeasured: string}} options
 * @returns {Promise<Array<{type: string, code: string, help: string, nodes: number, targets: string[]}>>}
 */
function runHtmlcs({ standard, types, perRow, contrastCode, unmeasured }) {
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
					const code =
						contrast.test(message.code) && message.msg.includes('NaN:1')
							? message.code + unmeasured
							: message.code;
					const key = type + ' ' + code;
					if (!rows.has(key))
						rows.set(key, { type, code, help: message.msg, nodes: 0, targets: [] });
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
 *   under « htmlcs:<code> »; others: the warnings and notices, for the report.
 */
async function scanHtmlcs(frame, source) {
	await frame.evaluate(source);
	const rows = await frame.evaluate(runHtmlcs, {
		standard: HTMLCS_STANDARD,
		types: MESSAGE_TYPES,
		perRow: TARGETS_PER_ROW,
		contrastCode: CONTRAST_CODE.source,
		unmeasured: UNMEASURED_SUFFIX
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
	CONTRAST_CODE,
	htmlcsSource,
	runHtmlcs,
	scanHtmlcs
};
