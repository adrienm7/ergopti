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
 *    on zero or several matches (but see 7); locate(id) also names its file
 *    and line.
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
 * 7. A lane delegates each stage to a workflow of its own, called by a job
 *    that keeps the stage job's id, so the lane's `toJSON(needs)` still names
 *    the jobs the receipt chain admits. That is the one duplicate id accepted:
 *    a caller whose `uses:` is the file defining the other job as its only
 *    job. job(id) and locate(id) then return the stage job, caller(id) and
 *    locateCaller(id) the calling job; laneFiles(rel) and laneJobs(rel) read a
 *    lane together with every stage file it calls.
 * 8. The default lookups read every lane inlined (inlineLane): its stage jobs
 *    as one workflow, each under its caller's name, needs and if, with every
 *    value the caller hands in read back from where it comes. The inliner is
 *    the single owner of the stage-call contract and refuses any wiring a
 *    stage could receive differently from the lane (an input not passed or
 *    passed in another form, an output not re-exported, a secret renamed,
 *    permissions or env that differ, a stage job with its own needs or if).
 *    The contract tests therefore read each lane as one workflow and still
 *    fail when a stage or a step disappears; real() reads the files as they
 *    are, for the checks of the layout itself.
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
// ======= 4/ Resolve A Stage Caller ====
// ======================================
// ======================================

/**
 * Resolves every job of one id across the pipeline to the job the lookups
 * return. One job is returned as is. Two are accepted only as a stage caller
 * and its stage: the caller's `uses:` names the stage's file, and that file
 * defines no other job, so the caller can only ever run that stage.
 * @param {string} id Job id.
 * @param {Array<{id: string, file: string, line: number, body: string}>} matches Jobs with that id.
 * @param {(rel: string) => Array<{id: string}>} jobsOf Jobs of one pipeline file.
 * @returns {{stage: object, caller: object|null}}
 */
function resolveJob(id, matches, jobsOf) {
	if (matches.length === 0) fail(`no job '${id}' in the pipeline`);
	if (matches.length === 1) {
		const only = matches[0];
		return field(only.body, 'uses') === null
			? { stage: only, caller: null }
			: { stage: only, caller: only };
	}
	const where = matches.map((m) => `${m.file}:${m.line}`).join(', ');
	const callers = matches.filter((m) => field(m.body, 'uses') !== null);
	const stages = matches.filter((m) => field(m.body, 'uses') === null);
	if (matches.length !== 2 || callers.length !== 1 || stages.length !== 1)
		fail(`job '${id}' is defined ${matches.length} times: ${where}`);
	const [caller] = callers;
	const [stage] = stages;
	if (field(caller.body, 'uses') !== `./${stage.file}`) {
		fail(
			`job '${id}' is defined 2 times: ${where}; a caller may share an id only with the job of the file it calls`
		);
	}
	const siblings = jobsOf(stage.file).map((job) => job.id);
	if (siblings.length !== 1) {
		fail(
			`stage caller '${id}' calls ${stage.file}, which defines ${siblings.length} jobs (${siblings.join(', ')}); a stage file defines its one job`
		);
	}
	return { stage, caller };
}

// ======================================
// ======================================
// ======= 5/ Inline A Lane =============
// ======================================
// ======================================

/**
 * Returns the lines of a top-level `key:` block of a workflow, its key line
 * included, up to the next top-level line; null when the workflow has none.
 * @param {string[]} lines Workflow lines.
 * @param {string} key Top-level key.
 * @returns {{at: number, lines: string[]}|null}
 */
function topLevelBlock(lines, key) {
	const at = lines.findIndex((line) => line === `${key}:`);
	if (at < 0) return null;
	let end = at + 1;
	while (end < lines.length && (lines[end] === '' || /^\s/.test(lines[end]))) end++;
	while (end > at + 1 && lines[end - 1] === '') end--;
	return { at, lines: lines.slice(at, end) };
}

/**
 * Reads the declarations of one `on.workflow_call` section (inputs, outputs or
 * secrets): each name with its definition lines, in order.
 * @param {string} text Workflow text.
 * @param {string} section Section name.
 * @returns {Map<string, string[]>}
 */
function callDeclarations(text, section) {
	const on = topLevelBlock(text.split('\n'), 'on');
	const found = new Map();
	if (!on) return found;
	const at = on.lines.indexOf(`    ${section}:`);
	if (at < 0) return found;
	let current = null;
	for (let index = at + 1; index < on.lines.length; index++) {
		const line = on.lines[index];
		if (line !== '' && !/^ {6}/.test(line)) break;
		const key = /^ {6}([A-Za-z0-9_-]+):\s*$/.exec(line);
		if (key) {
			if (found.has(key[1])) fail(`${section}.${key[1]} is declared twice`);
			current = key[1];
			found.set(current, [line]);
		} else if (line !== '') {
			if (!current) fail(`unreadable ${section} declaration '${line.trim()}'`);
			found.get(current).push(line);
		}
	}
	return found;
}

/**
 * Reads a job-level mapping (`with:`, `secrets:`, `outputs:`) of one-line
 * `name: value` entries; null when the job sets none.
 * @param {string} body Job body.
 * @param {string} key Job-level key.
 * @returns {Map<string, string>|null}
 */
function jobMapping(body, key) {
	const lines = body.split('\n');
	const at = lines.findIndex((line) => line === `    ${key}:`);
	if (at < 0) return null;
	const found = new Map();
	for (let index = at + 1; index < lines.length; index++) {
		const line = lines[index];
		if (line.trim() === '' || line.trimStart().startsWith('#')) continue;
		if (indentOf(line) <= 4) break;
		const entry = /^ {6}([A-Za-z0-9_-]+): (\S.*)$/.exec(line);
		if (!entry) fail(`unreadable ${key} entry '${line.trim()}'`);
		if (found.has(entry[1])) fail(`${key}.${entry[1]} is set twice`);
		found.set(entry[1], entry[2]);
	}
	return found;
}

/** Returns the lines of one job-level key, its continuation lines included, or null. */
function jobKeyLines(body, key) {
	const lines = body.split('\n');
	const at = lines.findIndex((line) => new RegExp(`^ {4}${escapeRegExp(key)}:`).test(line));
	if (at < 0) return null;
	let end = at + 1;
	while (end < lines.length && (lines[end] === '' || indentOf(lines[end]) > 4)) end++;
	while (end > at + 1 && lines[end - 1] === '') end--;
	return lines.slice(at, end);
}

/**
 * True when `job` calls a file that defines it as its one job: a lane's stage
 * caller.
 * @param {{id: string, body: string}} job A job of a pipeline file.
 * @param {(rel: string) => string|undefined} textOf Reads a pipeline file.
 * @returns {boolean}
 */
function isStageCaller(job, textOf) {
	const uses = field(job.body, 'uses');
	if (uses === null || !uses.startsWith('./')) return false;
	const rel = uses.slice(2);
	const text = textOf(rel);
	if (text === undefined) return false;
	const inner = jobsOfText(text, rel);
	return inner.length === 1 && inner[0].id === job.id;
}

/**
 * Inlines a lane: rebuilds it as one workflow whose jobs are its stage jobs,
 * each with its caller's name, needs and if, and with every value its caller
 * hands in read back from where it comes. It refuses any wiring a stage could
 * receive differently from the lane: a stage input the caller does not pass
 * or passes in another form, an output not re-exported as is, a secret not
 * passed through, permissions or env that differ, or a stage job that sets
 * its own needs or if. A missing stage file throws; a lost stage or step is
 * missing from the inlined lane.
 * @param {string} laneRel Lane path.
 * @param {string} laneText Lane text.
 * @param {(rel: string) => string|undefined} textOf Reads a stage file.
 * @returns {string}
 */
function inlineLane(laneRel, laneText, textOf) {
	const where = (detail) => `${laneRel}: ${detail}`;
	const lines = laneText.split('\n');
	const jobsAt = lines.findIndex((line) => /^jobs:\s*$/.test(line));
	if (jobsAt < 0) fail(where('no top-level jobs: block'));
	const header = lines.slice(0, jobsAt);
	if (topLevelBlock(header, 'env')) fail(where('a lane sets no env; each stage carries it'));
	const permissions = topLevelBlock(header, 'permissions');
	if (!permissions) fail(where('a lane declares its permissions'));
	const laneInputs = callDeclarations(laneText, 'inputs');
	const laneSecrets = callDeclarations(laneText, 'secrets');
	const callers = jobsOfText(laneText, laneRel);
	let env = null;
	const out = [];
	let cursor = jobsAt + 1;
	for (const caller of callers) {
		const at = caller.line - 1;
		out.push(...lines.slice(cursor, at), lines[at]);
		cursor = at + 1 + caller.body.split('\n').length;
		const who = `stage caller '${caller.id}'`;
		const uses = field(caller.body, 'uses');
		if (uses === null) fail(where(`job '${caller.id}' runs steps; a lane only calls stages`));
		if (!isStageCaller(caller, textOf))
			fail(where(`${who} must call a file that defines '${caller.id}' as its only job`));
		const keys = caller.body
			.split('\n')
			.filter((line) => JOB_PROPERTY.test(line))
			.map((line) => line.trim().replace(/:.*$/, ''));
		const allowed = ['name', 'needs', 'if', 'uses', 'permissions', 'with', 'secrets'];
		const extra = keys.filter((key) => !allowed.includes(key));
		if (extra.length) fail(where(`${who} sets ${extra.join(', ')}; the stage job owns them`));
		// `secrets: inherit` would hand the stage every secret; each one is listed.
		for (const key of ['with', 'secrets'])
			if (field(caller.body, key) !== null && !caller.body.split('\n').includes(`    ${key}:`))
				fail(where(`${who} must list each of its ${key} on its own line`));
		const stageRel = uses.slice(2);
		const stageText = textOf(stageRel);
		const stageLines = stageText.split('\n');
		const stageJobsAt = stageLines.findIndex((line) => /^jobs:\s*$/.test(line));
		const stageHeader = stageLines.slice(0, stageJobsAt);
		// A stage adds nothing at the top: no trigger, concurrency or defaults of its own.
		const topKeys = stageHeader
			.filter((line) => /^[^\s#]/.test(line))
			.map((line) => line.replace(/:.*$/, ''));
		if (topKeys.some((key) => !['name', 'on', 'permissions', 'env'].includes(key)))
			fail(
				where(
					`${stageRel} sets ${topKeys.join(', ')}; a stage sets only name, on, permissions and env`
				)
			);
		const trigger = topLevelBlock(stageHeader, 'on');
		if (
			!trigger ||
			trigger.lines[1] !== '  workflow_call:' ||
			trigger.lines.slice(2).some((line) => /^ {2}\S/.test(line))
		)
			fail(where(`${stageRel} must be triggered by workflow_call alone`));
		const stagePermissions = topLevelBlock(stageHeader, 'permissions');
		if (!stagePermissions || stagePermissions.lines.join('\n') !== permissions.lines.join('\n'))
			fail(where(`${stageRel} must grant exactly the lane's permissions`));
		const stageEnv = topLevelBlock(stageHeader, 'env');
		const envText = stageEnv ? stageEnv.lines.join('\n') : '';
		if (env === null) env = envText;
		else if (env !== envText) fail(where(`${stageRel} must set the same env as every stage`));
		const [stage] = jobsOfText(stageText, stageRel);
		for (const key of ['needs', 'if'])
			if (field(stage.body, key) !== null)
				fail(where(`${stageRel} job '${stage.id}' sets ${key}; its caller owns it`));
		const stagePermissionLines = jobKeyLines(stage.body, 'permissions');
		const callerPermissionLines = jobKeyLines(caller.body, 'permissions');
		if (JSON.stringify(stagePermissionLines) !== JSON.stringify(callerPermissionLines))
			fail(where(`${who} must grant exactly the permissions its stage job requests`));

		// Inputs: each one the stage declares comes from the caller, in one form.
		const needs = needsOf(caller.body);
		const given = jobMapping(caller.body, 'with') ?? new Map();
		const declared = callDeclarations(stageText, 'inputs');
		if (JSON.stringify([...given.keys()].sort()) !== JSON.stringify([...declared.keys()].sort()))
			fail(where(`${who} must pass exactly the inputs ${stageRel} declares`));
		const handed = new Map();
		for (const [key, value] of given) {
			if (laneInputs.has(key)) {
				if (value !== `\${{ inputs.${key} }}`)
					fail(where(`${who} must pass ${key}: \${{ inputs.${key} }}, got ${value}`));
				if (declared.get(key).join('\n') !== laneInputs.get(key).join('\n'))
					fail(where(`${stageRel} must declare ${key} as the lane does`));
				continue;
			}
			const typed = declared.get(key).some((line) => line === '        type: string');
			if (!typed) fail(where(`${stageRel} must declare ${key} as a string`));
			if (key === 'predecessors') {
				if (value !== '${{ toJSON(needs) }}')
					fail(where(`${who} must pass predecessors: \${{ toJSON(needs) }}`));
				handed.set('predecessors', 'toJSON(needs)');
				continue;
			}
			const result = /^\$\{\{ needs\.([A-Za-z0-9_-]+)\.result \}\}$/.exec(value);
			if (key === 'predecessor_result') {
				if (!result || needs.length !== 1 || result[1] !== needs[0])
					fail(where(`${who} must pass predecessor_result from its one need`));
				handed.set(key, `needs.${result[1]}.result`);
				continue;
			}
			const output = /^\$\{\{ needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+) \}\}$/.exec(value);
			if (!output || output[2] !== key || !needs.includes(output[1]))
				fail(where(`${who} must pass ${key} from the same output of one of its needs`));
			handed.set(key, `needs.${output[1]}.outputs.${key}`);
		}
		// Secrets pass through by name.
		const passed = jobMapping(caller.body, 'secrets') ?? new Map();
		const stageSecrets = callDeclarations(stageText, 'secrets');
		if (
			JSON.stringify([...passed.keys()].sort()) !== JSON.stringify([...stageSecrets.keys()].sort())
		)
			fail(where(`${who} must pass exactly the secrets ${stageRel} declares`));
		for (const [key, value] of passed) {
			if (value !== `\${{ secrets.${key} }}` || !laneSecrets.has(key))
				fail(where(`${who} must pass the lane's secret ${key} as is`));
			if (stageSecrets.get(key).join('\n') !== laneSecrets.get(key).join('\n'))
				fail(where(`${stageRel} must declare ${key} as the lane does`));
		}
		// Outputs are re-exported under their own names.
		const jobOutputs = jobMapping(stage.body, 'outputs') ?? new Map();
		const exported = callDeclarations(stageText, 'outputs');
		if (JSON.stringify([...jobOutputs.keys()]) !== JSON.stringify([...exported.keys()]))
			fail(where(`${stageRel} must re-export exactly the outputs of '${stage.id}'`));
		for (const [key, lines_] of exported) {
			if (!lines_.includes(`        value: \${{ jobs.${stage.id}.outputs.${key} }}`))
				fail(where(`${stageRel} must re-export ${key} as is`));
		}

		// The stage job, read back into the lane.
		const stageBody = stage.body.split('\n');
		const nameAt = stageBody.findIndex((line) => /^ {4}name:/.test(line));
		if (nameAt !== 0) fail(where(`${stageRel} job '${stage.id}' must start with its name`));
		const restored = [
			...jobKeyLines(caller.body, 'name'),
			...(jobKeyLines(caller.body, 'needs') ?? []),
			...(jobKeyLines(caller.body, 'if') ?? []),
			...stageBody.slice(1)
		].join('\n');
		// The inputs context only: not steps.native-pac-inputs.outputs.
		const read = restored.replace(/(?<![\w.-])inputs\.([A-Za-z0-9_-]+)\b/g, (match, key) => {
			if (laneInputs.has(key)) return match;
			if (!handed.has(key)) fail(where(`${stageRel} reads inputs.${key}, which nothing passes`));
			return handed.get(key);
		});
		out.push(read);
	}
	out.push(...lines.slice(cursor));
	const head = [...header];
	if (env) head.splice(permissions.at + permissions.lines.length, 0, '', ...env.split('\n'));
	return [...head, 'jobs:', ...out].join('\n');
}

/**
 * Rebuilds a pipeline with every lane inlined: stage files are folded into the
 * lane that calls them, so the result reads as one workflow per lane.
 * @param {Array<{rel: string, text: string}>} loaded Pipeline files in call order.
 * @returns {Array<{rel: string, text: string}>}
 */
function inlinePipeline(loaded) {
	const textOf = (rel) => loaded.find((entry) => entry.rel === rel)?.text;
	const stages = new Set();
	const lanes = new Set();
	for (const entry of loaded) {
		const jobs = jobsOfText(entry.text, entry.rel);
		const staged = jobs.filter((job) => isStageCaller(job, textOf));
		if (staged.length === 0) continue;
		if (staged.length !== jobs.length)
			fail(`${entry.rel} mixes stage callers with other jobs; a lane only calls stages`);
		lanes.add(entry.rel);
		for (const job of staged) stages.add(field(job.body, 'uses').slice(2));
	}
	return loaded
		.filter((entry) => !stages.has(entry.rel))
		.map((entry) =>
			lanes.has(entry.rel)
				? { rel: entry.rel, text: inlineLane(entry.rel, entry.text, textOf) }
				: { ...entry }
		);
}

/**
 * Returns the lane a stage file is inlined into, or the file itself when no
 * lane calls it as a stage: where an inlined view shows that file's job.
 * @param {Array<{rel: string, text: string}>} loaded Pipeline files as they are.
 * @param {string} rel Repository-relative path.
 * @returns {string}
 */
function laneOfFile(loaded, rel) {
	const textOf = (name) => loaded.find((entry) => entry.rel === name)?.text;
	for (const entry of loaded) {
		for (const job of jobsOfText(entry.text, entry.rel)) {
			if (field(job.body, 'uses') === `./${rel}` && isStageCaller(job, textOf)) return entry.rel;
		}
	}
	return rel;
}

// ======================================
// ======================================
// ======= 6/ Load A Pipeline ===========
// ======================================
// ======================================

/**
 * Reads ci.yml and every workflow it calls from one checkout, depth first, in
 * call order, refusing a missing or empty file.
 * @param {string} root Absolute path of the checkout.
 * @returns {Array<{rel: string, text: string}>}
 */
function loadCheckout(root) {
	const readWorkflow = (rel, caller) => {
		const abs = path.join(root, rel);
		if (!fs.existsSync(abs)) fail(`${rel} (called from ${caller}) does not exist`);
		const text = fs.readFileSync(abs, 'utf8');
		if (text.trim() === '') fail(`${rel} (called from ${caller}) is empty`);
		if (!/^jobs:\s*$/m.test(text)) fail(`${rel} has no top-level jobs: block`);
		return text;
	};
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
	return loaded;
}

/**
 * Binds the pipeline lookups to a list of workflow files, read once, on the
 * first lookup.
 * @param {() => Array<{rel: string, text: string}>} read Returns the files in call order.
 * @returns {object} The lookups.
 */
function view(read) {
	let cache = null;
	const load = () => {
		if (!cache) cache = read();
		return cache;
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

	const resolve = (id) =>
		resolveJob(
			id,
			load()
				.flatMap((entry) => jobs(entry.rel))
				.filter((candidate) => candidate.id === id),
			jobs
		);

	/**
	 * Locates the unique job `id` across the pipeline (the stage job when a
	 * stage caller shares its id).
	 * @param {string} id Job id.
	 * @returns {{id: string, file: string, line: number, body: string}}
	 */
	const locate = (id) => resolve(id).stage;

	/**
	 * Locates the unique job `id` that calls a reusable workflow: a lane in
	 * ci.yml, or a stage caller in a lane.
	 * @param {string} id Job id.
	 * @returns {{id: string, file: string, line: number, body: string}}
	 */
	const locateCaller = (id) => {
		const { caller } = resolve(id);
		if (!caller) fail(`job '${id}' calls no reusable workflow`);
		return caller;
	};

	/**
	 * Returns the body of the unique job `id` that calls a reusable workflow.
	 * @param {string} id Job id.
	 * @returns {string}
	 */
	const caller = (id) => locateCaller(id).body;

	/**
	 * Returns a pipeline file followed by every file it calls, depth first.
	 * @param {string} rel Repository-relative path of a pipeline file.
	 * @returns {string[]}
	 */
	const laneFiles = (rel) => {
		file(rel);
		const found = [];
		const visit = (current) => {
			if (found.includes(current)) return;
			found.push(current);
			for (const match of file(current).matchAll(LOCAL_CALL)) visit(match[1]);
		};
		visit(rel);
		return found;
	};

	/**
	 * Returns the jobs that run steps in a lane and its stage files, in call order.
	 * @param {string} rel Repository-relative path of a lane file.
	 * @returns {Array<{id: string, file: string, line: number, body: string}>}
	 */
	const laneJobs = (rel) =>
		laneFiles(rel)
			.flatMap((current) => jobs(current))
			.filter((candidate) => field(candidate.body, 'uses') === null);

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

	return {
		files,
		file,
		text,
		jobs,
		locate,
		job,
		locateCaller,
		caller,
		laneFiles,
		laneJobs,
		textWithout,
		findStep,
		calls
	};
}

/**
 * Binds the lookups to one checkout. The default view reads every lane
 * inlined, one workflow per lane, as the contract tests were written; real()
 * reads the files as they are, stage files included.
 * @param {string} root Absolute path of the checkout.
 * @returns {object} The inlined lookups, plus real().
 */
function open(root) {
	const actual = view(() => loadCheckout(root));
	const inlined = view(() => inlinePipeline(actual.files()));
	return { ...inlined, real: () => actual, laneOf: (rel) => laneOfFile(actual.files(), rel) };
}

module.exports = {
	ROOT,
	ENTRY_REL,
	open,
	view,
	inlineLane,
	inlinePipeline,
	laneOfFile,
	isStageCaller,
	callDeclarations,
	jobMapping,
	resolveJob,
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
