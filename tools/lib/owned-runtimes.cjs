// tools/lib/owned-runtimes.cjs

/**
 * ==============================================================================
 * MODULE: Owned Runtimes Registry
 * DESCRIPTION:
 * Loads _shared/core/network/data/owned_runtimes.json, the decided policy row of every
 * third-party program or runtime the three drivers depend on, and renders the
 * tables of docs/design/owned-runtimes.md from it.
 *
 * FEATURES & RATIONALE:
 * 1. One source: the rows used to be Markdown cells that the inventory test
 *    parsed. They now live in the registry; the document keeps its prose and
 *    only the regions between its GENERATED markers come from here.
 * 2. Closed vocabularies: a row names its OS, its class today, its decided
 *    class and its state from the registry's own lists, so a typo or a
 *    proposal left undecided fails the load instead of reaching the table.
 * 3. Injectable data: render() and splice() take the registry as data, so the
 *    drift test can mutate one row and prove the document follows it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { escapeTableCell } = require('./text-escape.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DATA_PATH = path.join(
	ROOT,
	'static/ergopti_plus/_shared/core/network/data/owned_runtimes.json'
);
const DOC_PATH = path.join(ROOT, 'docs/design/owned-runtimes.md');
const GENERATOR = 'tools/codegen/codegen-owned-runtimes.cjs';
const OS_ORDER = Object.freeze(['macos', 'linux', 'windows']);
const OS_LABELS = Object.freeze({ macos: 'macOS', linux: 'Linux', windows: 'Windows' });
const ROW_KEYS = Object.freeze([
	'os',
	'tool',
	'programs',
	'used_for',
	'today',
	'current_class',
	'version_needed',
	'if_missing',
	'pin_possible',
	'decision',
	'decision_text',
	'alternative',
	'status'
]);
const TEXT_KEYS = Object.freeze([
	'tool',
	'used_for',
	'today',
	'version_needed',
	'if_missing',
	'pin_possible',
	'decision_text'
]);
const REGIONS = Object.freeze(['headline', ...OS_ORDER]);

/**
 * Fails with the registry path in the message.
 * @param {string} message
 */
function fail(message) {
	throw new Error(`${path.relative(ROOT, DATA_PATH)}: ${message}`);
}

/**
 * Checks the registry shape and vocabularies; returns it unchanged.
 * @param {object} data Parsed registry.
 * @returns {object}
 */
function validate(data) {
	if (data.version !== 1) fail(`unsupported version ${data.version}`);
	for (const list of ['decision_classes', 'current_classes', 'statuses']) {
		if (!data[list] || Object.keys(data[list]).length === 0) fail(`"${list}" is empty`);
	}
	if (!Array.isArray(data.rows) || data.rows.length === 0) fail('"rows" is empty');
	const seen = new Set();
	for (const [index, row] of data.rows.entries()) {
		const where = `row ${index} (${row.os} ${row.tool})`;
		const keys = Object.keys(row);
		if (keys.join() !== ROW_KEYS.join()) fail(`${where} keys must be ${ROW_KEYS.join(', ')}`);
		if (!OS_ORDER.includes(row.os)) fail(`${where} has an unknown os`);
		for (const key of TEXT_KEYS) {
			if (typeof row[key] !== 'string' || row[key].trim() === '' || /\n/.test(row[key]))
				fail(`${where} needs a one-line "${key}"`);
		}
		if (row.alternative !== null && (typeof row.alternative !== 'string' || !row.alternative))
			fail(`${where} "alternative" is a non-empty string or null`);
		if (!Array.isArray(row.programs) || row.programs.some((p) => typeof p !== 'string' || !p))
			fail(`${where} "programs" must list program names`);
		if (!(row.current_class in data.current_classes)) fail(`${where} has an unknown current_class`);
		if (!(row.decision in data.decision_classes)) fail(`${where} has an unknown decision`);
		if (!(row.status in data.statuses)) fail(`${where} has an unknown status`);
		const id = `${row.os}\u0000${row.tool}`;
		if (seen.has(id)) fail(`${where} is listed twice`);
		seen.add(id);
	}
	return data;
}

/**
 * Reads and validates the committed registry.
 * @returns {object}
 */
function load() {
	return validate(JSON.parse(fs.readFileSync(DATA_PATH, 'utf8')));
}

/**
 * Renders an aligned Markdown table; every cell is escaped.
 * @param {string[]} header
 * @param {string[][]} rows
 * @returns {string[]}
 */
function markdownTable(header, rows) {
	const escaped = rows.map((row) => row.map(escapeTableCell));
	const widths = header.map((title, col) =>
		Math.max(3, title.length, ...escaped.map((row) => row[col].length))
	);
	const line = (cells) => `| ${cells.map((c, col) => c.padEnd(widths[col])).join(' | ')} |`;
	return [line(header), line(widths.map((w) => '-'.repeat(w))), ...escaped.map(line)];
}

/**
 * The headline counts: rows per OS, per decided class and state.
 * @param {object} data
 * @returns {string[]}
 */
function headlineTable(data) {
	const count = (os, test) =>
		String(data.rows.filter((row) => (os === null || row.os === os) && test(row)).length);
	const line = (label, test) => [
		label,
		...OS_ORDER.map((os) => count(os, test)),
		count(null, test)
	];
	const rows = [line('Rows inventoried', () => true)];
	for (const decision of Object.keys(data.decision_classes)) {
		for (const status of Object.keys(data.statuses)) {
			const test = (row) => row.decision === decision && row.status === status;
			if (count(null, test) === '0') continue;
			rows.push(
				line(`${data.decision_classes[decision].label}, ${data.statuses[status].label}`, test)
			);
		}
	}
	const followUp = Object.keys(data.statuses).find((status) => data.statuses[status].follow_up);
	if (!followUp) fail('no status is marked "follow_up": true');
	rows.push(line('Rows with work left (any class)', (row) => row.status === followUp));
	return markdownTable(
		[
			'Table rows (a row can group several OS tools)',
			...OS_ORDER.map((os) => OS_LABELS[os]),
			'Total'
		],
		rows
	);
}

/**
 * One OS's decided table.
 * @param {object} data
 * @param {string} os
 * @returns {string[]}
 */
function osTable(data, os) {
	const rows = data.rows
		.filter((row) => row.os === os)
		.map((row) => [
			row.tool,
			row.used_for,
			row.today,
			row.current_class,
			row.version_needed,
			row.if_missing,
			row.pin_possible,
			row.alternative === null
				? row.decision_text
				: `${row.decision_text} (alternative noted: ${row.alternative})`,
			data.statuses[row.status].label
		]);
	if (rows.length === 0) fail(`no ${os} row`);
	return markdownTable(
		[
			'Tool',
			'Used for (source)',
			'Today',
			'Class today',
			'Version needed',
			'If missing or wrong',
			'Pin possible?',
			'Decision',
			'State'
		],
		rows
	);
}

/**
 * The generated text of one region, markers excluded.
 * @param {object} data
 * @param {string} region One of REGIONS.
 * @returns {string}
 */
function render(data, region) {
	if (region === 'headline') return headlineTable(data).join('\n');
	if (OS_ORDER.includes(region)) return osTable(data, region).join('\n');
	throw new Error(`unknown owned-runtimes region "${region}"`);
}

/**
 * Replaces every GENERATED region of the document with its rendering.
 * @param {string} doc Current document text.
 * @param {object} data Registry.
 * @returns {string}
 */
function splice(doc, data) {
	let next = doc;
	for (const region of REGIONS) {
		const begin = `<!-- BEGIN GENERATED ${region}: ${GENERATOR}; do not edit -->\n`;
		const end = `\n<!-- END GENERATED ${region} -->`;
		const start = next.indexOf(begin);
		if (start < 0 || next.indexOf(begin, start + 1) >= 0)
			throw new Error(`${path.relative(ROOT, DOC_PATH)} must hold one "${region}" begin marker`);
		const stop = next.indexOf(end, start);
		if (stop < 0) throw new Error(`${path.relative(ROOT, DOC_PATH)} has no "${region}" end marker`);
		// Blank lines around the table keep the comment markers out of its rows.
		next = next.slice(0, start + begin.length) + `\n${render(data, region)}\n` + next.slice(stop);
	}
	return next;
}

/**
 * The committed document and the one the registry implies.
 * @returns {{current: string, next: string}}
 */
function generate() {
	const current = fs.readFileSync(DOC_PATH, 'utf8');
	return { current, next: splice(current, load()) };
}

module.exports = {
	DATA_PATH,
	DOC_PATH,
	OS_ORDER,
	REGIONS,
	generate,
	load,
	render,
	splice,
	validate
};
