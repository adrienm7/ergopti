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
 *     [--moves-out=<file>]   also writes the step's [old, new] moves as JSON
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

// The kinds whose new token newPathToken spells from the referencing file's
// place; every other kind carries its new text in the row.
const SPELLED_KINDS = new Set(['path', 'dir', 'dir-successor', 'dir-split-prose', 'dir-split']);

/** Builds the new spelling of a path token in the form it was written. */
function newPathToken(row, movedRepo) {
	const r = row.resolution;
	// The separator the token was written with: "/", "\" (AHK, Windows) or
	// the doubled "\\" of a JavaScript string that spells a Windows path.
	const sep = row.old.includes('/')
		? '/'
		: row.old.includes('\\\\')
			? '\\\\'
			: row.old.includes('\\')
				? '\\'
				: '/';
	let out;
	if (r.form === 'repo') out = r.newRepo;
	else if (r.form === 'embedded') out = r.keep + r.newRepo.slice(PREFIX.length);
	else if (r.form === 'shared-alias') out = r.keep + r.newRepo.slice(`${PREFIX}_shared/`.length);
	else if (r.form === 'tree') out = r.newRepo.slice(PREFIX.length);
	else if (r.form === 'shared') out = r.newRepo.slice(`${PREFIX}_shared/`.length);
	else if (r.form === 'root') {
		// Relative to the root of the referencing file's tree, which may not be
		// the target's: driver_root .. "/../_shared/data/x" keeps its "../_shared".
		const refTree = row.file.slice(PREFIX.length).split('/')[0];
		out = r.lead + path.posix.relative(`${PREFIX}${refTree}`, r.newRepo);
		// A token that climbs out of the tree and back in keeps that climb:
		// driver_root() .. "/../_shared/modules/x" written in a _shared file still
		// starts from a driver root at run time.
		const segs = row.old
			.replace(/\\\\|\\/g, '/')
			.slice(r.lead.length)
			.replace(/^\//, '')
			.split('/');
		for (let i = segs.length - 1; i > 0; i--) {
			const head = segs.slice(0, i);
			if (!head.includes('..')) continue;
			const dir = path.posix.normalize(`${PREFIX}${refTree}/${head.join('/')}`);
			if (!r.newRepo.startsWith(`${dir}/`)) continue;
			out = `${r.lead}${head.join('/')}/${path.posix.relative(dir, r.newRepo)}`;
			break;
		}
	} else {
		// File-relative: relative to where the referencing file will be.
		const from = path.posix.dirname(movedRepo.get(row.file) || row.file);
		let rel = path.posix.relative(from, r.newRepo);
		if (r.lead === '' && !rel.startsWith('.') && row.old.startsWith('./')) rel = `./${rel}`;
		out = r.lead + rel;
	}
	// A token spelled with a leading separator (DIR .. "/adapters/x.lua",
	// _SharedDir . "\modules\x.json") keeps it.
	if (row.old.startsWith(sep) && out !== '' && !out.startsWith('/')) out = `/${out}`;
	return sep === '/' ? out : out.replace(/\//g, sep);
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
 * Rewrites one file's text for the references a step lists in it. Rows run
 * longest first, so a long path is rewritten before a token it contains; the
 * shared Lua root switch runs last, on what the path rewrites leave.
 * @param {string} text The file's text.
 * @param {object[]} rows The file's rows of Plan.references().
 * @param {Map<string, string>} movedRepo The step's moves, repository paths.
 * @param {string} file The file's repository path, for messages.
 * @returns {string} The rewritten text.
 */
function rewriteText(text, rows, movedRepo, file) {
	const original = text;
	rows.sort((a, b) => b.old.length - a.old.length);
	let rootSwitch = false;
	// Every replacement is final: a rewritten span becomes a placeholder until
	// the end, so a shorter row (the folder _shared/core) never rewrites inside
	// what a longer one wrote (…/_shared/core/network/data/x.json).
	const slots = [];
	const hold = (value) => {
		slots.push(value);
		return `\u0000${slots.length - 1}\u0000`;
	};
	const swap = (from, to) => {
		text = text.split(from).join(hold(to));
	};
	for (const row of rows) {
		// The root switch runs last, on what the path rewrites leave.
		if (row.kind === 'shared-root') {
			rootSwitch = true;
			continue;
		}
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
			swap(row.old, row.new);
			continue;
		}
		if (
			[
				'lua-tail',
				'lua-climb',
				'folder-edit',
				'lua-module-quoted',
				'shared-prefix',
				'source-check',
				'lua-concat'
			].includes(row.kind)
		) {
			swap(row.old, row.new);
			continue;
		}
		if (row.kind === 'lua-module-field') {
			text = text.replace(new RegExp(`${esc}(?!\\w)`, 'g'), () => hold(row.new));
			continue;
		}
		if (row.kind === 'lua-module-list') {
			swap(row.old, row.new);
			continue;
		}
		if (row.kind === 'lua-module-inline') {
			const inline = new RegExp(`(?<![\\w.%])${esc}(?!\\w|\\.[A-Za-z_])`, 'g');
			text = text.replace(Plan.LUA_SHORT_STRING, (lit) => lit.replace(inline, () => hold(row.new)));
			continue;
		}
		if (row.kind === 'path-regex') {
			text = text.replace(new RegExp(`(?<![\\w\\\\])${esc}(?![\\w])`, 'g'), () => hold(row.new));
			continue;
		}
		if (row.kind === 'join' || row.kind === 'join-successor') {
			swap(row.old, row.new);
			continue;
		}
		if (row.kind === 'lua-module-escaped') {
			text = text.replace(new RegExp(`(?<![\\w%.])${esc}(?![\\w])`, 'g'), () => hold(row.new));
		} else if (row.kind === 'lua-module' && (!row.old.includes('.') || row.resolution?.loadOnly)) {
			// A one-word name moves only where it is loaded (Plan.isModuleLoadSite).
			text = text.replace(new RegExp(`(["'])${esc}\\1`, 'g'), (whole, quote, offset, all) =>
				Plan.isModuleLoadSite(all, offset) ? `${quote}${hold(row.new)}${quote}` : whole
			);
		} else if (row.kind === 'lua-module' || row.kind === 'lua-prefix') {
			text = text.replace(
				new RegExp(`(["'])${esc}\\1`, 'g'),
				(whole, quote) => `${quote}${hold(row.new)}${quote}`
			);
		} else {
			// Whole tokens only: tests/unit/modules/llm must not rewrite
			// inside tests/unit/modules/llm_extra or a longer path.
			const bounded = new RegExp(
				`(?<![A-Za-z0-9_.\\-/\\\\])${esc}(?![A-Za-z0-9_\\-]|\\.[A-Za-z0-9])`,
				'g'
			);
			const next = newPathToken(row, movedRepo);
			text = text.replace(bounded, () => hold(next));
		}
	}
	text = text.replace(/\u0000(\d+)\u0000/g, (_, i) => slots[Number(i)]);
	if (rootSwitch) text = Plan.sharedRootRewrite(text);
	return text === original ? text : repairCoupled(original, text);
}

// x:sub(1, 12) == "_shared/lua/": a length written beside the literal it measures.
const SUB_PREFIX =
	/(:sub\(\s*1\s*,\s*|\bstring\.sub\(\s*[\w.]+\s*,\s*1\s*,\s*)(\d+)(\s*\)\s*[=~]=\s*)(["'])([^"'\n]*)\4/g;
// for _, dir in ipairs({ base, base .. "/a", base .. "/a/b" }) do … mkdir(dir
const MKDIR_LADDER =
	/(\bfor\s+_\s*,\s*(\w+)\s+in\s+ipairs\s*\(\s*\{)([^{}]*)(\}\s*\)\s*do\b[^\n]*\n?[^\n]*?mkdir\s*\(\s*)/g;

/**
 * Repairs what a rewrite of paths cannot keep consistent on its own:
 * - a `sub(1, N) == "literal"` check whose literal was rewritten keeps N equal
 *   to the literal's length, when it was equal before;
 * - a list of folders created one `mkdir` at a time (a fixture tree) keeps
 *   each folder once and gains the parents a deeper new path needs, in order.
 * @param {string} before The file's text before the step.
 * @param {string} after The rewritten text.
 * @returns {string}
 */
function repairCoupled(before, after) {
	const was = [...before.matchAll(SUB_PREFIX)].map((m) => Number(m[2]) === m[5].length);
	let index = 0;
	let out = after.replace(SUB_PREFIX, (whole, head, n, mid, q, lit) => {
		const coupled = was[index++];
		return coupled && Number(n) !== lit.length ? `${head}${lit.length}${mid}${q}${lit}${q}` : whole;
	});
	out = out.replace(MKDIR_LADDER, (whole, head, _v, body, tail) => {
		// Split at the top-level commas only: an entry may call a function.
		const entries = [];
		let depth = 0;
		let cur = '';
		for (const ch of body) {
			if (ch === '(') depth++;
			if (ch === ')') depth--;
			if (ch === ',' && depth === 0) {
				entries.push(cur.trim());
				cur = '';
			} else cur += ch;
		}
		entries.push(cur.trim());
		if (entries[entries.length - 1] === '') entries.pop();
		// base, base .. "/a/b", or a bare "a/b" a loop joins onto a base itself.
		const parsed = entries.map((e) => {
			const m = e.match(/^([A-Za-z_][\w.]*)(?:\s*\.\.\s*(["'])(\/[^"'\n]*)\2)?$/);
			if (m) return { base: m[1], rel: m[3] || '', q: m[2] || '"' };
			const lit = e.match(/^(["'])([^"'\n\/][^"'\n]*)\1$/);
			return lit ? { base: '', rel: `/${lit[2]}`, q: lit[1] } : { raw: e };
		});
		const render = (base, rel, q) =>
			base === '' ? `${q}${rel.slice(1)}${q}` : rel ? `${base} .. ${q}${rel}${q}` : base;
		const hasRoot = (base) => base === '' || parsed.some((p) => p.base === base && p.rel === '');
		const seen = new Set();
		const ordered = [];
		const emit = (base, rel, q) => {
			const key = `${base}|${rel}`;
			if (seen.has(key)) return;
			const parent = rel.slice(0, rel.lastIndexOf('/'));
			if (rel && parent && !seen.has(`${base}|${parent}`) && hasRoot(base)) emit(base, parent, q);
			seen.add(key);
			ordered.push(render(base, rel, q));
		};
		for (const p of parsed) {
			if (p.raw !== undefined) ordered.push(p.raw);
			else emit(p.base, p.rel, p.q);
		}
		if (ordered.join(', ') === entries.join(', ')) return whole;
		const lead = body.match(/^\s*/)[0];
		const trail = body.match(/\s*$/)[0];
		return `${head}${lead}${ordered.join(', ')}${trail}${tail}`;
	});
	return out;
}

/**
 * Removes the folders a step leaves empty. Git forgets them, but a checkout
 * that applied the step keeps them on disk, and a source scan that walks the
 * file system (a runner discovering suites, a gate counting folders) would
 * still see the old tree. A folder holding an ignored file is not empty and
 * stays.
 * @param {string[]} oldRepoPaths Repository paths of the files that left.
 */
function pruneEmptyFolders(oldRepoPaths) {
	const folders = new Set();
	for (const f of oldRepoPaths) {
		const parts = f.split('/');
		for (let i = parts.length - 1; i > PREFIX.split('/').length; i--)
			folders.add(parts.slice(0, i).join('/'));
	}
	// Deepest first, so a parent is seen after its emptied children.
	for (const dir of [...folders].sort((a, b) => b.split('/').length - a.split('/').length)) {
		const abs = path.join(ROOT, dir);
		if (fs.existsSync(abs) && fs.readdirSync(abs).length === 0) fs.rmdirSync(abs);
	}
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
	// Every rewrite must be computable: a token the applier cannot spell
	// would stop phase 2 in the middle of a step.
	const finalRepo = new Map(
		[...map].filter(([, t]) => t).map(([o, t]) => [PREFIX + o, PREFIX + t])
	);
	for (const r of refs) {
		if (
			!SPELLED_KINDS.has(r.kind) ||
			r.new === '(retired)' ||
			r.new === Plan.SPLIT ||
			Plan.REFUSED_KINDS.has(r.kind)
		)
			continue;
		try {
			newPathToken(r, finalRepo);
		} catch (error) {
			problems.push(
				`${r.step}: cannot spell the rewrite of ${r.old} in ${r.file}: ${error.message}`
			);
		}
	}
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
					!SPELLED_KINDS.has(row.kind) || row.new === '(retired)' || row.new === Plan.SPLIT
						? row.new
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

	// Every refusal is found before the first write, so a refused step leaves
	// the tree as it found it instead of half rewritten.
	const refusedRows = refs.filter((row) => Plan.REFUSED_KINDS.has(row.kind));
	if (refusedRows.length > 0)
		throw new Error(
			`refusing --apply: ${refusedRows.length} refused reference(s), nothing changed:\n  ` +
				refusedRows.map((row) => `${row.file}: ${row.old} ${row.new}`).join('\n  ')
		);

	// References first, in the files' current locations; then the moves.
	for (const [file, rows] of edits) {
		const abs = path.join(ROOT, file);
		const text = rewriteText(fs.readFileSync(abs, 'utf8'), rows, movedRepo, file);
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
	pruneEmptyFolders([...movedRepo.keys(), ...retiredRepo]);
	// The follow-ups (repin.cjs) pair each moved file with its new path from
	// this list rather than from Git's similarity guess.
	const movesOut = (args.find((a) => a.startsWith('--moves-out=')) || '').slice(
		'--moves-out='.length
	);
	if (movesOut) fs.writeFileSync(movesOut, `${JSON.stringify([...movedRepo], null, '\t')}\n`);
	// A rewritten file this step also moved is staged at its new path: the old
	// one no longer exists once the move ran.
	git(
		'add',
		'--',
		...new Set([...[...edits.keys()].map((f) => movedRepo.get(f) || f), ...movedRepo.values()])
	);
	console.log(
		'applied and staged; run the step gates of docs/design/structure-plan.md before committing.'
	);
}

if (require.main === module) main();

module.exports = {
	newPathToken,
	rewriteOwnIncludes,
	rewriteText,
	repairCoupled,
	pruneEmptyFolders
};
