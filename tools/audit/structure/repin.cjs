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
 *     [--derived-before <values>] [--requalify-out <records>]
 *   node tools/audit/structure/repin.cjs --derive-out <values>
 *   Compares the working tree with <rev> (HEAD by default), rewrites the pins
 *   and prints one line per re-pinned file. <file> is the JSON list of
 *   [old, new] moves apply-step --moves-out= wrote; --check rewrites nothing
 *   and fails when a pin is stale. --derive-out records the derived pins of the
 *   tree before a step; --derived-before hands them to the re-pin after it.
 *   --requalify-out appends the requalified pins (edits.cjs REQUALIFIED_PINS)
 *   to a JSON list the runner writes into the step's commit body.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const Plan = require('./plan.cjs');
const Edits = require('./edits.cjs');

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
	for (const e of entries) {
		const at = (f) => path.join(root, moves.get(f) || f);
		if (!fs.existsSync(at(e.file)) || !fs.existsSync(at(e.source)))
			throw new Error(`repin: derived pin ${e.file} names a missing file`);
		const holder = fs.readFileSync(at(e.file), 'utf8');
		const value = e.derive(fs.readFileSync(at(e.source), 'utf8'), holder, lib);
		if (!value) throw new Error(`repin: ${e.file} cannot be derived from ${e.source}`);
		if (pinned && !holder.includes(value))
			throw new Error(`repin: the derivation of ${e.file} no longer reproduces its pin`);
		values[e.file] = value;
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
	requalifications = []
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
		for (const [old, now] of pairs) {
			if (now === null) continue;
			const abs = path.join(root, now);
			if (!fs.existsSync(abs)) continue;
			const from = before.get(old);
			const cached = contents.get(now);
			const to = sha256(
				typeof cached === 'string' ? Buffer.from(cached, 'utf8') : fs.readFileSync(abs)
			);
			if (from === to) continue;
			if (next.has(from) && next.get(from) !== to) ambiguous.add(from);
			else {
				next.set(from, to);
				origin.set(from, [old, now]);
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
				const to = next.get(h);
				if (!to) return h;
				pins.push([h, to]);
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
	const edits = repin({ base, write: !check, moves, derivedBefore, requalifications });
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
