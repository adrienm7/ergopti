// tools/test/ci-pipeline.cjs

/**
 * ==============================================================================
 * MODULE: CI Pipeline Loader
 * DESCRIPTION:
 * Loads `.github/workflows/ci.yml` and every reusable workflow it calls, in call
 * order, and slices jobs and steps out of them for the workflow contract tests.
 *
 * ROOT CAUSE ENCODED:
 * The contract tests each read ci.yml by path and sliced it with their own
 * regex, returning an empty string when a job was not found. Once the pipeline
 * was split into one reusable workflow per OS, a negative check ("appears in no
 * other job", `doesNotMatch`) would have kept passing against a file that had
 * lost the job it inspects. Every lookup here throws instead of returning
 * nothing, so a check can no longer pass vacuously.
 * The slicers read keys by column. YAML accepts any consistent indentation, so
 * a job indented by six spaces, or a quoted `'if':` key, hid a job-level
 * `continue-on-error: true` from the "every job gates its box" check while
 * GitHub still honoured it. Every layout the slicers cannot read now throws.
 *
 * FEATURES & RATIONALE:
 * 1. files() follows every `uses: ./.github/workflows/<file>.yml`, recursively,
 *    so a test reads what CI runs rather than a fixed list of paths. A called
 *    file that is missing or empty throws.
 * 2. job(id) returns the unique job body across the whole pipeline and throws
 *    on zero or several matches; locate(id) also names its file and line.
 * 3. step(body, name) returns the unique step of a job and throws when it is
 *    missing; findStep(name) does the same across the pipeline.
 * 4. Slicing is by indentation, and the layout is enforced rather than assumed:
 *    jobs at two spaces under `jobs:`, every job key at exactly four, steps at
 *    six (`- key:`), every step key at exactly eight, all keys unquoted. Lines
 *    are split on LF only, so every returned body is an exact substring of its
 *    file.
 * 5. open(root) binds the same lookups to another checkout, which is how
 *    tools/test/test-ci-pipeline.cjs proves each refusal on fixtures.
 * 6. runOf() returns a step's script line by line, and scriptBlock() with
 *    blockExits() tell whether a brace-delimited block of it ends in a given
 *    exit, so a test can require that a failure branch still fails.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const ENTRY_REL = '.github/workflows/ci.yml';

// A local reusable-workflow call; remote `owner/repo/...@ref` calls are not
// part of this repository's pipeline.
const LOCAL_CALL = /^\s+uses:\s*['"]?\.\/(\.github\/workflows\/[A-Za-z0-9._-]+\.ya?ml)['"]?\s*$/gm;
const JOB_KEY = /^ {2}([A-Za-z0-9_][A-Za-z0-9_-]*):\s*(?:#.*)?$/;
// The only key spelling field(), needsOf() and stepField() read: plain, one per
// line. A quoted, complex or flow-mapped key would be invisible to them.
const JOB_PROPERTY = /^ {4}[A-Za-z_][A-Za-z0-9_-]*:(?:\s|$)/;
const STEP_HEAD = /^ {6}- [A-Za-z_][A-Za-z0-9_-]*:(?:\s|$)/;
const STEP_PROPERTY = /^ {8}[A-Za-z_][A-Za-z0-9_-]*:(?:\s|$)/;
const BLOCK_SCALAR = /^[>|][-+]?$/;

/** Returns the column of the first non-space character, or -1 for a blank line. */
function indentOf(line) {
	if (line.trim() === '') return -1;
	return line.length - line.trimStart().length;
}

/** True for a full-line YAML comment. */
function isComment(line) {
	return line.trimStart().startsWith('#');
}

/** Escapes a literal for use inside a RegExp. */
function escapeRegExp(value) {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Throws a loader error that names the pipeline. */
function fail(message) {
	throw new Error(`[ci-pipeline] ${message}`);
}

/**
 * Drops trailing blank lines, and trailing comments indented at most `maxIndent`,
 * which belong to whatever follows.
 * @param {string[]} lines
 * @param {number} maxIndent
 * @returns {string[]}
 */
function trimTrailing(lines, maxIndent) {
	let end = lines.length;
	while (end > 0) {
		const line = lines[end - 1];
		const ind = indentOf(line);
		if (ind === -1 || (isComment(line) && ind <= maxIndent)) {
			end--;
			continue;
		}
		break;
	}
	return lines.slice(0, end);
}

/**
 * Reads one key of a mapping whose keys sit at a fixed column, folding a block
 * scalar onto one line. Returns null when the key is absent.
 * @param {string[]} lines
 * @param {RegExp} marker Matches the key line; its last non-empty group is the inline value.
 * @param {number} keyIndent Column of the mapping's keys.
 * @param {string} what Description for the duplicate-key error.
 * @returns {string|null}
 */
function readKey(lines, marker, keyIndent, what) {
	const at = lines
		.map((line, index) => (!isComment(line) && marker.test(line) ? index : -1))
		.filter((index) => index >= 0);
	if (at.length === 0) return null;
	if (at.length > 1) fail(`${what} appears ${at.length} times`);
	const match = marker.exec(lines[at[0]]);
	const inline = match
		.slice(1)
		.find((group) => group !== undefined)
		.trim();
	if (inline !== '' && !BLOCK_SCALAR.test(inline)) return inline;
	const folded = [];
	for (let index = at[0] + 1; index < lines.length; index++) {
		const ind = indentOf(lines[index]);
		if (ind === -1) continue;
		if (ind <= keyIndent) break;
		folded.push(lines[index].trim());
	}
	return folded.join(' ');
}

// ===============================
// ===============================
// ======= 1/ Slice The Jobs =====
// ===============================
// ===============================

/**
 * Splits a workflow text into its jobs, refusing any layout the job checks
 * cannot read. A test also uses it on a mutated copy of a pipeline file to
 * prove its own check can fail.
 * @param {string} source Workflow YAML.
 * @param {string} rel The path to report.
 * @returns {Array<{id: string, file: string, line: number, body: string}>}
 */
function jobsOfText(source, rel) {
	const lines = source.split('\n');
	const jobsAt = lines.findIndex((line) => /^jobs:\s*$/.test(line));
	if (jobsAt < 0) fail(`${rel} has no top-level jobs: block`);
	const found = [];
	let current = null;
	const close = (end) => {
		if (!current) return;
		if (current.properties === 0)
			fail(`${rel}:${current.line}: job '${current.id}' has no job-level key`);
		current.body = trimTrailing(lines.slice(current.start, end), 2).join('\n');
		delete current.start;
		delete current.properties;
		found.push(current);
		current = null;
	};
	let index = jobsAt + 1;
	for (; index < lines.length; index++) {
		const line = lines[index];
		const ind = indentOf(line);
		if (ind === -1 || isComment(line)) continue;
		if (ind === 0) break;
		const where = `${rel}:${index + 1}`;
		if (ind < 4) {
			const key = JOB_KEY.exec(line);
			if (ind !== 2 || !key)
				fail(`${where}: expected a job key at two spaces, got '${line.trim()}'`);
			close(index);
			current = { id: key[1], file: rel, line: index + 1, start: index + 1, properties: 0 };
			continue;
		}
		if (!current) fail(`${where}: '${line.trim()}' is indented under jobs: before any job key`);
		// YAML takes the first key's column for the whole job; the checks read
		// job keys at four spaces only, so any other column would hide them.
		if (current.properties === 0 && ind !== 4) {
			fail(
				`${where}: job '${current.id}' starts its keys at ${ind} spaces; job keys must sit at exactly 4`
			);
		}
		if (ind === 4) {
			if (!JOB_PROPERTY.test(line)) {
				fail(
					`${where}: job '${current.id}' has a job-level line the checks cannot read: '${line.trim()}'; ` +
						'write each job key plain and on its own line'
				);
			}
			current.properties++;
		}
	}
	close(index);
	if (found.length === 0) fail(`${rel} declares no job`);
	return found;
}

/**
 * Returns the value of a job-level key (four-space indent), folding a block
 * scalar onto one line, or null when the job does not set it.
 * @param {string} body Job body from job().
 * @param {string} key Key name, such as `if` or `runs-on`.
 * @returns {string|null}
 */
function field(body, key) {
	const marker = new RegExp(`^ {4}${escapeRegExp(key)}:(.*)$`);
	return readKey(body.split('\n'), marker, 4, `job key '${key}' in one job`);
}

/**
 * Returns the job ids a job needs, from a scalar, a flow list or a block list.
 * @param {string} body Job body from job().
 * @returns {string[]}
 */
function needsOf(body) {
	const lines = body.split('\n');
	const at = lines.findIndex((line) => /^ {4}needs:/.test(line));
	if (at < 0) return [];
	const inline = lines[at].replace(/^ {4}needs:/, '').trim();
	if (inline.startsWith('[')) {
		if (!inline.endsWith(']')) fail(`multi-line flow list in needs: ${inline}`);
		return inline
			.slice(1, -1)
			.split(',')
			.map((entry) => entry.trim())
			.filter(Boolean);
	}
	if (inline !== '') return [inline];
	const listed = [];
	for (let index = at + 1; index < lines.length; index++) {
		const ind = indentOf(lines[index]);
		if (ind === -1) continue;
		if (ind <= 4) break;
		const entry = /^\s+-\s*([A-Za-z0-9_-]+)\s*$/.exec(lines[index]);
		if (!entry) fail(`unreadable needs entry: ${lines[index].trim()}`);
		listed.push(entry[1]);
	}
	return listed;
}

// ================================
// ================================
// ======= 2/ Slice The Steps =====
// ================================
// ================================

/**
 * Splits a job body into its steps, refusing any layout the step checks cannot
 * read.
 * @param {string} body Job body from job().
 * @returns {Array<{name: string, body: string}>}
 */
function steps(body) {
	const lines = body.split('\n');
	const at = lines.findIndex((line) => /^ {4}steps:\s*$/.test(line));
	if (at < 0) return [];
	let end = lines.length;
	for (let index = at + 1; index < lines.length; index++) {
		const ind = indentOf(lines[index]);
		if (ind !== -1 && ind <= 4 && !isComment(lines[index])) {
			end = index;
			break;
		}
	}
	const found = [];
	let start = -1;
	const close = (stop) => {
		if (start < 0) return;
		const stepLines = trimTrailing(lines.slice(start, stop), 6);
		const named = stepLines.find((line, index) =>
			index === 0 ? /^ {6}-\s+name:/.test(line) : /^ {8}name:/.test(line)
		);
		const name = named
			? named
					.replace(/^\s*-?\s*name:\s*/, '')
					.trim()
					.replace(/^(['"])(.*)\1$/, '$2')
			: '';
		found.push({ name, body: stepLines.join('\n') });
	};
	for (let index = at + 1; index < end; index++) {
		const line = lines[index];
		const ind = indentOf(line);
		if (ind === -1 || isComment(line)) continue;
		// A step's first key fixes the column of all its keys: `- key:` at six
		// spaces puts them at eight, the only column stepField() reads.
		if (ind === 6) {
			if (!STEP_HEAD.test(line))
				fail(`a step must start as '- key:' at six spaces, got '${line.trim()}'`);
			close(index);
			start = index;
			continue;
		}
		if (ind < 8) fail(`a steps line at ${ind} spaces: '${line.trim()}'`);
		if (start < 0) fail(`'${line.trim()}' sits under steps: before the first step`);
		if (ind === 8 && !STEP_PROPERTY.test(line)) {
			fail(
				`a step line the checks cannot read: '${line.trim()}'; write each step key plain and on its own line`
			);
		}
	}
	close(end);
	return found;
}

/**
 * Returns the unique step named `name` in a job body.
 * @param {string} body Job body from job().
 * @param {string} name Exact step name.
 * @returns {string}
 */
function step(body, name) {
	const matches = steps(body).filter((candidate) => candidate.name === name);
	if (matches.length === 0) fail(`no step named '${name}' in this job`);
	if (matches.length > 1) fail(`step '${name}' appears ${matches.length} times in one job`);
	return matches[0].body;
}

/**
 * Returns the value of a step-level key, such as `if` or `continue-on-error`,
 * folding a block scalar onto one line, or null when the step does not set it.
 * @param {string} body Step body from step() or steps().
 * @param {string} key Key name.
 * @returns {string|null}
 */
function stepField(body, key) {
	const escaped = escapeRegExp(key);
	const marker = new RegExp(`^ {6}- ${escaped}:(.*)$|^ {8}${escaped}:(.*)$`);
	return readKey(body.split('\n'), marker, 8, `step key '${key}' in one step`);
}

/**
 * Returns the script of a step's `run:` key line by line, dedented and not
 * folded, or null when the step runs no script. An inline value is one line.
 * @param {string} body Step body from step() or steps().
 * @returns {string[]|null}
 */
function runOf(body) {
	const lines = body.split('\n');
	const at = lines.findIndex((line) => /^ {6}- run:|^ {8}run:/.test(line));
	if (at < 0) return null;
	const inline = lines[at].replace(/^\s*-?\s*run:/, '').trim();
	if (inline !== '' && !BLOCK_SCALAR.test(inline)) return [inline];
	const block = [];
	for (let index = at + 1; index < lines.length; index++) {
		const ind = indentOf(lines[index]);
		if (ind !== -1 && ind <= 8) break;
		block.push(lines[index]);
	}
	const first = block.find((line) => line.trim() !== '');
	if (!first) fail(`step '${lines[0].trim()}' has an empty run: script`);
	const indent = indentOf(first);
	return trimTrailing(
		block.map((line) => line.slice(indent)),
		-1
	);
}

// ======================================
// ======================================
// ======= 3/ Read A Script =============
// ======================================
// ======================================

/**
 * Returns the brace-delimited block that opens on the unique line of `lines`
 * starting with `opener`: that line alone when the block also closes on it,
 * otherwise every line up to the closing brace at the opener's own column.
 * @param {string[]} lines Script lines, such as runOf() returns.
 * @param {string} opener Start of the opening line, such as `if ($exit -ne 0) {`.
 * @returns {string[]}
 */
function scriptBlock(lines, opener) {
	const at = lines
		.map((line, index) => (line.trimStart().startsWith(opener) ? index : -1))
		.filter((index) => index >= 0);
	if (at.length !== 1)
		fail(`expected one script line starting with '${opener}', found ${at.length}`);
	const start = at[0];
	if (lines[start].trimEnd().endsWith('}')) return [lines[start]];
	const indent = indentOf(lines[start]);
	for (let index = start + 1; index < lines.length; index++) {
		if (indentOf(lines[index]) === indent && lines[index].trim() === '}')
			return lines.slice(start, index + 1);
	}
	fail(`the block opened by '${opener}' never closes at its own column`);
}

/**
 * True when the last statement of a block from scriptBlock() is `exit <code>`,
 * alone on its line or after a `;`.
 * @param {string[]} block Block lines, opener and closing brace included.
 * @param {string} code Literal exit code or variable, such as `1` or `$exit`.
 * @returns {boolean}
 */
function blockExits(block, code) {
	const last =
		block.length === 1
			? block[0].replace(/^[^{]*\{/, '').replace(/\}\s*$/, '')
			: (block
					.slice(1, -1)
					.filter((line) => line.trim() !== '' && !isComment(line))
					.at(-1) ?? '');
	return new RegExp(`(?:^|;)\\s*exit ${escapeRegExp(code)}$`).test(last.trim());
}

// ======================================
// ======================================
// ======= 4/ Load A Pipeline ===========
// ======================================
// ======================================

/**
 * Binds the pipeline lookups to one checkout. The files are read once, on the
 * first lookup.
 * @param {string} root Absolute path of the checkout.
 * @returns {object} The lookups: files, file, text, jobs, locate, job, textWithout, findStep, calls.
 */
function open(root) {
	let cache = null;

	/** Reads one workflow of the pipeline, refusing a missing or empty file. */
	const readWorkflow = (rel, caller) => {
		const abs = path.join(root, rel);
		if (!fs.existsSync(abs)) fail(`${rel} (called from ${caller}) does not exist`);
		const text = fs.readFileSync(abs, 'utf8');
		if (text.trim() === '') fail(`${rel} (called from ${caller}) is empty`);
		if (!/^jobs:\s*$/m.test(text)) fail(`${rel} has no top-level jobs: block`);
		return text;
	};

	/** Loads ci.yml and every workflow it calls, depth first, in call order. */
	const load = () => {
		if (cache) return cache;
		const loaded = [];
		const seen = new Set();
		const visit = (rel, caller) => {
			if (seen.has(rel)) return;
			seen.add(rel);
			const text = readWorkflow(rel, caller);
			loaded.push({ rel, text });
			for (const match of text.matchAll(LOCAL_CALL)) visit(match[1], rel);
		};
		visit(ENTRY_REL, 'the repository');
		if (loaded.length < 2)
			fail(`${ENTRY_REL} calls no reusable workflow; the pipeline layout changed`);
		cache = loaded;
		return loaded;
	};

	/**
	 * Returns every pipeline file, ci.yml first, then the called workflows in call order.
	 * @returns {Array<{rel: string, text: string}>}
	 */
	const files = () => load().map((entry) => ({ ...entry }));

	/**
	 * Returns the text of one pipeline file.
	 * @param {string} rel Repository-relative path, such as `.github/workflows/ci-linux.yml`.
	 * @returns {string}
	 */
	const file = (rel) => {
		const entry = load().find((candidate) => candidate.rel === rel);
		if (!entry) {
			fail(
				`${rel} is not part of the pipeline (${load()
					.map((candidate) => candidate.rel)
					.join(', ')})`
			);
		}
		return entry.text;
	};

	/**
	 * Returns the whole pipeline as one text, in call order.
	 * @returns {string}
	 */
	const text = () =>
		load()
			.map((entry) => entry.text)
			.join('\n');

	/**
	 * Splits one pipeline file into its jobs.
	 * @param {string} rel Repository-relative path of a pipeline file.
	 * @returns {Array<{id: string, file: string, line: number, body: string}>}
	 */
	const jobs = (rel) => jobsOfText(file(rel), rel);

	/**
	 * Locates the unique job `id` across the pipeline.
	 * @param {string} id Job id.
	 * @returns {{id: string, file: string, line: number, body: string}}
	 */
	const locate = (id) => {
		const matches = load()
			.flatMap((entry) => jobs(entry.rel))
			.filter((candidate) => candidate.id === id);
		if (matches.length === 0) fail(`no job '${id}' in the pipeline`);
		if (matches.length > 1) {
			fail(
				`job '${id}' is defined ${matches.length} times: ${matches.map((m) => `${m.file}:${m.line}`).join(', ')}`
			);
		}
		return matches[0];
	};

	/**
	 * Returns the body of the unique job `id`, without its key line.
	 * @param {string} id Job id.
	 * @returns {string}
	 */
	const job = (id) => locate(id).body;

	/**
	 * Returns the whole pipeline with the body of job `id` removed.
	 * @param {string} id Job id.
	 * @returns {string}
	 */
	const textWithout = (id) => {
		const target = locate(id);
		return load()
			.map((entry) =>
				entry.rel === target.file ? entry.text.replace(target.body, '') : entry.text
			)
			.join('\n');
	};

	/**
	 * Finds the unique step named `name` anywhere in the pipeline.
	 * @param {string} name Exact step name.
	 * @returns {{file: string, job: string, body: string}}
	 */
	const findStep = (name) => {
		const matches = [];
		for (const entry of load()) {
			for (const candidate of jobs(entry.rel)) {
				for (const found of steps(candidate.body)) {
					if (found.name === name)
						matches.push({ file: entry.rel, job: candidate.id, body: found.body });
				}
			}
		}
		if (matches.length === 0) fail(`no step named '${name}' in the pipeline`);
		if (matches.length > 1) {
			fail(
				`step '${name}' appears ${matches.length} times: ${matches.map((m) => `${m.file} ${m.job}`).join(', ')}`
			);
		}
		return matches[0];
	};

	/**
	 * Returns the reusable-workflow calls of one pipeline file, in order.
	 * @param {string} rel Repository-relative path, ci.yml by default.
	 * @returns {Array<{id: string, uses: string}>}
	 */
	const calls = (rel = ENTRY_REL) =>
		jobs(rel)
			.map((candidate) => ({ id: candidate.id, uses: field(candidate.body, 'uses') }))
			.filter((candidate) => candidate.uses !== null);

	return { files, file, text, jobs, locate, job, textWithout, findStep, calls };
}

module.exports = {
	ROOT,
	ENTRY_REL,
	open,
	jobsOfText,
	field,
	needsOf,
	steps,
	step,
	stepField,
	runOf,
	scriptBlock,
	blockExits,
	...open(ROOT)
};
