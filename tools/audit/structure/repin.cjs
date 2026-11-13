// tools/audit/structure/repin.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Content Pin Follow-Up
 * DESCRIPTION:
 * Many files pin the SHA-256 of another file: review receipts of behavior
 * owners, the source of a generated table, vendor digests, the Windows cohort
 * input manifests and the receipts that pin those. A structure step rewrites
 * the paths and module names inside hundreds of files, so every pin of one of
 * them goes stale in the same commit. This follow-up replaces each pinned
 * value that equals the pre-step hash of a file the step changed with that
 * file's post-step hash, and repeats until nothing changes: a re-pinned file
 * is itself changed, and its own pins follow.
 *
 * FEATURES & RATIONALE:
 * 1. Exact, not listed: a 64-hex value is a pin of a file when it equals that
 *    file's hash before the step. No registry of pin sites can fall behind.
 * 2. Refusal on ambiguity: two files with the same bytes before the step and
 *    different bytes after it make a pin of that hash undecidable; the step
 *    stops instead of guessing.
 * 3. History stays: files no structure step rewrites (docs/audits, the plan's
 *    own records, vendored code) keep the hashes they recorded.
 * 4. Derived pins: a hash of a value built from a file (a producer with one
 *    region restored) is listed in edits.cjs DERIVED_PINS with its derivation,
 *    which must reproduce the pin from the pre-step bytes before it re-pins.
 * 5. Requalified receipts: the Windows cohort frames and their pins, designed
 *    to be immutable, are re-pinned only as an explicit requalification that
 *    names each old→new pin and the file it follows; a derived pin there is
 *    refused.
 *
 * USAGE:
 *   node tools/audit/structure/repin.cjs [--base <rev>] [--moves <file>] [--check]
 *     [--derived-before <values>] [--requalify-out <records>] [--history <values>]
 *   node tools/audit/structure/repin.cjs --derive-out <values>
 *   Compares the working tree with <rev> (HEAD by default), rewrites the pins
 *   and prints one line per re-pinned file. <file> is the JSON list of
 *   [old, new] moves apply-step --moves-out= wrote; --check rewrites nothing
 *   and fails when a pin is stale. --derive-out records the derived pins of the
 *   tree before a step; --derived-before hands them to the re-pin after it.
 *   --requalify-out appends the requalified pins (edits.cjs REQUALIFIED_PINS)
 *   to a JSON list the runner writes into the step's commit body. --history
 *   keeps the values written per file across the runner's rounds, so a pin
 *   re-pinned to a value its file later outgrows follows it again.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const Plan = require('./plan.cjs');
const Edits = require('./edits.cjs');

// The plan's committed move map: old path, new path and step, by line.
const MOVE_MAP = 'docs/design/structure-plan/move-map.tsv';

const ROOT = path.resolve(__dirname, '..', '..', '..');
const PIN = /\b[0-9a-f]{64}\b/g;
const MAX_ROUNDS = 10;

function sha256(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}

function git(root, args, input) {
	return execFileSync('git', args, {
		cwd: root,
		input,
		maxBuffer: 1024 * 1024 * 1024
	});
}

/**
 * The files the working tree changed against `base`, as [old, new] pairs. A
 * moved file is paired with its new path from the step's own list of moves,
 * never from Git's similarity guess; a deleted one has no new side.
 * @param {Map<string, string>} moves Old repository path to new.
 */
function changedPairs(root, base, moves = new Map()) {
	const out = git(root, ['diff', '--no-renames', '--name-status', '-z', base]).toString('utf8');
	const fields = out.split('\0').filter((f) => f !== '');
	const pairs = [];
	for (let i = 0; i + 1 < fields.length; i += 2) {
		const [status, file] = [fields[i], fields[i + 1]];
		if (status === 'M' || status === 'T') pairs.push([file, file]);
		else if (status === 'D') pairs.push([file, moves.get(file) || null]);
	}
	return pairs;
}

/** The hash of each `base:path`, read in one git cat-file batch. */
function baseHashes(root, base, paths) {
	if (paths.length === 0) return new Map();
	const out = git(
		root,
		['cat-file', '--batch'],
		paths.map((p) => `${base}:${p}`).join('\n') + '\n'
	);
	const hashes = new Map();
	let at = 0;
	for (const p of paths) {
		const header = out.toString('utf8', at, out.indexOf(0x0a, at));
		at += Buffer.byteLength(header) + 1;
		const size = Number(header.split(' ')[2]);
		if (!Number.isSafeInteger(size)) throw new Error(`repin: ${base}:${p} cannot be read`);
		hashes.set(p, sha256(out.subarray(at, at + size)));
		at += size + 1;
	}
	return hashes;
}

/**
 * The value of every derived pin (edits.cjs DERIVED_PINS) in the tree at
 * `root` as it stands, computed with that tree's own tools: the pre-step
 * value before the step, the post-step one after it. Before the step each
 * value must be the pin its holder holds.
 * @param {{root?: string, moves?: Map<string, string>, entries?: Array, pinned?: boolean}} [options]
 * @returns {Object<string, string>} Each holder, by its pre-step path, to its value.
 */
function deriveAll({
	root = ROOT,
	moves = new Map(),
	entries = Edits.DERIVED_PINS,
	pinned = false
} = {}) {
	const lib = (rel) => require(path.join(root, rel));
	const values = {};
	const at = (f) => path.join(root, moves.get(f) || f);
	// An entry names its files as the tree had them before the migration; an
	// earlier step may have moved them already. The plan moves each file once,
	// so the file is at its first place or at the last one the committed move
	// map gives (the plan run on a stepped tree no longer knows the first).
	let finals = null;
	const located = (f) => {
		if (fs.existsSync(at(f))) return f;
		if (!finals)
			finals = new Map(
				fs
					.readFileSync(path.join(root, MOVE_MAP), 'utf8')
					.split('\n')
					.slice(1)
					.filter(Boolean)
					.map((line) => line.split('\t'))
			);
		const moved = finals.get(f);
		if (moved && fs.existsSync(at(moved))) return moved;
		throw new Error(`repin: derived pin names a missing file ${f}`);
	};
	for (const e of entries) {
		const file = located(e.file);
		const source = located(e.source);
		const holder = fs.readFileSync(at(file), 'utf8');
		const value = e.derive(fs.readFileSync(at(source), 'utf8'), holder, lib, at(source));
		if (!value) throw new Error(`repin: ${file} cannot be derived from ${source}`);
		if (pinned && !holder.includes(value))
			throw new Error(`repin: the derivation of ${file} no longer reproduces its pin`);
		// Keyed by the holder's place before the step, as the re-pin reads it.
		values[file] = value;
	}
	return values;
}

/** Tracked and new text files a structure step may rewrite. */
function candidateFiles(root) {
	return git(root, ['ls-files', '-co', '--exclude-standard', '-z'])
		.toString('utf8')
		.split('\0')
		.filter((f) => f !== '' && !Plan.neverRewritten(f));
}

/**
 * Re-pins every stale hash of the working tree against `base`.
 * @param {{root?: string, base?: string, write?: boolean, moves?: Map<string, string>}} [options]
 * @returns {Array<{file: string, pins: Array<[string, string]>}>} The edits.
 */
function repin({
	root = ROOT,
	base = 'HEAD',
	write = true,
	moves = new Map(),
	derived = Edits.DERIVED_PINS,
	derivedBefore = null,
	requalify = Edits.REQUALIFIED_PINS,
	requalifications = [],
	history = {}
} = {}) {
	const edits = new Map();
	const contents = new Map();
	const read = (f) => {
		if (!contents.has(f)) {
			const abs = path.join(root, f);
			const bytes = fs.existsSync(abs) && fs.lstatSync(abs).isFile() ? fs.readFileSync(abs) : null;
			contents.set(
				f,
				bytes && !bytes.subarray(0, 8192).includes(0) ? bytes.toString('utf8') : null
			);
		}
		return contents.get(f);
	};
	const files = candidateFiles(root);
	const requalified = new Set(requalify.map((e) => e.file));
	requalifications.length = 0;
	// A derived pin moves from its pre-step value, recorded by the runner
	// before the step, to the value the step's tree derives now.
	const derivedAfter = derivedBefore ? deriveAll({ root, moves, entries: derived }) : {};
	for (let round = 0; round < MAX_ROUNDS; round++) {
		const pairs = changedPairs(root, base, moves);
		const before = baseHashes(
			root,
			base,
			pairs.map(([o]) => o)
		);
		const next = new Map();
		const origin = new Map(); // pre-step hash -> [old path, new path]
		const ambiguous = new Set();
		// Files the step removed with no new place: a requalified pin of one
		// cannot be attributed to any file of the step.
		const gone = new Map();
		for (const [old, now] of pairs) {
			if (now === null || !fs.existsSync(path.join(root, now))) {
				gone.set(before.get(old), old);
				continue;
			}
			const abs = path.join(root, now);
			const from = before.get(old);
			const cached = contents.get(now);
			const to = sha256(
				typeof cached === 'string' ? Buffer.from(cached, 'utf8') : fs.readFileSync(abs)
			);
			if (from !== to) {
				if (next.has(from) && next.get(from) !== to) ambiguous.add(from);
				else {
					next.set(from, to);
					origin.set(from, [old, now]);
				}
			}
			// An earlier round of the same step re-pinned this file's pins to a
			// value it has since outgrown (a generator rewrote it): each value
			// recorded for it follows it too.
			for (const was of history[now] || [])
				if (was !== to && was !== from) {
					if (next.has(was) && next.get(was) !== to) ambiguous.add(was);
					else {
						next.set(was, to);
						origin.set(was, [old, now]);
					}
				}
		}
		let changed = false;
		for (const f of files) {
			const text = read(f);
			if (text === null || !PIN.test(text)) continue;
			PIN.lastIndex = 0;
			const pins = [];
			const updated = text.replace(PIN, (h) => {
				if (ambiguous.has(h))
					throw new Error(`repin: ${f} pins ${h}, shared by files the step made different`);
				if (requalified.has(f) && gone.has(h) && !next.has(h))
					throw new Error(
						`repin: ${f} pins ${h} of ${gone.get(h)}, which the step removed: no file accounts for it`
					);
				const to = next.get(h);
				if (!to) return h;
				pins.push([h, to]);
				const target = origin.get(h)[1];
				history[target] = [...new Set([...(history[target] || []), to])];
				if (requalified.has(f)) {
					const [oldPath, newPath] = origin.get(h);
					requalifications.push({ file: f, from: h, to, oldPath, newPath });
				}
				return to;
			});
			if (updated === text) continue;
			contents.set(f, updated);
			if (write) fs.writeFileSync(path.join(root, f), updated);
			const entry = edits.get(f) || { file: f, pins: [] };
			entry.pins.push(...pins);
			edits.set(f, entry);
			changed = true;
		}
		for (const [holder, to] of Object.entries(derivedAfter)) {
			const f = moves.get(holder) || holder;
			if (requalified.has(f)) throw new Error(`repin: ${f} is requalified, not re-derived`);
			const from = derivedBefore[holder];
			if (!from) throw new Error(`repin: no pre-step value of the derived pin ${holder}`);
			const text = read(f);
			if (from === to || text.includes(to)) continue;
			if (!text.includes(from)) throw new Error(`repin: ${f} lost its pin ${from}`);
			const updated = text.split(from).join(to);
			contents.set(f, updated);
			if (write) fs.writeFileSync(path.join(root, f), updated);
			const entry = edits.get(f) || { file: f, pins: [] };
			entry.pins.push([from, to]);
			edits.set(f, entry);
			changed = true;
		}
		if (!changed) return [...edits.values()];
		// Without writing, the next round would read the old bytes again.
		if (!write) return [...edits.values()];
	}
	throw new Error(`repin: the pins do not settle after ${MAX_ROUNDS} rounds`);
}

/**
 * The commit-body section that requalifies the immutable receipts a step
 * re-pinned (edits.cjs REQUALIFIED_PINS): one line per pin, old→new, with the
 * file whose move or rewrite justifies it.
 * @param {Array<{file: string, from: string, to: string, oldPath: string, newPath: string}>} records
 * @returns {string} The section, or '' when the step re-pinned none.
 */
function requalificationSection(records) {
	if (records.length === 0) return '';
	const lines = records.map(
		(r) =>
			`- ${r.file}: ${r.from} -> ${r.to} (${
				r.oldPath === r.newPath ? `${r.oldPath} rewritten in place` : `${r.oldPath} -> ${r.newPath}`
			})`
	);
	return (
		'Requalification of the immutable Windows cohort receipts (to confirm\n' +
		'on the real Windows PC):\n' +
		lines.join('\n')
	);
}

function main() {
	const args = process.argv.slice(2);
	const at = args.indexOf('--base');
	const base = at >= 0 ? args[at + 1] : 'HEAD';
	const check = args.includes('--check');
	const movesAt = args.indexOf('--moves');
	const moves = new Map(movesAt >= 0 ? JSON.parse(fs.readFileSync(args[movesAt + 1], 'utf8')) : []);
	const deriveOut = args.indexOf('--derive-out');
	if (deriveOut >= 0) {
		fs.writeFileSync(
			args[deriveOut + 1],
			JSON.stringify(deriveAll({ pinned: true }), null, 1) + '\n'
		);
		return;
	}
	const beforeAt = args.indexOf('--derived-before');
	const derivedBefore =
		beforeAt >= 0 ? JSON.parse(fs.readFileSync(args[beforeAt + 1], 'utf8')) : null;
	const requalifications = [];
	// The values each round of the runner wrote, per file, for the next round.
	const historyAt = args.indexOf('--history');
	const historyFile = historyAt >= 0 ? args[historyAt + 1] : null;
	const history =
		historyFile && fs.existsSync(historyFile)
			? JSON.parse(fs.readFileSync(historyFile, 'utf8'))
			: {};
	const edits = repin({ base, write: !check, moves, derivedBefore, requalifications, history });
	if (historyFile) fs.writeFileSync(historyFile, JSON.stringify(history, null, 1) + '\n');
	// Every round of the runner adds its requalified pins to the step's list.
	const outAt = args.indexOf('--requalify-out');
	if (outAt >= 0) {
		const out = args[outAt + 1];
		const earlier = fs.existsSync(out) ? JSON.parse(fs.readFileSync(out, 'utf8')) : [];
		fs.writeFileSync(out, JSON.stringify([...earlier, ...requalifications], null, 1) + '\n');
	}
	for (const e of edits) console.log(`${e.file}: ${e.pins.length} pin(s)`);
	console.log(`[repin] ${edits.length} file(s) ${check ? 'hold stale pins' : 're-pinned'}.`);
	if (check && edits.length > 0) process.exit(1);
}

if (require.main === module) main();

module.exports = { repin, changedPairs, deriveAll, requalificationSection };
