// tools/test/linux-unit-failure-excerpt.cjs

/**
 * ==============================================================================
 * MODULE: Linux Configuration Failure Annotation
 * DESCRIPTION:
 * Extracts the complete public assertion of the fixed Configuration restore
 * fixture from a finished failed unit log. The inline failure and terminal
 * replay record must agree; incomplete or ambiguous output is refused. The
 * original reporter, unit exit status and failure artifact remain authoritative.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const { TextDecoder } = require('node:util');

const CASE = 'routes the Configuration restore row to the recommended hotstrings';
const MAX_LOG_BYTES = 32 * 1024 * 1024;
const MAX_MESSAGE_BYTES = 8 * 1024;

function refuse(reason) {
	throw new Error(reason);
}

function escapeMessage(text) {
	return text.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
}

/**
 * Requires a complete failed runner record before publishing its fixed case.
 * @param {string} log Fresh, completed linux-unit.log contents.
 * @returns {string} A single escaped GitHub notice, including its line ending.
 */
function annotation(log) {
	if (Buffer.byteLength(log, 'utf8') > MAX_LOG_BYTES) refuse('unit log exceeds the read budget');
	const footers = [
		...log.matchAll(
			/^OVERALL RESULTS:\r?\nTotal modules: ([1-9]\d*)\r?\nPassed tests:  (\d+)\r?\nFailed tests:  ([1-9]\d*)\r?\n========================================\r?\n/gm
		)
	];
	if (footers.length !== 1) refuse('expected one complete failed unit footer');
	const footer = footers[0];
	const inline = `  FAIL ${CASE} — `;
	const terminal = `  - ${CASE} : `;
	const replay = `\n    replay: luajit tests/run.lua --only "${CASE}"\n`;
	const lines = log.split('\n');
	if (lines.filter((line) => line.startsWith(inline)).length !== 1)
		refuse('expected one inline Configuration failure');
	if (lines.filter((line) => line.startsWith(terminal)).length !== 1)
		refuse('expected one terminal Configuration failure');
	const start = log.indexOf(terminal);
	if (start < footer.index + footer[0].length)
		refuse('Configuration detail precedes the unit footer');
	const end = log.indexOf(replay, start + terminal.length);
	if (end === -1 || log.indexOf(replay, end + replay.length) !== -1)
		refuse('expected one complete Configuration replay');
	const detail = log.slice(start + terminal.length, end);
	if (!/^test_hotstrings_scope\.lua:[1-9]\d*: \S/.test(detail))
		refuse('assertion does not name the Configuration fixture');
	if (/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/.test(detail))
		refuse('assertion contains unsupported control bytes');
	const inlineStart = log.indexOf(inline);
	if (inlineStart >= footer.index || !log.startsWith(`${inline}${detail}\n`, inlineStart))
		refuse('inline and terminal assertions disagree');
	const completeReporter =
		/^\[report:linux-lua\] \x1b\[31mFAIL\x1b\[0m — ([\d\u202F]+) passed, ([\d\u202F]+) failed \(exit 1, format lua\)\.\n$/;
	if ([...log.matchAll(/^\[report:linux-lua\][^\n]*\n/gm)].length !== 1)
		refuse('expected one completed reporter receipt');
	const reporter = log.slice(end + replay.length).match(/\[report:linux-lua\][^\n]*\n$/);
	const receipt = reporter && reporter[0].match(completeReporter);
	if (
		!receipt ||
		Number(receipt[1].replace(/\u202F/g, '')) !== Number(footer[2]) ||
		Number(receipt[2].replace(/\u202F/g, '')) !== Number(footer[3])
	)
		refuse('completed reporter failure receipt is missing or inconsistent');
	const message = escapeMessage(`${CASE}\n${detail}`);
	if (Buffer.byteLength(message, 'utf8') > MAX_MESSAGE_BYTES)
		refuse('complete assertion exceeds the annotation budget');
	return `::notice title=linux-lua Configuration assertion::${message}\n`;
}

/**
 * Opens only a regular log, retaining read refusals as fixed public diagnostics.
 * @param {string[]} argv Exactly one current-run log path.
 * @returns {void}
 */
function main(argv) {
	let descriptor;
	try {
		if (argv.length !== 1 || !argv[0]) refuse('expected exactly one current unit log path');
		descriptor = fs.openSync(argv[0], fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
		const stat = fs.fstatSync(descriptor);
		if (!stat.isFile() || stat.size > MAX_LOG_BYTES)
			refuse('unit log is not a regular bounded file');
		const log = new TextDecoder('utf-8', { fatal: true }).decode(fs.readFileSync(descriptor));
		process.stdout.write(annotation(log));
	} catch (error) {
		const reason =
			descriptor === undefined
				? 'unit log could not be opened or arguments were refused'
				: error instanceof TypeError
					? 'unit log is not valid UTF-8'
					: error.message;
		process.stderr.write(`Configuration assertion annotation refused: ${reason}.\n`);
		process.exitCode = 2;
	} finally {
		if (descriptor !== undefined) fs.closeSync(descriptor);
	}
}

if (require.main === module) main(process.argv.slice(2));

module.exports = { annotation };
