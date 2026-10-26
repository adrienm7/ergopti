// tools/test/linux-unit-failure-excerpt.cjs

/**
 * ==============================================================================
 * MODULE: Linux Unit Failure Annotations
 * DESCRIPTION:
 * Publishes the complete assertion of every failed case of a finished failed
 * Linux unit log as one GitHub notice each. The reporter annotates test names
 * only; the runner's terminal summary holds the full assertion and its replay
 * command. The footer count, the summary records and the reporter receipt
 * must agree; incomplete or ambiguous output is refused. The original
 * reporter, unit exit status and failure artifact remain authoritative.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const { TextDecoder } = require('node:util');

const MAX_LOG_BYTES = 32 * 1024 * 1024;
const MAX_MESSAGE_BYTES = 8 * 1024;
const FOOTER = 'OVERALL RESULTS:';
const RECORD = '  - ';
const REPLAY = '    replay: luajit tests/run.lua';
const REPORTER = '[report:linux-lua] ';

const strict = new TextDecoder('utf-8', { fatal: true });

function refuse(reason) {
	throw new Error(reason);
}

/**
 * Splits raw bytes into complete lines without decoding unrelated output.
 * @param {Buffer} bytes The fresh unit log.
 * @returns {Buffer[]} Lines without their newline.
 */
function rawLines(bytes) {
	if (bytes.length === 0 || bytes[bytes.length - 1] !== 10) refuse('unit log is unfinished');
	const lines = [];
	for (let start = 0; start < bytes.length; ) {
		const newline = bytes.indexOf(10, start);
		lines.push(bytes.subarray(start, newline));
		start = newline + 1;
	}
	return lines;
}

function startsWith(line, text) {
	const prefix = Buffer.from(text, 'utf8');
	return line.length >= prefix.length && line.subarray(0, prefix.length).equals(prefix);
}

/**
 * Strictly decodes one selected line; unrelated fixture output is never decoded.
 * @param {Buffer} line One raw line.
 * @returns {string} Its text without a carriage return.
 */
function decode(line) {
	try {
		return strict.decode(line).replace(/\r$/, '');
	} catch {
		return refuse('unit log is not valid UTF-8');
	}
}

/**
 * Reverses run.lua's shell_quote of one --only argument.
 * @param {string} quoted A single-quoted POSIX word.
 * @returns {string} The original case name.
 */
function unquote(quoted) {
	const match = /^'((?:[^']|'\\'')*)'$/.exec(quoted);
	if (!match) refuse('replay case name is not one quoted word');
	return match[1].replaceAll("'\\''", "'");
}

/**
 * Renders control bytes visibly so a notice can never carry a hidden command.
 * @param {string} text Decoded assertion text.
 * @returns {string} Text whose only line breaks are \n and whose controls read \xNN.
 */
function visible(text) {
	return text.replace(
		/[\x00-\x08\x0B-\x1F\x7F]/g,
		(ch) => '\\x' + ch.charCodeAt(0).toString(16).padStart(2, '0')
	);
}

function escapeMessage(text) {
	return text.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
}

/**
 * Bounds one notice, stating the cut instead of dropping the record.
 * @param {string} name Failed case name.
 * @param {string} detail Complete assertion.
 * @returns {string} Escaped message within MAX_MESSAGE_BYTES.
 */
function boundedMessage(name, detail) {
	const whole = escapeMessage(visible(`${name}\n${detail}`));
	if (Buffer.byteLength(whole, 'utf8') <= MAX_MESSAGE_BYTES) return whole;
	const characters = [...detail];
	const total = Buffer.byteLength(detail, 'utf8');
	const cut = (count) => {
		const shown = characters.slice(0, count).join('');
		const note = `[assertion truncated: ${Buffer.byteLength(shown, 'utf8')} of ${total} bytes shown; the failed unit log artifact keeps it whole]`;
		return escapeMessage(visible(`${name}\n${shown}\n${note}`));
	};
	let low = 0;
	let high = characters.length;
	while (low < high) {
		const middle = Math.ceil((low + high) / 2);
		if (Buffer.byteLength(cut(middle), 'utf8') <= MAX_MESSAGE_BYTES) low = middle;
		else high = middle - 1;
	}
	const result = cut(low);
	if (Buffer.byteLength(result, 'utf8') > MAX_MESSAGE_BYTES)
		refuse('failed case name exceeds the annotation budget');
	return result;
}

/**
 * Selects the terminal failure records of a finished failed unit log.
 * @param {Buffer} bytes The fresh unit log, without transport normalization.
 * @returns {Array<{name: string, detail: string}>} One entry per failed case, in runner order.
 */
function failures(bytes) {
	if (bytes.length > MAX_LOG_BYTES) refuse('unit log exceeds the read budget');
	const lines = rawLines(bytes);
	const footers = lines.flatMap((line, index) => (startsWith(line, FOOTER) ? [index] : []));
	if (footers.length !== 1) refuse('expected one complete failed unit footer');
	const footerAt = footers[0];
	if (footerAt + 5 > lines.length) refuse('selected unit footer is incomplete');
	const footer = lines
		.slice(footerAt, footerAt + 5)
		.map(decode)
		.join('\n');
	const counts =
		/^OVERALL RESULTS:\nTotal modules: [1-9]\d*\nPassed tests: {2}(\d+)\nFailed tests: {2}([1-9]\d*)\n=+$/.exec(
			footer
		);
	if (!counts) refuse('expected one complete failed unit footer');
	// The runner prints each failure as "  - name : assertion" (the assertion may
	// span lines) closed by its replay command, then the reporter its receipt.
	const records = [];
	let current = null;
	let receipt = null;
	for (let index = footerAt + 5; index < lines.length && receipt === null; index++) {
		const line = lines[index];
		if (startsWith(line, REPORTER)) receipt = decode(line);
		else if (current && startsWith(line, REPLAY)) {
			current.replay = decode(line).slice(REPLAY.length);
			records.push(current);
			current = null;
		} else if (current) current.lines.push(decode(line));
		else if (startsWith(line, RECORD)) current = { lines: [decode(line)], replay: null };
	}
	if (current) refuse('a failure record has no replay command');
	const reporter =
		receipt &&
		/^\[report:linux-lua\] \x1b\[31mFAIL\x1b\[0m — ([\d\u202F ]+) passed, ([\d\u202F ]+) failed \(exit 1, format lua\)\.$/.exec(
			receipt
		);
	const number = (text) => Number(text.replace(/[\u202F ]/g, ''));
	if (
		!reporter ||
		number(reporter[1]) !== Number(counts[1]) ||
		number(reporter[2]) !== Number(counts[2])
	)
		refuse('completed reporter failure receipt is missing or inconsistent');
	if (records.length !== Number(counts[2]))
		refuse('failure records disagree with the failed test count');
	return records.map((record) => {
		const replay = /^(?: --module=[a-z_]+)?(?: --only (.+))?$/.exec(record.replay);
		if (!replay) refuse('replay command is not the runner replay');
		const first = record.lines[0].slice(RECORD.length);
		let name;
		let rest;
		if (replay[1] === undefined) {
			// A module load error has no --only; its name is a dotted module path.
			const split = first.indexOf(' : ');
			if (split < 1) refuse('failure record has no assertion');
			name = first.slice(0, split);
			rest = first.slice(split + 3);
		} else {
			name = unquote(replay[1]);
			if (!first.startsWith(`${name} : `)) refuse('failure record and replay name disagree');
			rest = first.slice(name.length + 3);
		}
		const detail = [rest, ...record.lines.slice(1)].join('\n');
		if (detail.trim() === '') refuse('failure record has no assertion');
		return { name, detail };
	});
}

/**
 * Renders one GitHub notice per failed case.
 * @param {Buffer} bytes The fresh unit log.
 * @returns {string} Notices, each with its line ending.
 */
function annotations(bytes) {
	return failures(bytes)
		.map(
			({ name, detail }) =>
				`::notice title=linux-lua failed case::${boundedMessage(name, detail)}\n`
		)
		.join('');
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
		process.stdout.write(annotations(fs.readFileSync(descriptor)));
	} catch (error) {
		const reason =
			descriptor === undefined
				? 'unit log could not be opened or arguments were refused'
				: error.message;
		process.stderr.write(`Failed unit assertion annotation refused: ${reason}.\n`);
		process.exitCode = 2;
	} finally {
		if (descriptor !== undefined) fs.closeSync(descriptor);
	}
}

if (require.main === module) main(process.argv.slice(2));

module.exports = { annotations, failures };
