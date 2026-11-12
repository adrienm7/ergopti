// tools/audit/structure/apply-step.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Step Applier (Rule B, phase 2)
 * DESCRIPTION:
 * Applies one step of docs/design/structure-plan.md mechanically: `git mv`
 * of every file the step moves on the three drivers, _shared and the tests,
 * then the rewrite of every reference to those files (Lua require names,
 * AutoHotkey #Include lines, and repository paths in tools, workflows,
 * manifests and docs), then the re-relativisation of the relative #Include
 * lines inside the moved AutoHotkey files themselves.
 *
 * It recomputes the step from the Git index of the day rather than from the
 * appendix, because the trees keep changing while the plan waits: a file born
 * after the plan was written moves with its module all the same.
 *
 * SAFETY:
 * Without --apply it only prints what it would do. --apply additionally needs
 * ERGOPTI_STRUCTURE_PHASE=2 in the environment, the coordinator's go for
 * phase 2, and refuses when any file it would touch has unstaged or staged
 * changes, so it never mixes a move with somebody else's edit. It stages the
 * exact paths it touched and commits nothing: the gates of the step run first.
 *
 * USAGE:
 *   node tools/audit/structure/apply-step.cjs --list
 *   node tools/audit/structure/apply-step.cjs <module>            dry run
 *   ERGOPTI_STRUCTURE_PHASE=2 node tools/audit/structure/apply-step.cjs <module> --apply
 *   <module> is a step key such as infra/config (ids such as S01 also work,
 *   but they renumber when the trees change).
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const Plan = require('./plan.cjs');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const PREFIX = 'static/ergopti_plus/';

function git(...args) {
	return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}

/** Builds the new spelling of a path token in the form it was written. */
function newPathToken(row, movedRepo) {
	const r = row.resolution;
	const backslash = row.old.includes('\\') && !row.old.includes('/');
	let out;
	if (r.form === 'repo') out = r.newRepo;
	else if (r.form === 'tree') out = r.newRepo.slice(PREFIX.length);
	else if (r.form === 'shared') out = r.newRepo.slice(`${PREFIX}_shared/`.length);
	else if (r.form === 'root') {
		const tree = r.newRepo.slice(PREFIX.length).split('/')[0];
		out = r.lead + r.newRepo.slice(`${PREFIX}${tree}/`.length);
	} else {
		// File-relative: relative to where the referencing file will be.
		const from = path.posix.dirname(movedRepo.get(row.file) || row.file);
		let rel = path.posix.relative(from, r.newRepo);
		if (r.lead === '' && !rel.startsWith('.') && row.old.startsWith('./')) rel = `./${rel}`;
		out = r.lead + rel;
	}
	// A token spelled with a leading slash (DIR .. "/adapters/x.lua") keeps it.
	if (row.old.startsWith('/') && out !== '' && !out.startsWith('/')) out = `/${out}`;
	return backslash ? out.replace(/\//g, '\\') : out;
}

/** Re-relativises the relative #Include lines of an AHK file that moves. */
function rewriteOwnIncludes(text, oldRepo, newRepo, finalRepo) {
	return text.replace(
		/^(\s*#Include\s+(?:\*i\s+)?)(%A_LineFile%[\\/]\.\.[\\/])?([^\s;%<][^\s;]*)/gm,
		(all, head, lead, target) => {
			const sep = target.includes('\\') && !target.includes('/') ? '\\' : '/';
			const posix = target.replace(/\\/g, '/');
			const resolvedOld = path.posix.normalize(`${path.posix.dirname(oldRepo)}/${posix}`);
			if (!fs.existsSync(path.join(ROOT, resolvedOld))) return all; // A_ScriptDir-relative or a directory: untouched
			const finalTarget = finalRepo.get(resolvedOld) || resolvedOld;
			const rel = path.posix.relative(path.posix.dirname(newRepo), finalTarget);
			return head + (lead || '') + (sep === '\\' ? rel.replace(/\//g, '\\') : rel);
		}
	);
}

/**
 * The dry run of the whole sequence on today's index. A later step runs on
 * the tree its predecessors leave, so a per-step dry run on today's tree
 * would not be the run phase 2 makes; instead this proves, for the full map:
 * the rules are idempotent (a step recomputed after its predecessors moves
 * nothing twice), no step leaves two Lua roots answering one name, no
 * touched file has local changes, and every reference is either rewritten
 * mechanically or listed for review, with nothing refused.
 * @returns {number} The exit code: 0 when the sequence is clean.
 */
function checkAll(map, plan) {
	const problems = [];
	const targets = [...map.values()].filter(Boolean);
	const again = Plan.moveMap(targets).map;
	const twice = [...again].filter(([o, t]) => o !== t);
	if (twice.length > 0)
		problems.push(
			`${twice.length} path(s) the rules would move a second time, e.g. ${twice[0].join(' -> ')}`
		);
	const left = Plan.luaCollisions(targets);
	if (left.length > 0)
		problems.push(
			`${left.length} Lua module name(s) answered by two roots: ${left.map((c) => c.name).join(', ')}`
		);
	const refs = Plan.attributeSteps(plan, Plan.references(map));
	const byStep = new Map(plan.map((s) => [s.id, []]));
	for (const r of refs) (byStep.get(r.step) || byStep.set(r.step, []).get(r.step)).push(r);
	const touched = new Set();
	for (const s of plan)
		for (const [o, t] of s.moves) touched.add(PREFIX + o).add(PREFIX + (t || o));
	for (const r of refs) touched.add(r.file);
	const dirty = git('status', '--porcelain', '-z')
		.split('\0')
		.filter(Boolean)
		.map((l) => l.slice(3));
	const dirtyTouched = dirty.filter((f) => touched.has(f));
	if (dirtyTouched.length > 0)
		problems.push(
			`${dirtyTouched.length} touched file(s) have local changes: ${dirtyTouched.slice(0, 5).join(', ')}`
		);
	console.log('step\tfeature\tmoves\trenames\trewrites\treview\trefused');
	for (const s of plan) {
		const own = byStep.get(s.id) || [];
		const renames = s.moves.filter(
			([o, t]) => t && path.posix.basename(o) !== path.posix.basename(t)
		).length;
		const review = own.filter((r) => Plan.REVIEWED_KINDS.has(r.kind)).length;
		const refused = own.filter((r) => Plan.REFUSED_KINDS.has(r.kind));
		console.log(
			`${s.id}\t${s.key}\t${s.moves.length}\t${renames}\t${own.length}\t${review}\t${refused.length}`
		);
		for (const r of refused.slice(0, 20))
			problems.push(`${s.id} ${s.key}: ${r.kind} ${r.file}: ${r.old} ${r.new}`);
		if (refused.length > 20)
			problems.push(`${s.id} ${s.key}: ${refused.length - 20} more refusal(s)`);
	}
	const orphan = byStep.get('unknown') || [];
	for (const r of orphan.filter((x) => Plan.REFUSED_KINDS.has(x.kind)).slice(0, 20))
		problems.push(`no step: ${r.kind} ${r.file}: ${r.old}`);
	if (problems.length > 0) {
		console.error(`\n[REFUSED] ${problems.length} problem(s):\n  - ${problems.join('\n  - ')}`);
		return 1;
	}
	console.log(
		`\n[OK] ${plan.length} steps, ${refs.length} references: the sequence runs without design work.`
	);
	return 0;
}

function main() {
	const args = process.argv.slice(2);
	const { map } = Plan.moveMap();
	const plan = Plan.steps(map);
	if (args.includes('--list') || args.length === 0) {
		for (const s of plan) console.log(`${s.id}\t${s.key}\t${s.moves.length} move(s)`);
		return;
	}
	if (args.includes('--check-all')) {
		process.exit(checkAll(map, plan));
	}
	const wanted = args.find((a) => !a.startsWith('--'));
	const step = plan.find((s) => s.key === wanted || s.id === wanted);
	if (!step) throw new Error(`no step named ${wanted}; run --list`);
	const apply = args.includes('--apply');
	if (apply && process.env.ERGOPTI_STRUCTURE_PHASE !== '2')
		throw new Error(
			"refusing --apply: phase 2 of the structure plan needs ERGOPTI_STRUCTURE_PHASE=2 (the coordinator's go)"
		);

	const movedRepo = new Map(
		step.moves.filter(([, t]) => t).map(([o, t]) => [PREFIX + o, PREFIX + t])
	);
	const retiredRepo = step.moves.filter(([, t]) => !t).map(([o]) => PREFIX + o);
	// Only this step's moves are applied; the references to them are rewritten.
	const stepMap = new Map(
		[...map].map(([o, t]) => [o, step.moves.some(([so]) => so === o) ? t : o])
	);
	const refs = Plan.references(stepMap);
	const edits = new Map();
	for (const row of refs) {
		if (!edits.has(row.file)) edits.set(row.file, []);
		edits.get(row.file).push(row);
	}

	const touched = new Set([
		...movedRepo.keys(),
		...movedRepo.values(),
		...retiredRepo,
		...edits.keys()
	]);
	const dirty = git(
		'status',
		'--porcelain',
		'-z',
		'--',
		...[...touched].filter((f) => fs.existsSync(path.join(ROOT, f)))
	)
		.split('\0')
		.filter(Boolean);
	console.log(
		`${step.id} ${step.key}: ${movedRepo.size} move(s), ${retiredRepo.length} retirement(s), ` +
			`${refs.length} reference(s) in ${edits.size} file(s)`
	);
	if (dirty.length > 0)
		console.log(
			`  ${dirty.length} touched path(s) have local changes:\n    ${dirty.join('\n    ')}`
		);
	const after = [...stepMap.values()].filter(Boolean);
	const before = new Set(Plan.luaCollisions([...map.keys()], false).map((c) => c.file));
	const created = Plan.luaCollisions(after).filter(
		(c) =>
			!before.has(c.file) &&
			(movedRepo.has(PREFIX + c.file) ||
				[...movedRepo.values()].some(
					(t) => Plan.luaModuleName(t.slice(PREFIX.length), true) === c.name
				))
	);
	for (const c of created)
		console.log(
			`  collision: ${c.name} would be answered by ${c.file} and by _shared/lua — retire or rename the shim in this step`
		);
	if (!apply) {
		for (const [o, t] of movedRepo) console.log(`  git mv ${o} ${t}`);
		for (const r of retiredRepo)
			console.log(`  git rm ${r}  (absence declared in _shared/core/features.json)`);
		for (const [file, rows] of edits) {
			for (const row of rows) {
				const next =
					row.kind === 'lua-module'
						? row.new
						: row.new === '(retired)'
							? '(retired)'
							: newPathToken(row, movedRepo);
				console.log(`  ${file}: ${row.old} -> ${next}`);
			}
		}
		console.log('dry run: nothing changed. Add --apply with ERGOPTI_STRUCTURE_PHASE=2 to apply.');
		return;
	}
	if (dirty.length > 0)
		throw new Error('refusing --apply: commit or set aside the local changes above first');
	if (created.length > 0)
		throw new Error('refusing --apply: resolve the Lua module collisions above first');

	// References first, in the files' current locations; then the moves.
	for (const [file, rows] of edits) {
		rows.sort((a, b) => b.old.length - a.old.length);
		const abs = path.join(ROOT, file);
		let text = fs.readFileSync(abs, 'utf8');
		for (const row of rows) {
			if (row.new === '(retired)') {
				console.log(`  review by hand: ${file} names retired ${row.old}`);
				continue;
			}
			if (Plan.REFUSED_KINDS.has(row.kind))
				throw new Error(`refused reference ${row.file}: ${row.old}`);
			// A sentence naming a folder that scatters stays as written; the
			// review list of the step names it.
			if (row.new === Plan.SPLIT) continue;
			const esc = row.old.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
			if (row.kind === 'lua-rewrite') {
				if (!text.includes(row.old))
					throw new Error(`${file}: the listed runtime edit no longer matches`);
				text = text.split(row.old).join(row.new);
				continue;
			}
			if (row.kind === 'lua-module' || row.kind === 'lua-prefix') {
				text = text.replace(new RegExp(`(["'])${esc}\\1`, 'g'), `$1${row.new}$1`);
			} else {
				// Whole tokens only: tests/unit/modules/llm must not rewrite
				// inside tests/unit/modules/llm_extra or a longer path.
				const bounded = new RegExp(
					`(?<![A-Za-z0-9_.\\-/\\\\])${esc}(?![A-Za-z0-9_\\-]|\\.[A-Za-z0-9])`,
					'g'
				);
				text = text.replace(bounded, newPathToken(row, movedRepo));
			}
		}
		fs.writeFileSync(abs, text, 'utf8');
	}
	const finalRepo = new Map(
		[...map].filter(([, t]) => t).map(([o, t]) => [PREFIX + o, PREFIX + (stepMap.get(o) || o)])
	);
	for (const [oldRepo, newRepo] of movedRepo) {
		if (oldRepo.endsWith('.ahk')) {
			const abs = path.join(ROOT, oldRepo);
			const text = fs.readFileSync(abs, 'utf8');
			const next = rewriteOwnIncludes(text, oldRepo, newRepo, finalRepo);
			if (next !== text) fs.writeFileSync(abs, next, 'utf8');
		}
		fs.mkdirSync(path.dirname(path.join(ROOT, newRepo)), { recursive: true });
		git('mv', '--', oldRepo, newRepo);
	}
	for (const r of retiredRepo) git('rm', '-q', '--', r);
	git('add', '--', ...[...edits.keys(), ...movedRepo.values()]);
	console.log(
		'applied and staged; run the step gates of docs/design/structure-plan.md before committing.'
	);
}

if (require.main === module) main();

module.exports = { newPathToken, rewriteOwnIncludes };
