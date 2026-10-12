// tools/codegen/codegen-native-http-failure-stages.cjs
// Closed passive failed-frame diagnostics, generated from one protocol authority.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const ROOT = path.resolve(__dirname, '../..');
const SOURCE = 'static/ergopti_plus/_shared/modules/network/native_http_failure_stages.json';
const OUTPUTS = {
	swift: 'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift',
	python: 'static/ergopti_plus/macos/platform/network/native_http.py',
	go: 'static/ergopti_plus/_shared/go/native_http/transport.go'
};
const MARKER = 'GENERATED NATIVE HTTP FAILURE STAGES';

function render(bytes) {
	const source = bytes.toString('utf8');
	if (!Buffer.from(source).equals(bytes)) throw new Error('Failure-stage authority is not UTF-8.');
	if (source.includes('\\')) throw new Error('Escaped failure-stage authority fields are refused.');
	const authority = JSON.parse(source);
	if (
		Object.keys(authority).sort().join() !== 'schema_version,stages' ||
		authority.schema_version !== 1 ||
		!Array.isArray(authority.stages) ||
		authority.stages.length < 1 ||
		authority.stages.length > 32
	)
		throw new Error('Invalid failure-stage authority.');
	const rows = authority.stages;
	for (const [key, count] of [
		['schema_version', 1],
		['stages', 1],
		['symbol', rows.length],
		['code', rows.length],
		['reasons', rows.length]
	]) {
		if ([...source.matchAll(new RegExp('"' + key + '"\\s*:', 'g'))].length !== count)
			throw new Error('Duplicate or escaped failure-stage field.');
	}
	const codes = new Set(),
		symbols = new Set();
	for (const row of rows) {
		if (
			Object.keys(row).sort().join() !== 'code,reasons,symbol' ||
			typeof row.symbol !== 'string' ||
			typeof row.code !== 'string' ||
			!/^[a-z][A-Za-z0-9]{0,63}$/.test(row.symbol) ||
			!/^native_[a-z_]{1,63}$/.test(row.code) ||
			codes.has(row.code) ||
			symbols.has(row.symbol) ||
			!Array.isArray(row.reasons) ||
			row.reasons.length < 1 ||
			row.reasons.length > 32 ||
			new Set(row.reasons).size !== row.reasons.length ||
			row.reasons.some(
				(value) =>
					typeof value !== 'string' || !/^[a-z_]{1,32}$/.test(value) || value === 'complete'
			)
		)
			throw new Error('Invalid closed failure-stage row.');
		codes.add(row.code);
		symbols.add(row.symbol);
	}
	const swift =
		'enum ManagedHTTPFailureStage: String, CaseIterable {\n' +
		rows.map((row) => `\tcase ${row.symbol} = ${JSON.stringify(row.code)}\n`).join('') +
		'\n\tfunc permits(reason: String) -> Bool {\n\t\tswitch self {\n' +
		rows
			.map(
				(row) =>
					`\t\tcase .${row.symbol}: return [${row.reasons.map((value) => JSON.stringify(value)).join(', ')}].contains(reason)\n`
			)
			.join('') +
		'\t\t}\n\t}\n}\n';
	const python =
		'FAILURE_STAGES = {\n' +
		rows
			.map((row) =>
				row.reasons.length === 1
					? `    ${JSON.stringify(row.code)}: frozenset([${JSON.stringify(row.reasons[0])}]),\n`
					: `    ${JSON.stringify(row.code)}: frozenset(\n        [\n${row.reasons.map((value) => `            ${JSON.stringify(value)},\n`).join('')}        ]\n    ),\n`
			)
			.join('') +
		'}\n';
	const go =
		'func validNativeFailureStage(stage, reason string) bool {\n\tswitch stage {\n' +
		rows
			.map(
				(row) =>
					`\tcase ${JSON.stringify(row.code)}:\n\t\tswitch reason {\n\t\tcase ${row.reasons.map((value) => JSON.stringify(value)).join(', ')}:\n\t\t\treturn true\n\t\t}\n`
			)
			.join('') +
		'\t}\n\treturn false\n}\n\n';
	return { swift, python, go };
}
function rewrite(source, name, generated) {
	const comment = name === 'python' ? '#' : '//';
	const begin = `${comment} BEGIN ${MARKER}\n`;
	const end = `${comment} END ${MARKER}\n`;
	if (source.split(begin).length !== 2 || source.split(end).length !== 2)
		throw new Error('Failure-stage generation markers are missing or repeated.');
	const left = source.indexOf(begin) + begin.length;
	const right = source.indexOf(end);
	if (right < left) throw new Error('Failure-stage generation markers are reversed.');
	const attribution = `${comment} Generated from ${SOURCE}; do not edit this span.\n`;
	return source.slice(0, left) + attribution + generated + source.slice(right);
}
function main() {
	const rendered = render(fs.readFileSync(path.join(ROOT, SOURCE)));
	for (const [name, relative] of Object.entries(OUTPUTS)) {
		const destination = path.join(ROOT, relative);
		const current = fs.readFileSync(destination, 'utf8');
		const expected = rewrite(current, name, rendered[name]);
		if (process.argv.includes('--check')) {
			if (current !== expected) throw new Error('Failure-stage generated binding drift.');
		} else {
			fs.writeFileSync(destination, expected);
		}
	}
}
if (require.main === module) main();
module.exports = { render, rewrite, OUTPUTS };
