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

function main() {
	const args = process.argv.slice(2);
	const { map } = Plan.moveMap();
	const plan = Plan.steps(map);
	if (args.includes('--list') || args.length === 0) {
		for (const s of plan) console.log(`${s.id}\t${s.key}\t${s.moves.length} move(s)`);
		return;
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
	const before = new Set(Plan.luaCollisions([...map.keys()]).map((c) => c.file));
	const created = Plan.luaCollisions(after).filter(
		(c) =>
			!before.has(c.file) &&
			(movedRepo.has(PREFIX + c.file) ||
				[...movedRepo.values()].some((t) => Plan.luaModuleName(t.slice(PREFIX.length)) === c.name))
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
		const abs = path.join(ROOT, file);
		let text = fs.readFileSync(abs, 'utf8');
		for (const row of rows) {
			if (row.new === '(retired)') {
				console.log(`  review by hand: ${file} names retired ${row.old}`);
				continue;
			}
			if (row.kind === 'lua-module') {
				const esc = row.old.replace(/\./g, '\\.');
				text = text.replace(new RegExp(`(["'])${esc}\\1`, 'g'), `$1${row.new}$1`);
			} else {
				text = text.split(row.old).join(newPathToken(row, movedRepo));
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
