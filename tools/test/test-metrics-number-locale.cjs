// tools/test/test-metrics-number-locale.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Numbers In The Interface Language (MET-07)
 * DESCRIPTION:
 * The typing dashboard formatted every number the French way (thin-space
 * thousands, a decimal comma, « Md » for a billion) and the apps dashboard
 * through Intl.NumberFormat('fr-FR'), whatever the interface language the host
 * seeded, on the three drivers. The real format.js and modal.js run here in a
 * sandbox under several seeded locales; the expected strings are written out,
 * not computed by the code under test.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const UI = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');
const NBSP = /[\u00A0\u202F]/g;

/** Loads one page file in a fresh sandbox seeded with `locale`. */
function load(file, locale) {
	const context = vm.createContext({
		document: { addEventListener() {}, getElementById: () => null },
		escapeHtml: (value) => String(value),
		console
	});
	context.window = context;
	context._i18n_locale = locale;
	vm.runInContext(fs.readFileSync(path.join(UI, file), 'utf8'), context, { filename: file });
	return context;
}

const typing = {
	en: { plain: ['1,234', '12,345.5', '1.2M', '3.4B', '-1,234'], exact: '12,345.5' },
	de: { plain: ['1.234', '12.345,5', '1,2 Mio.', '3,4 Mrd.', '-1.234'], exact: '12.345,5' },
	fr: { plain: ['1 234', '12 345,5', '1,2 M', '3,4 Md', '-1 234'], exact: '12 345,5' }
};
const values = [1234, 12345.5, 1234567, 3400000000, -1234];
let checks = 0;
for (const [locale, expected] of Object.entries(typing)) {
	const page = load('metrics_typing/format.js', locale);
	values.forEach((value, index) => {
		assert.equal(
			page.format_number_plain(value).replace(NBSP, ' '),
			expected.plain[index],
			`met-07: ${locale} plain ${value}`
		);
		checks++;
	});
	const html = page.format_number(12345.5).replace(NBSP, ' ');
	assert.ok(
		html.includes(`title="${expected.exact}"`) && html.includes(`>${expected.exact}</data>`),
		`met-07: ${locale} grouped number and its exact tooltip: ${html}`
	);
	assert.equal(page.format_number(12), '12', 'a small number has no tooltip');
	assert.equal(page.format_number_plain(Number.NaN), '0', 'a missing number still reads 0');
	checks += 3;
}

// The apps page's integer formatter, taken from its file and run alone: the
// rest of modal.js wires the live dashboard.
const modal = fs.readFileSync(path.join(UI, 'metrics_apps/modal.js'), 'utf8');
const formatInt = modal.match(/^function format_int\(n\) \{\n[\s\S]*?\n\}$/m);
assert.ok(formatInt, 'metrics_apps/modal.js defines format_int');
for (const [locale, expected] of Object.entries({
	en: '1,234,568',
	de: '1.234.568',
	fr: '1 234 568'
})) {
	const context = vm.createContext({});
	context.window = context;
	context._i18n_locale = locale;
	vm.runInContext(formatInt[0], context);
	assert.equal(
		context.format_int(1234567.6).replace(NBSP, ' '),
		expected,
		`met-07: apps ${locale}`
	);
	checks++;
}

console.log(`metrics numbers follow the interface language: ${checks} checks`);
