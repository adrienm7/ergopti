// tools/audit/structure/plan.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Generator (Rule B)
 * DESCRIPTION:
 * Computes the move map of docs/design/structure-plan.md from the Git index
 * and the target rules (rules.cjs): the target path of every tracked file of
 * windows/, macos/, linux/ and _shared/, the singleton pass, the ordered
 * steps, and the references each step has to rewrite (Lua require names,
 * AutoHotkey #Include lines, and repository paths in tools, workflows,
 * manifests, tests and docs).
 *
 * It only reads. The appendices it writes are a dated snapshot: the trees keep
 * changing while the plan waits, so apply-step.cjs recomputes the same data
 * from the index of the day instead of trusting the appendix.
 *
 * USAGE:
 *   node tools/audit/structure/plan.cjs            print the summary
 *   node tools/audit/structure/plan.cjs --write    rewrite docs/design/structure-plan/
 *   node tools/audit/structure/plan.cjs --map-all  print the move map of every file
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const Census = require('./census.cjs');
const Rules = require('./rules.cjs');
const Edits = require('./edits.cjs');
const { stripComments } = require('../../lib/script-source.cjs');

// A feature's sub-folders: a one-file sub-folder folds into the feature and
// its file keeps its own name (clipboard/engine/x.lua → clipboard/x.lua).
const SUB_NAMES = new Set(Rules.SUBS);

const ROOT = path.resolve(__dirname, '..', '..', '..');
const OUT_DIR = 'docs/design/structure-plan';
const PREFIX = `${Census.BASE}/`;

// History is not rewritten: dated audit records name the paths of their day.
// The plan, its appendices, its own tools and tests describe today's tree on
// purpose (their tables and fixtures name old paths); rules.cjs is rewritten,
// since its runtime sites name files that move.
const NEVER_REWRITTEN = [
	/^docs\/audits\//,
	/^docs\/design\/structure-plan(\/|\.md$)/,
	/^CHANGELOG/,
	/^tools\/audit\/structure\/(?!rules\.cjs$)/,
	/^tools\/test\/test-structure-[\w-]+\.cjs$/,
	// Third-party code, pinned by its vendor digests; its paths are its own.
	/^static\/ergopti_plus\/_shared\/ui\/vendor\/[^/]+\.js$/,
	/^static\/ergopti_plus\/windows\/vendor\/(?:ComVar|Promise|UIA|WebView2)\.ahk$/,
	/^static\/ergopti_plus\/macos\/vendor\/hs_asm\//
];

/** True for a file no structure step rewrites. */
function neverRewritten(file) {
	return NEVER_REWRITTEN.some((re) => re.test(file));
}
const TEXT_LIMIT_BYTES = 2 * 1024 * 1024;
const BINARY =
	/\.(png|jpe?g|gif|ico|icns|webp|mp4|mov|woff2?|ttf|otf|zip|gz|xz|tar|dll|exe|dylib|so|a|o|bin|db|sqlite|pdf|keylayout\.bin)$/i;

// ──────────────────────────────────────────────────────────────────────────────
// Move map
// ──────────────────────────────────────────────────────────────────────────────

/** True for a folder that is architecture code (not tests, not exempt). */
function isCodeFolder(treeRelFolder) {
	const rel = treeRelFolder.split('/').slice(1).join('/');
	return (
		!/^tests(\/|$)/.test(rel) &&
		!/(^|\/)test(\/|$)/.test(rel) &&
		Census.exemptionOf(treeRelFolder) === null &&
		Census.exemptionOf(rel) === null
	);
}

/**
 * The singleton pass: a code folder left with one file becomes that file in
 * its parent, and a folder holding only a README is retired. A test folder
 * the plan would create with one file gives it to its parent unchanged, since
 * test file names already carry their subject.
 * @param {Map<string, string|null>} map Tree-relative old path to target.
 * @param {Map<string, number>} existing The folders of the index today and their entry counts.
 */
function foldSingletons(map, existing) {
	for (let pass = 0; pass < 8; pass++) {
		const targets = [...map.values()].filter(Boolean);
		const taken = new Set(targets);
		const table = Census.folderTable(targets);
		// Parity wins over the singleton rule: a folder that is real on a
		// counterpart driver stays a folder everywhere.
		const largest = new Map();
		for (const [folder, entries] of table) {
			const [tree, ...rest] = folder.split('/');
			const key = Census.counterpartKey(tree, rest.join('/'));
			if (key) largest.set(key, Math.max(largest.get(key) || 0, entries.size));
		}
		let changed = false;
		for (const [folder, entries] of table) {
			if (entries.size !== 1 || folder.split('/').length < 2) continue;
			// Only the driver trees and the _shared roots that mirror them fold:
			// _shared/modules and _shared/data paths are read by codegen.
			if (!/^(windows|macos|linux|_shared)\//.test(`${folder}/`)) continue;
			// Shared data keeps its folders: codegen and the drivers read them by
			// path, and some by directory (db/migrations/).
			if (/^_shared\/(.+\/)?data\//.test(`${folder}/`)) continue;
			if (Census.exemptionOf(folder) || Census.exemptionOf(folder.split('/').slice(1).join('/')))
				continue;
			// Test runners discover suites by folder (module groups, stubs,
			// startup smokes), so a test folder that is a singleton today is left
			// to its suite; one the plan creates or empties down to one file folds.
			if (
				!isCodeFolder(folder) &&
				existing.has(folder) &&
				existing.get(folder) < Census.MIN_ENTRIES
			)
				continue;
			const only = [...entries][0];
			// A Convention S marker is retired even where a counterpart is real:
			// the absence is declared in _shared/core/features.json instead.
			if (only === 'README.md' && isCodeFolder(folder)) {
				for (const [old, t] of map) if (t === `${folder}/${only}`) map.set(old, null);
				changed = true;
				continue;
			}
			const [tree, ...rest] = folder.split('/');
			const key = Census.counterpartKey(tree, rest.join('/'));
			if (isCodeFolder(folder) && key && largest.get(key) >= Census.MIN_ENTRIES) continue;
			const child = `${folder}/${only}`;
			if (table.has(child)) {
				// A folder holding one folder, such as core/events/ holding only
				// adapters/: the child's content moves up one level.
				const created = (f) => !existing.has(f) || existing.get(f) >= Census.MIN_ENTRIES;
				if (!(isCodeFolder(folder) && isCodeFolder(child)) && !(created(folder) && created(child)))
					continue;
				const prefix = `${child}/`;
				const hoisted = [...map].filter(([, t]) => t && t.startsWith(prefix));
				if (hoisted.some(([, t]) => taken.has(`${folder}/${t.slice(prefix.length)}`))) continue;
				for (const [old, t] of hoisted) map.set(old, `${folder}/${t.slice(prefix.length)}`);
				changed = true;
				continue;
			}
			// A test fold stops at the feature (or core/<domain>) it covers: a test
			// file never lands loose in tests/<kind>/ or tests/<kind>/core/.
			if (!isCodeFolder(folder)) {
				const p = folder.split('/');
				const depth = ['core', 'platform'].includes(p[3]) ? 5 : 4;
				if (p[0] !== '_shared' && p[1] === 'tests' && p.length - 1 < depth) continue;
			}
			const parent = folder.split('/').slice(0, -1).join('/');
			const dirName = folder.split('/').pop();
			const ext = path.extname(only);
			const stem = path.basename(only, ext);
			let target;
			if (isCodeFolder(folder) && ['init', 'bridge', dirName].includes(stem))
				target = `${parent}/${dirName}${ext}`;
			else if (isCodeFolder(folder) && !stem.startsWith(dirName))
				target = SUB_NAMES.has(dirName) ? `${parent}/${only}` : `${parent}/${dirName}_${only}`;
			else target = `${parent}/${only}`;
			if (target && (table.has(target) || taken.has(target))) continue; // the name is taken: leave it for review
			for (const [old, t] of map) {
				if (t === child) {
					map.set(old, target);
					changed = true;
				}
			}
		}
		if (!changed) return;
	}
}

/**
 * Strips the prefixes a file name repeats from its folder (rules.cjs,
 * strippedName). A rename that would meet another file's name in the same
 * folder, renamed or not, is dropped for every file involved.
 * @param {Map<string, string|null>} map Tree-relative old path to target.
 */
function renamePrefixes(map) {
	const proposals = new Map();
	const pinned = Rules.pinnedModules();
	for (const [old, target] of map) {
		if (!target) continue;
		// A module whose name a runtime site builds keeps its file name.
		const oldName = luaModuleName(old);
		const oldTree = old.split('/')[0];
		const stem = path.posix.basename(old).replace(/\.lua$/, '');
		if (oldName && (pinned.has(`${oldTree}|${oldName}`) || pinned.has(`${oldTree}|stem:${stem}`)))
			continue;
		const [tree, ...rest] = target.split('/');
		const [, ...oldRest] = old.split('/');
		const name = Rules.strippedName(oldRest.join('/'), rest.join('/'));
		proposals.set(old, `${path.posix.dirname(target)}/${name}`);
	}
	const count = new Map();
	for (const t of proposals.values()) count.set(t, (count.get(t) || 0) + 1);
	const original = new Set([...map.values()].filter(Boolean));
	for (const [old, t] of proposals) {
		if (t === map.get(old)) continue;
		if (count.get(t) > 1 || original.has(t)) continue; // ambiguous: keep the name
		map.set(old, t);
	}
}

/**
 * A driver module and a _shared module that would answer the same Lua name
 * (both roots are on package.path, the first wins silently): the shared one
 * takes the `_core` suffix, the convention phase_stats_core.lua already
 * follows, and the driver keeps its name; an init.lua becomes core.lua.
 * @param {Map<string, string|null>} map Tree-relative old path to target.
 */
function resolveLuaCollisions(map) {
	for (const c of luaCollisions([...map.values()].filter(Boolean))) {
		for (const [old, t] of map) {
			if (!t || !t.startsWith('_shared/') || luaModuleName(t, true) !== c.name) continue;
			const next = t.endsWith('/init.lua')
				? t.replace(/\/init\.lua$/, '/core.lua')
				: t.replace(/\.lua$/, '_core.lua');
			map.set(old, next);
		}
	}
	const left = luaCollisions([...map.values()].filter(Boolean));
	if (left.length > 0)
		throw new Error(`unresolved Lua module collisions: ${left.map((c) => c.name).join(', ')}`);
}

/**
 * The full move map of the index.
 * @returns {{files: string[], map: Map<string, string|null>}} Tree-relative paths.
 */
function moveMap(files = Census.trackedFiles(ROOT).map((f) => f.slice(PREFIX.length))) {
	const map = new Map(files.map((f) => [f, Rules.mapPath(f)]));
	foldSingletons(map, new Map([...Census.folderTable(files)].map(([k, v]) => [k, v.size])));
	renamePrefixes(map);
	resolveLuaCollisions(map);
	// The shared Lua root switches in one step (sharedRootRewrite): a file the
	// rules leave under _shared/lua/ would keep a second root alive.
	const leftInRoot = [...map.values()].filter((t) => t && t.startsWith(SHARED_LUA_ROOT));
	if (leftInRoot.length > 0)
		throw new Error(
			`${leftInRoot.length} file(s) stay under _shared/lua/, e.g. ${leftInRoot[0]}: give them a home in rules.cjs`
		);
	// Two files must never meet at one target.
	const seen = new Map();
	for (const [old, target] of map) {
		if (!target) continue;
		if (seen.has(target))
			throw new Error(`two files map to ${target}: ${seen.get(target)} and ${old}`);
		seen.set(target, old);
	}
	return { files, map };
}

// ──────────────────────────────────────────────────────────────────────────────
// Steps
// ──────────────────────────────────────────────────────────────────────────────

/**
 * The step a move belongs to: the target module, the same key on every tree,
 * so one step moves one module on the three drivers, its _shared mirror and
 * its tests together.
 */
function stepKeyOf(oldPath, target) {
	// All of _shared moves first, in one step that also switches the shared Lua
	// root from _shared/lua to _shared: no period with two roots.
	if (oldPath.startsWith('_shared/')) return '_shared';
	const pick = target || oldPath;
	const data = pick.match(/^[^/]+\/tests\/(fixtures|support|hardware)\//);
	if (data) return `tests/${data[1]}`;
	if (pick.startsWith('_shared/tests/lua/')) return 'tests/shared_lua';
	let rel = pick.split('/').slice(1);
	if (rel[0] === 'tests') rel = rel.slice(2);
	if (['core', 'platform'].includes(rel[0]) && rel.length > 2)
		return `${rel[0]}/${rel[1].replace(/\.[^.]+$/, '')}`;
	return (rel[0] || 'root').replace(/\.[^.]+$/, '');
}

// Leaves first, so each step's consumers still resolve the names it does not
// touch: the plumbing every module requires moves before the modules.
const LAYER_ORDER = ['_shared', 'core', 'platform', 'settings', 'menu', 'tray', '*', 'tests'];

function stepOrder(a, b) {
	const rank = (k) => {
		const i = LAYER_ORDER.indexOf(k.split('/')[0]);
		return i >= 0 ? i : LAYER_ORDER.indexOf('*');
	};
	return rank(a) - rank(b) || a.localeCompare(b);
}

/** Moves grouped by step, in order. */
function steps(map) {
	const groups = new Map();
	for (const [old, target] of map) {
		if (old === target) continue;
		const key = stepKeyOf(old, target);
		if (!groups.has(key)) groups.set(key, []);
		groups.get(key).push([old, target]);
	}
	return [...groups.keys()].sort(stepOrder).map((key, i) => ({
		id: `S${String(i + 1).padStart(2, '0')}`,
		key,
		moves: groups.get(key).sort((x, y) => x[0].localeCompare(y[0]))
	}));
}

// ──────────────────────────────────────────────────────────────────────────────
// References
// ──────────────────────────────────────────────────────────────────────────────

/** The Lua module name of a tree-relative Lua path, or null. */
function luaModuleName(treeRel, target = false) {
	if (!treeRel || !treeRel.endsWith('.lua')) return null;
	const [tree, ...rest] = treeRel.split('/');
	let rel = rest.join('/');
	if (tree === '_shared') {
		// Today the shared Lua root is _shared/lua; in the target it is _shared.
		// Both are on package.path while the migration runs, so a file still
		// under lua/ keeps its old name in either mode.
		// The shared test modules move to _shared/tests/lua/ and are named from
		// _shared like any shared module (test.assertions → tests.lua.assertions).
		if (rel.startsWith('lua/')) rel = rel.slice(4);
		else if (!target || (/^tests\//.test(rel) && !/^tests\/lua\//.test(rel))) return null;
	}
	return rel
		.replace(/\.lua$/, '')
		.replace(/\/init$/, '')
		.split('/')
		.join('.');
}

/** Every tracked text file of the repository, outside the never-rewritten set. */
function textFiles() {
	return Census.trackedFiles(ROOT).length
		? require('node:child_process')
				.execFileSync('git', ['ls-files', '-z'], {
					cwd: ROOT,
					encoding: 'utf8',
					maxBuffer: 64 * 1024 * 1024
				})
				.split('\0')
				.filter(Boolean)
				.filter((f) => !BINARY.test(f) && !neverRewritten(f))
		: [];
}

/** The category a referencing file falls in, which decides its gate. */
function categoryOf(file) {
	if (/^\.github\/workflows\//.test(file)) return 'ci-workflow';
	if (/^tools\/build\/.*manifest/i.test(file) || /manifest.*\.json$/i.test(file))
		return 'packaging-manifest';
	if (/^tools\/build\//.test(file)) return 'build';
	if (/^tools\/(test|lint)\//.test(file)) return 'repo-test';
	if (/^tools\//.test(file)) return 'tooling';
	if (/^docs\/|\.md$/.test(file)) return 'docs';
	if (/\/tests?\//.test(file)) return 'driver-test';
	if (/\.ahk$/.test(file)) return 'ahk-include';
	if (/\.lua$/.test(file)) return 'lua-require';
	return 'other';
}

/**
 * Resolves one path-shaped token of a file to a moved file, and records the
 * form it was written in so the rewrite can keep that form.
 * @returns {{form: string, lead: string, oldRepo: string, newRepo: string}|null}
 */
function resolvePathToken(raw, file, inTree, byRepoPath, sharedArgument = false, folders = null) {
	// //go:build or a // comment: a comment marker, never a path the plan
	// moves (file:///A.app/… is a path, after its empty authority).
	if (/^\/\/(?!\/)/.test(raw)) return null;
	// "\\\\modules\\\\x" in a JavaScript string spells the Windows path \\modules\\x.
	const token = raw.replace(/\\\\|\\/g, '/');
	const candidates = [];
	// Paths.shared("modules/hotstrings"): the argument is relative to _shared,
	// whatever the driver's own tree holds under the same name.
	// The root itself (SHARED .. "/lua") is the root switch's.
	if (sharedArgument && !token.startsWith(PREFIX) && token.replace(/^\//, '') !== 'lua')
		candidates.push({
			form: 'shared',
			lead: '',
			abs: path.posix.normalize(`${PREFIX}_shared/${token.replace(/^\//, '')}`)
		});
	if (token.startsWith(PREFIX)) candidates.push({ form: 'repo', lead: '', abs: token });
	// repository .. "/static/ergopti_plus/…": the leading slash joins the root.
	if (token.startsWith(`/${PREFIX}`))
		candidates.push({ form: 'repo', lead: '', abs: token.slice(1) });
	const tree = Census.TREES.find((t) => token.startsWith(`${t}/`));
	if (tree) candidates.push({ form: 'tree', lead: '', abs: PREFIX + token });
	// `${SP}/_shared/modules/x.json`: a tree path joined onto the drivers' root.
	const joinedTree = Census.TREES.find((t) => token.startsWith(`/${t}/`));
	if (joinedTree) candidates.push({ form: 'tree', lead: '', abs: PREFIX + token.slice(1) });
	if (inTree && !token.startsWith(PREFIX)) {
		const lead = (token.match(/^(%A_LineFile%\/\.\.\/|%A_ScriptDir%\/)/) || [''])[0];
		const rest = token.slice(lead.length);
		const dir = path.posix.dirname(file);
		if (lead !== '%A_ScriptDir%/')
			candidates.push({ form: 'file', lead, abs: path.posix.normalize(`${dir}/${rest}`) });
		// "./lua" and "../x" are relative to the file and nothing else.
		const fileRelative = /^\.\.?\//.test(rest);
		if (!fileRelative)
			candidates.push({
				form: 'root',
				lead,
				abs: path.posix.normalize(`${PREFIX}${inTree}/${rest}`)
			});
		// Paths.shared("modules/llm/x.json") and its peers resolve against _shared/.
		if (inTree !== '_shared' && !lead && !fileRelative)
			candidates.push({
				form: 'shared',
				lead,
				abs: path.posix.normalize(`${PREFIX}_shared/${rest}`)
			});
		// SHARED_LUA_DIR .. "/toml_codec/source_open.lua": relative to today's
		// shared Lua root, which S00 turns into _shared itself. Only a Lua file
		// is read that way: "<config>/hotstrings/x" in a redaction corpus is a
		// user path, not the shared hotstrings folder.
		if (!lead && !fileRelative && /\.lua$/.test(rest))
			candidates.push({
				form: 'shared',
				lead,
				abs: path.posix.normalize(`${PREFIX}_shared/lua/${rest}`)
			});
	}
	// require('../../static/ergopti_plus/_shared/x.json') from a tool.
	if (!inTree && /^\.\.?\//.test(token))
		candidates.push({
			form: 'file',
			lead: '',
			abs: path.posix.normalize(`${path.posix.dirname(file)}/${token}`)
		});
	// …/Contents/Resources/_shared/data/x, ergopti_plus/_shared/x: a bundle or
	// a partial repository path that embeds a tree keeps what precedes it.
	for (const t of Census.TREES) {
		const at = token.indexOf(`/${t}/`);
		if (at >= 0)
			candidates.push({
				form: 'embedded',
				lead: '',
				keep: token.slice(0, at + 1),
				abs: path.posix.normalize(PREFIX + token.slice(at + 1))
			});
	}
	// "/shared/modules/x.json" or "/owned-shared/…" in a test's fake file
	// system: a root named for _shared, whose rest is a _shared path.
	const alias = token.match(/^(.*\/)((?:[A-Za-z0-9]+[-_])*shared)\/(.+)$/);
	if (alias && !token.includes('/_shared/'))
		candidates.push({
			form: 'shared-alias',
			lead: '',
			keep: `${alias[1]}${alias[2]}/`,
			abs: path.posix.normalize(`${PREFIX}_shared/${alias[3]}`)
		});
	// The token names the first of its readings that exists today; only then
	// is it looked up. Otherwise SCRIPT_DIR .. "/modules/hotstrings" (the
	// driver's own folder) would read as _shared/modules/hotstrings whenever
	// only the shared one moves.
	const existing = candidates.find((c) => EXISTING.has(c.abs));
	if (!existing && folders && token.includes('/')) {
		// A file the index does not hold (generated, never committed) in a
		// folder that moves whole follows its folder. Explicit forms only: a
		// bare relative name may be anything.
		const c = candidates.find(
			(x) =>
				(['repo', 'tree', 'embedded'].includes(x.form) ||
					(sharedArgument && x.form === 'shared')) &&
				path.posix.dirname(x.abs) !== `${PREFIX}_shared/lua` &&
				EXISTING.has(path.posix.dirname(x.abs)) &&
				folders.has(path.posix.dirname(x.abs)) &&
				folders.get(path.posix.dirname(x.abs)) !== SPLIT
		);
		if (!c) return null;
		return {
			form: c.form,
			lead: c.lead,
			keep: c.keep,
			oldRepo: path.posix.dirname(c.abs),
			newRepo: `${folders.get(path.posix.dirname(c.abs))}/${path.posix.basename(c.abs)}`
		};
	}
	if (!existing || !byRepoPath.has(existing.abs)) return null;
	return {
		form: existing.form,
		lead: existing.lead,
		keep: existing.keep,
		oldRepo: existing.abs,
		newRepo: byRepoPath.get(existing.abs)
	};
}

// Every tracked file and folder of the repository, as the index has them.
const EXISTING = (() => {
	const out = new Set();
	for (const f of require('node:child_process')
		.execFileSync('git', ['ls-files', '-z'], {
			cwd: ROOT,
			encoding: 'utf8',
			maxBuffer: 64 * 1024 * 1024
		})
		.split('\0')
		.filter(Boolean)) {
		out.add(f);
		const parts = f.split('/');
		for (let i = 1; i < parts.length; i++) out.add(parts.slice(0, i).join('/'));
	}
	return out;
})();

const SPLIT = '(split)';

/**
 * Where each folder that the plan touches goes: one new folder when all its
 * files keep their place relative to it, SPLIT when they scatter (a folder
 * named by a directory reference cannot then be rewritten mechanically).
 * @param {Map<string, string|null>} map Tree-relative old path to target.
 * @returns {Map<string, string>} Repository folder to repository folder or SPLIT.
 */
function directoryMap(map) {
	const seen = new Map();
	for (const [old, target] of map) {
		const parts = old.split('/');
		for (let i = 2; i < parts.length; i++) {
			const dir = parts.slice(0, i).join('/');
			// Folders only: a file renamed in place does not scatter its folder.
			const relDir = parts.slice(i, -1).join('/');
			const tdir = target === null ? null : path.posix.dirname(target);
			let next;
			if (tdir === null) next = null;
			else if (relDir === '') next = tdir;
			else if (tdir.endsWith(`/${relDir}`)) next = tdir.slice(0, -relDir.length - 1);
			else next = SPLIT;
			if (!seen.has(dir)) seen.set(dir, new Set());
			seen.get(dir).add(next);
		}
	}
	const out = new Map();
	// The shared Lua root becomes _shared itself; both stay on package.path
	// until the last shared Lua file has left _shared/lua.
	seen.set('_shared/lua', new Set(['_shared']));
	for (const [dir, targets] of seen) {
		const live = [...targets].filter((t) => t !== null);
		if (live.length === 0) continue;
		const value = live.length === 1 && live[0] !== SPLIT ? live[0] : SPLIT;
		if (value !== dir) out.set(PREFIX + dir, value === SPLIT ? SPLIT : PREFIX + value);
	}
	return out;
}

/**
 * The nearest folder that holds every new place of a scattered folder's
 * files (windows/modules/llm → windows/ai), when it is deeper than the tree
 * root: what a sentence naming the old folder should name instead.
 */
function splitSuccessors(map, byRepoDir) {
	const out = new Map();
	const common = (a, b) => {
		const x = a.split('/');
		const y = b.split('/');
		let i = 0;
		while (i < x.length && i < y.length && x[i] === y[i]) i++;
		return x.slice(0, i).join('/');
	};
	const acc = new Map();
	for (const [old, target] of map) {
		if (!target) continue;
		const parts = old.split('/');
		for (let i = 2; i < parts.length; i++) {
			const dir = PREFIX + parts.slice(0, i).join('/');
			if (byRepoDir.get(dir) !== SPLIT) continue;
			const t = PREFIX + path.posix.dirname(target);
			acc.set(dir, acc.has(dir) ? common(acc.get(dir), t) : t);
		}
	}
	// The tree root itself is a valid successor for code (a list of layer roots
	// becomes the driver root); prose only takes a folder below it.
	for (const [dir, c] of acc) if (c.split('/').length >= 3) out.set(dir, c);
	return out;
}

/** True when the match at `index` is documentation or a comment, not code. */
function isProse(file, text, code, index) {
	if (/\.(md|txt)$/i.test(file)) return true;
	if (code !== null) return code[index] === ' ' && text[index] !== ' ';
	if (!/\.(c?js|mjs|py|sh|ya?ml|ps1|swift|go|c|h)$/.test(file)) return false;
	const lineStart = text.lastIndexOf('\n', index) + 1;
	const before = text.slice(lineStart, index);
	return /(\/\/|^\s*\*|^\s*\/\*|#)/.test(before);
}

/**
 * A path a moving file spells relative to itself ("../../vendor/x.lua") whose
 * target stays: it is re-relativised against the file's new place.
 * @returns {{form: string, lead: string, oldRepo: string, newRepo: string}|null}
 */
function resolveOwnRelative(token, file, selfTarget) {
	const abs = path.posix.normalize(`${path.posix.dirname(file)}/${token.replace(/\\/g, '/')}`);
	if (!EXISTING.has(abs) || !selfTarget) return null;
	return { form: 'file', lead: '', oldRepo: abs, newRepo: abs };
}

/** Escapes a path for a Lua pattern the way the sources write it. */
const luaPatternEscape = (p) => p.replace(/[.-]/g, (c) => `%${c}`);

/**
 * The tails of its own path a moving Lua file matches to find its root:
 * source:match("^(.*)/modules/llm/ollama_binary%.lua$") or "^(.*)/infra/[^/]+$".
 * The part before the tail (the driver root) stays, so the tail is respelled
 * from the file's new place.
 */
function ownTails(text, selfOld, selfTarget) {
	const out = [];
	const tree = selfOld.split('/')[0];
	for (const m of text.matchAll(
		/\/((?:[\w]+(?:%[.-][\w]+)*\/)*)([\w]+(?:%[.-][\w]+)*%\.lua|\[\^\/\]\+)\$/g
	)) {
		const dirs = m[1].replace(/%([.-])/g, '$1');
		const leaf = m[2] === '[^/]+' ? null : m[2].replace(/%([.-])/g, '$1');
		const ownRel = selfOld.slice(tree.length + 1);
		const tail = dirs + (leaf || path.posix.basename(selfOld));
		if (!`/${ownRel}`.endsWith(`/${tail}`)) continue;
		const anchor = ownRel.slice(0, ownRel.length - tail.length); // kept, with its trailing slash
		const newRel = selfTarget.slice(tree.length + 1);
		if (!newRel.startsWith(anchor)) continue;
		const newTail = newRel.slice(anchor.length);
		const spelled = leaf
			? luaPatternEscape(newTail)
			: `${luaPatternEscape(path.posix.dirname(newTail) === '.' ? '' : `${path.posix.dirname(newTail)}/`)}[^/]+`;
		const next = `/${spelled}$`.replace('//', '/');
		if (next !== m[0]) out.push({ old: m[0], new: next });
	}
	// The same tail spelled with a separator variable:
	// "^(.*)" .. sep .. "lua" .. sep .. "test" .. sep .. "x%.lua$".
	for (const m of text.matchAll(
		/(["'])\^\(\.\*\)\1((?:\s*\.\.\s*\w+\s*\.\.\s*(["'])[\w%.$-]+\3)+)/g
	)) {
		const sepVar = (m[2].match(/\.\.\s*(\w+)\s*\.\./) || [])[1];
		const parts = [...m[2].matchAll(/(["'])([\w%.$-]+)\1/g)].map((x) => x[2]);
		const lastRaw = parts[parts.length - 1];
		if (!sepVar || (!lastRaw.endsWith('%.lua$') && !lastRaw.endsWith('%.lua'))) continue;
		const dollar = lastRaw.endsWith('$');
		const tail = parts
			.map((p, i) => (i === parts.length - 1 && dollar ? p.slice(0, -1) : p))
			.map((p) => p.replace(/%([.-])/g, '$1'))
			.join('/');
		const ownRel = selfOld.slice(tree.length + 1);
		if (!`/${ownRel}`.endsWith(`/${tail}`)) continue;
		const anchor = ownRel.slice(0, ownRel.length - tail.length);
		const newRel = selfTarget.slice(tree.length + 1);
		if (!newRel.startsWith(anchor)) continue;
		const q = m[3];
		const spelled = newRel
			.slice(anchor.length)
			.split('/')
			.map(
				(p, i, all) =>
					` .. ${sepVar} .. ${q}${luaPatternEscape(p)}${i === all.length - 1 && dollar ? '$' : ''}${q}`
			)
			.join('');
		if (spelled !== m[2]) out.push({ old: m[0], new: `${m[1]}^(.*)${m[1]}${spelled}` });
	}
	return out;
}

/**
 * The dirname() climbs a moving Lua file makes from its own source path to
 * reach a folder that stays (_shared, the driver root):
 * NativePath.dirname(assert(NativePath.dirname(source))). The number of
 * climbs follows the file's new depth.
 */
function ownClimbs(text, selfOld, selfTarget) {
	const out = [];
	const vars = [
		...text.matchAll(/\blocal\s+(\w+)\s*=[^\n]*\bdebug\.getinfo\(\s*1\s*,\s*["']S["']\s*\)/g)
	].map((m) => m[1]);
	// The anchor a climb of k folders reaches from the file today, and the
	// number of climbs that reaches it from the new place (null: no stable anchor).
	const climbsFor = (k) => {
		const oldParts = selfOld.split('/');
		if (k >= oldParts.length) return null;
		const anchor = oldParts.slice(0, oldParts.length - k).join('/');
		if (!selfTarget.startsWith(`${anchor}/`)) return null;
		return selfTarget.split('/').length - anchor.split('/').length;
	};
	// One climb per line: local dir = NativePath.dirname(src) or src, then
	// dir = NativePath.dirname(dir) or dir / dir = dir and NativePath.dirname(dir).
	const lines = text.split('\n');
	for (let i = 0; i < lines.length; i++) {
		const head = lines[i].match(
			/^(\s*)local\s+(\w+)\s*=\s*NativePath\.dirname\((\w+)\)(?:\s+or\s+\3)?\s*(?:--.*)?$/
		);
		if (!head || !vars.includes(head[3])) continue;
		const x = head[2];
		const step = new RegExp(
			`^(\\s*)${x}\\s*=\\s*(?:${x}\\s+and\\s+NativePath\\.dirname\\(${x}\\)|NativePath\\.dirname\\(${x}\\)\\s+or\\s+${x})\\s*(?:--.*)?$`
		);
		let j = i + 1;
		while (j < lines.length && step.test(lines[j])) j++;
		const k = j - i;
		const k2 = climbsFor(k);
		if (k2 === null || k2 === k || k2 < 1) continue;
		const block = lines.slice(i, j);
		const template = (
			j - 1 > i ? lines[j - 1] : `${head[1]}${x} = ${x} and NativePath.dirname(${x})`
		).replace(/\s*--.*$/, '');
		const next = k2 > k ? [...block, ...Array(k2 - k).fill(template)] : block.slice(0, k2);
		out.push({ old: block.join('\n'), new: next.join('\n') });
	}
	for (const v of new Set(vars)) {
		const re = new RegExp(`((?:NativePath\\.dirname\\((?:assert\\()?)+)${v}\\b`, 'g');
		for (const m of text.matchAll(re)) {
			const k = (m[1].match(/NativePath\.dirname\(/g) || []).length;
			const asserts = (m[1].match(/assert\(/g) || []).length;
			const closers = k + asserts;
			const after = text.slice(m.index + m[0].length, m.index + m[0].length + closers);
			if (after !== ')'.repeat(closers)) continue;
			const oldParts = selfOld.split('/');
			if (k >= oldParts.length) continue;
			const anchor = oldParts.slice(0, oldParts.length - k).join('/');
			if (!selfTarget.startsWith(`${anchor}/`)) continue;
			const k2 = selfTarget.split('/').length - anchor.split('/').length;
			if (k2 === k) continue;
			const wrap = asserts > 0;
			let expr = `NativePath.dirname(${v})`;
			for (let i = 1; i < k2; i++)
				expr = `NativePath.dirname(${wrap ? 'assert(' : ''}${expr}${wrap ? ')' : ''})`;
			out.push({ old: m[0] + after, new: expr });
		}
	}
	return out;
}

let CONFIG_KEYS = null;
/**
 * The configuration keys, from the generated config_keys.lua wherever the plan
 * has put it: a key such as "llm.app_profile_overrides" can spell a module
 * name, and a stored setting must keep its key.
 * @returns {Set<string>}
 */
function configKeys() {
	if (CONFIG_KEYS) return CONFIG_KEYS;
	// The generator names its output (and the steps rewrite that name with the
	// move): the key list is found wherever the plan has put it, renamed or not.
	const generator = fs.readFileSync(
		path.join(ROOT, 'tools/codegen/codegen-config-keys.cjs'),
		'utf8'
	);
	const output = (generator.match(/\bLUA_OUTPUT\s*=\s*'([^']+)'/) || [])[1];
	if (!output || !fs.existsSync(path.join(ROOT, output)))
		throw new Error(
			`codegen-config-keys.cjs names no Lua output the index holds (${output}): the plan needs the key list`
		);
	CONFIG_KEYS = new Set();
	for (const m of fs.readFileSync(path.join(ROOT, output), 'utf8').matchAll(/=\s*"([^"]+)"/g))
		CONFIG_KEYS.add(m[1]);
	return CONFIG_KEYS;
}

let LOCALE_KEYS = null;
/** The keys of the English locale, wherever the plan has put it. */
function localeKeys() {
	if (LOCALE_KEYS) return LOCALE_KEYS;
	const source = [...EXISTING].find((f) =>
		new RegExp(`^${PREFIX}_shared/(.+/)?locales/en\\.json$`).test(f)
	);
	if (!source)
		throw new Error('locales/en.json not found under _shared: the plan needs the key list');
	LOCALE_KEYS = new Set(Object.keys(JSON.parse(fs.readFileSync(path.join(ROOT, source), 'utf8'))));
	return LOCALE_KEYS;
}

/** True when the token at `index` opens the argument of a Paths.shared call. */
function isSharedArgument(text, index) {
	// Paths.shared("x"), helpers.shared("x"), shared('x') and readShared(`x`)
	// in the tools; Paths.shared_llm_path("x") is relative to the AI data.
	const before = text.slice(Math.max(0, index - 40), index);
	// SHARED_DIR .. "/modules/x", SHARED / "modules/x", SHARED + '/x',
	// ${SRC_SHARED}/modules/x, _SharedDir . "\\modules\\x" (AHK): a path joined onto an
	// expression naming _shared.
	if (/\b\w*[sS][hH][aA][rR][eE][dD]\w*(?:\(\))?\s*(?:\.\.|\/|\+|\s\.)\s*["'`]$/.test(before))
		return true;
	if (/\$\{?\w*SHARED\w*\}?$/.test(before)) return true;
	// const MENU_SOURCE_REL = 'modules/menu/menu.toml' beside shared(): a path
	// relative to _shared kept in a constant.
	if (/\bconst\s+\w*_REL\s*=\s*["'`]$/.test(before) && /\bshared\(|SHARED/.test(text)) return true;
	// local ORDER_FILE = "data/locale_order.json" … read_shared(ORDER_FILE): a
	// constant the file hands to a shared reader.
	const named = before.match(/\b(?:local|const|let)\s+([A-Za-z_]\w*)\s*=\s*["'`]$/);
	if (named && new RegExp(`\\b\\w*[sS]hared\\w*\\(\\s*${named[1]}\\s*[,)]`).test(text)) return true;
	// const SOURCES = ['data/x.json', …] … SOURCES.map((s) => sharedRel(s)):
	// the elements of a list the file hands to a shared helper.
	if (sharedLists(text).some(([from, to]) => index > from && index < to)) return true;
	// paths.shared = function(path) if path == "modules/hotstrings" …: the
	// argument a stand-in of a shared resolver is compared with.
	if (
		sharedStandIns(text).some((sc) => index > sc.from && index < sc.to && sc.compare.test(before))
	)
		return true;
	// read('lua/test/format.lua', SHARED): the base comes after the path.
	if (/^[^"'`\n]*["'`]\s*,\s*\w*SHARED\w*\s*\)/.test(text.slice(index, index + 200))) return true;
	return (
		/\b\w*[sS]hared(?!_llm)\w*\(\s*["'`]$/.test(before) &&
		!/shared_llm_path\(\s*["'`]$/.test(before)
	);
}

let standInText = null;
let standIns = [];
/**
 * The stand-ins a test assigns to a shared resolver (paths.shared =
 * function(path) … end), each with the lines its parameter is compared in.
 * @returns {Array<{from: number, to: number, compare: RegExp}>}
 */
function sharedStandIns(text) {
	if (text === standInText) return standIns;
	standIns = [];
	for (const m of text.matchAll(
		/\b[\w.]*[sS]hared(?!_llm)\w*\s*=\s*function\s*\(\s*([A-Za-z_]\w*)/g
	))
		standIns.push({
			from: m.index,
			to: m.index + 1500,
			compare: new RegExp(`\\b${m[1]}\\s*[=~!]==?\\s*["'\`]$`)
		});
	standInText = text;
	return standIns;
}

/**
 * The tables a require stand-in answers from (function environment.require(name)
 * if modules[name] then return modules[name] end): their keys are module names.
 * @returns {string[]}
 */
function standInTables(text) {
	const tables = new Set();
	for (const m of text.matchAll(
		/(?:\bfunction\s+[\w.:]*\brequire\s*\(\s*([A-Za-z_]\w*)\s*\)|\brequire\s*=\s*function\s*\(\s*([A-Za-z_]\w*)\s*\))([^\n]*\n){0,6}/g
	)) {
		const param = m[1] || m[2];
		for (const t of m[0].matchAll(new RegExp(`\\b([A-Za-z_]\\w*)\\[\\s*${param}\\s*\\]`, 'g')))
			if (t[1] !== 'package') tables.add(t[1]);
	}
	return [...tables];
}

let tailIndex = null;
let tailIndexSize = -1;
/**
 * The repository files whose path ends with `/<tail>`.
 * @returns {string[]}
 */
function filesEndingWith(tail) {
	// Rebuilt when the index of existing paths changes (a test adds fakes).
	if (tailIndex === null || tailIndexSize !== EXISTING.size) {
		tailIndexSize = EXISTING.size;
		tailIndex = new Map();
		for (const p of EXISTING) {
			const base = p.slice(p.lastIndexOf('/') + 1);
			if (!/\.[A-Za-z0-9]+$/.test(base)) continue;
			if (!tailIndex.has(base)) tailIndex.set(base, []);
			tailIndex.get(base).push(p);
		}
	}
	const name = tail.slice(tail.lastIndexOf('/') + 1);
	return (tailIndex.get(name) || []).filter((p) => p.endsWith(`/${tail}`));
}

/**
 * A quoted module name at `index` of a tool listed in edits.cjs
 * MODULE_NAME_FILES: one of the tool's own JavaScript values (a property, an
 * element or a comparison operand, in single quotes).
 */
function isListedModuleSite(file, text, index) {
	return (
		Edits.MODULE_NAME_FILES.some((e) => e.file === file) &&
		text[index] === "'" &&
		/(?:[\w$]+\s*:|[[,(]|[!=]==?)\s*$/.test(text.slice(Math.max(0, index - 40), index))
	);
}

/**
 * True when the path at `index` is joined onto a base named for a driver
 * (${DRIVER_REL}/modules/llm, WIN .. "/modules"): it is that driver's folder,
 * not the shared one of the same name.
 */
function foreignBaseBefore(text, index) {
	const base = text
		.slice(Math.max(0, index - 40), index)
		.match(/(?:\$\{\s*([\w$.]+)\s*\}|([\w$.]+)\s*\.\.\s*["'])$/);
	return !!base && /driver|windows|macos|linux|\bwin\b|_WIN|WIN_/i.test(base[1] || base[2]);
}

let listText = null;
let listRanges = [];
/**
 * The array constants of a file whose elements it hands, one by one, to a
 * shared helper: `SOURCES.map((s) => sharedRel(s))`, `for (const [name,
 * file] of TABLES) … shared(file)`. Their literals are relative to _shared.
 * @returns {Array<[number, number]>} The offsets each array literal spans.
 */
function sharedLists(text) {
	if (text === listText) return listRanges;
	listRanges = [];
	for (const m of text.matchAll(/\bconst\s+([A-Z][A-Z0-9_]*)\s*=\s*\[/g)) {
		const name = m[1];
		const uses = [
			...text.matchAll(
				new RegExp(
					`\\b${name}\\.(?:map|flatMap|forEach|some|every|filter)\\(\\s*\\(?([^)=]*)\\)?\\s*=>([^\\n]*)`,
					'g'
				)
			),
			...text.matchAll(
				new RegExp(`\\bfor\\s*\\(\\s*const\\s+([^)]*?)\\s+of\\s+${name}\\s*\\)([^\\n]*)`, 'g')
			)
		];
		const handed = uses.some((u) =>
			(u[1].match(/[A-Za-z_]\w*/g) || []).some((param) => handsToShared(u[2], param))
		);
		if (!handed) continue;
		// The array runs to its matching bracket.
		let depth = 0;
		let end = -1;
		for (let i = m.index + m[0].length - 1; i < text.length; i++) {
			if (text[i] === '[') depth++;
			else if (text[i] === ']' && --depth === 0) {
				end = i;
				break;
			}
		}
		if (end > 0) listRanges.push([m.index + m[0].length - 1, end]);
	}
	// for (const rel of ['modules/features/manifest.toml', …]) … resolve(sharedDir, rel)
	for (const m of text.matchAll(/\bfor\s*\(\s*const\s+([A-Za-z_]\w*)\s+of\s+\[([^\]]*)\]\s*\)/g)) {
		const body = text.slice(m.index + m[0].length, m.index + m[0].length + 400);
		if (handsToShared(body, m[1]))
			listRanges.push([m.index + m[0].indexOf('['), m.index + m[0].lastIndexOf(']')]);
	}
	listText = text;
	return listRanges;
}

/** True when `code` hands `name` to a shared helper or joins it onto a shared base. */
function handsToShared(code, name) {
	return (
		new RegExp(`\\b\\w*[sS]hared(?!_llm)\\w*\\(\\s*${name}\\s*\\)`).test(code) ||
		new RegExp(
			`\\b(?:path\\.)?(?:resolve|join)\\(\\s*\\w*[sS][hH][aA][rR][eE][dD]\\w*\\s*,\\s*${name}\\s*\\)`
		).test(code)
	);
}

// A JavaScript require of a Node module or a dependency is not a Lua load,
// even where a Lua module shares its name ("crypto", "path").
const NODE_MODULES = new Set([
	...require('node:module').builtinModules,
	...(fs.existsSync(path.join(ROOT, 'node_modules'))
		? fs.readdirSync(path.join(ROOT, 'node_modules'))
		: [])
]);

/** A one-line Lua string literal; group 2 is its content. */
const LUA_SHORT_STRING = /(["'])((?:\\.|(?!\1)[^\\\n])*)\1/g;
/** A dotted name bounded inside a string: not a prefix of a longer name. */
const INLINE_MODULE_NAME = /(?<![\w.%])([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+)(?!\w|\.[A-Za-z_])/g;
/** A Lua table constructor of string literals only. */
const LUA_NAME_TABLE =
	/\{\s*(?:--[^\n]*\n\s*)*(?:(["'])[A-Za-z_][\w.]*\1\s*[,;]\s*(?:--[^\n]*\n\s*)*)*(["'])[A-Za-z_][\w.]*\2\s*[,;]?\s*(?:--[^\n]*\n\s*)*\}/g;

/** Code just before a quoted name that loads it as a Lua module. */
// Logger.error( before a quoted tag: the tag names the logging module.
const LUA_LOG_TAG_BEFORE = /\bLogger\.\w+\s*\(\s*$/;

/** True when the quoted name at `index` is the tag of a Lua Logger call. */
function isLuaLogTagSite(text, index) {
	return LUA_LOG_TAG_BEFORE.test(text.slice(Math.max(0, index - 40), index));
}

const MODULE_LOAD_BEFORE =
	/(?:\brequire\s*(?:[%\\]?\()?|\bpackage\.(?:loaded|preload)\s*\[|\bpcall\s*\(\s*require\s*,|\brequire_\w*\s*\(|\b\w*_require\s*\(|\b\w*(?:load|fresh)_(?:module|with_stubs)\s*\(|\brawget\s*\(\s*package\.(?:loaded|preload)\s*,|\bsearchpath\s*\()\s*$/;

/**
 * Tells whether the quoted token at `index` is a Lua module load: a require
 * argument or a package.loaded / package.preload key.
 * @param {string} text Source text.
 * @param {number} index Offset of the opening quote.
 * @returns {boolean}
 */
function isModuleLoadSite(text, index) {
	const before = text.slice(Math.max(0, index - 80), index);
	if (MODULE_LOAD_BEFORE.test(before)) return true;
	const alias = loadedAliases(text);
	if (alias !== null && alias.test(before)) return true;
	if (keyedByModuleName(text, index, before)) return true;
	const wrappers = requireWrappers(text);
	if (wrappers !== null && wrappers.test(before)) return true;
	return comparesModuleName(text, index, before);
}

let wrapperText = null;
let wrapperPattern = null;
/**
 * The local functions of a file that hand their only parameter to require
 * (local function collision_dependency(name) local loaded, owner =
 * pcall(require, name) … end): a call of one loads its argument.
 * @returns {RegExp|null} The code before a quoted argument of such a call.
 */
function requireWrappers(text) {
	if (text !== wrapperText) {
		const names = [];
		for (const m of text.matchAll(
			/\blocal\s+function\s+([A-Za-z_]\w*)\s*\(\s*([A-Za-z_]\w*)\s*\)([^\n]*\n){0,4}/g
		)) {
			const body = m[0].slice(m[0].indexOf(')') + 1);
			const param = m[2];
			if (
				new RegExp(`\\b(?:pcall\\s*\\(\\s*require\\s*,|require\\s*\\()\\s*${param}\\s*\\)`).test(
					body
				)
			)
				names.push(m[1]);
		}
		wrapperPattern = names.length > 0 ? new RegExp(`\\b(?:${names.join('|')})\\s*\\(\\s*$`) : null;
		wrapperText = text;
	}
	return wrapperPattern;
}

/**
 * A key of a table keyed by module names, the require stand-ins of a test
 * ({ ["tests.helpers"] = reporter, ["text_utils"] = { … } }): a one-word key
 * beside dotted ones is a module name too.
 */
function keyedByModuleName(text, index, before) {
	if (!/\[\s*$/.test(before)) return false;
	const close = text.slice(index).match(/^(["'])[A-Za-z_]\w*\1\s*\]\s*=/);
	if (!close) return false;
	const around = text.slice(Math.max(0, index - 400), index + 400);
	return /\[\s*(["'])[a-z_]\w*(?:\.[a-z_]\w*)+\1\s*\]\s*=/.test(around);
}

let scopeText = null;
let scopes = [];
/**
 * A comparison with a variable that holds a module name: the parameter of a
 * require stand-in (require = function(name) … name == "number_policy") or
 * the key of a walk of package.loaded (for key in pairs(package.loaded) …
 * key ~= "logger"). Each holds within the next lines after it is bound.
 */
function comparesModuleName(text, index, before) {
	if (text !== scopeText) {
		scopes = [];
		for (const m of text.matchAll(/\brequire\s*=\s*function\s*\(\s*(\w+)/g))
			scopes.push({ name: m[1], from: m.index, to: m.index + 1500 });
		for (const m of text.matchAll(
			/\bfor\s+(\w+)[^\n]*?\bin\s+(?:next\s*,|i?pairs\s*\()\s*package\.loaded\b/g
		))
			scopes.push({ name: m[1], from: m.index, to: m.index + 800 });
		scopeText = text;
	}
	for (const sc of scopes) {
		if (index < sc.from || index > sc.to) continue;
		if (new RegExp(`\\b${sc.name}\\s*[=~]=\\s*$`).test(before)) return true;
	}
	return false;
}

let aliasText = null;
let aliasPattern = null;
/**
 * The names a file gives package.loaded (local Modules = package.loaded;
 * local cache, saved = package.loaded, {}): rawget(Modules, "x") and
 * cache["x"] are load sites like package.loaded["x"].
 * @returns {RegExp|null} The pattern of text just before such a key.
 */
function loadedAliases(text) {
	if (text === aliasText) return aliasPattern;
	const names = new Set();
	for (const m of text.matchAll(/\blocal\s+([\w\s,]+?)\s*=\s*([^\n]+)/g)) {
		const vars = m[1].split(',').map((v) => v.trim());
		const values = m[2].split(',').map((v) => v.trim());
		vars.forEach((v, i) => {
			if (/^package\.loaded\b/.test(values[i] || '') && /^\w+$/.test(v)) names.add(v);
		});
	}
	aliasText = text;
	aliasPattern =
		names.size === 0
			? null
			: new RegExp(
					`(?:\\brawget\\s*\\(\\s*(?:${[...names].join('|')})\\s*,|\\b(?:${[...names].join('|')})\\s*\\[)\\s*$`
				);
	return aliasPattern;
}

// ──────────────────────────────────────────────────────────────────────────────
// The shared Lua root switch
// ──────────────────────────────────────────────────────────────────────────────

// Today the shared Lua root is _shared/lua; in the target it is _shared itself.
// The step that empties _shared/lua turns every resolver into one of _shared in
// the same commit (docs/design/structure-plan.md, Lua module names), so there
// is never a period with two shared roots.
const SHARED_LUA_ROOT = '_shared/lua/';

// An expression naming the shared root: shared, SHARED, shared_root,
// logger_shared_root, Paths.shared_root() …
const SHARED_IDENT = String.raw`((?:[A-Za-z_]\w*\.)*[A-Za-z_]*[Ss][Hh][Aa][Rr][Ee][Dd]\w*(?:\(\))?)`;

/**
 * The rewrites of the root switch, in order. Paths to files and folders that
 * move are rewritten first, as ordinary path tokens; these catch what is left:
 * the root spelled as a folder (LUA_PATH patterns, install layouts, fixture
 * trees), the shared test modules' folder, and the root built by a join onto
 * an expression that names _shared.
 */
const SHARED_ROOT_REWRITES = [
	// The shared test modules' folder: its files are rewritten one by one
	// above, so what is left names the folder as a whole (an exclusion, a
	// prune, a test-double root), which is now the shared test tree.
	[/(?<![A-Za-z0-9_.-])_shared([\\/])lua\1test(?![A-Za-z0-9_.-])/g, '_shared$1tests'],
	[/(?<![A-Za-z0-9_.-])_shared([\\/])lua(?![A-Za-z0-9_.-])/g, '_shared'],
	// shared_root .. "/lua": the whole literal names the root.
	[new RegExp(`${SHARED_IDENT}\\s*\\.\\.\\s*(["'])\\/?lua\\2`, 'g'), '$1'],
	// shared .. "/lua/?.lua;" and SHARED .. "lua/?.lua;".
	[new RegExp(`${SHARED_IDENT}(\\s*\\.\\.\\s*)(["'])(\\/?)lua\\/`, 'g'), '$1$2$3$4'],
	// '_shared' .. sep .. 'lua': the root joined with a separator variable.
	[/(["'])_shared\1(\s*\.\.\s*[A-Za-z_]\w*\s*\.\.\s*)(["'])lua\3/g, '$1_shared$1'],
	// JavaScript: SHARED_ROOT + '/lua'.
	[new RegExp(`${SHARED_IDENT}\\s*\\+\\s*(["'])\\/?lua\\2`, 'g'), '$1'],
	// Python: shared / "lua".
	[new RegExp(`${SHARED_IDENT}\\s*\\/\\s*(["'])lua\\2`, 'g'), '$1'],
	// shared('lua', modulePath) in a tool: the module path is now _shared-relative.
	[/\bshared\(\s*(['"])lua\1\s*,\s*/g, 'shared('],
	// arg[1] .. "/lua/?.lua;": a LUA_PATH fragment only the shared Lua root has.
	[/(["'])\/lua\/\?(\.lua|\/init\.lua)/g, '$1/?$2'],
	// Paths.shared("lua") asks for the root itself.
	[/\bPaths\.shared\(\s*(["'])lua\1\s*\)/g, 'Paths.shared_root()'],
	// helpers.shared("lua/") in a test asks for the root itself.
	[/(\.shared\(\s*)(["'])lua\/?\2(\s*\))/g, '$1$2$2$3']
];

/** True when `text` spells the shared Lua root in a form the switch rewrites. */
function hasSharedRoot(text) {
	return SHARED_ROOT_REWRITES.some(([re]) => new RegExp(re.source).test(text));
}

/** Applies the shared Lua root switch to one file's text. */
function sharedRootRewrite(text) {
	return SHARED_ROOT_REWRITES.reduce((out, [re, to]) => out.replace(re, to), text);
}

/**
 * True when `map` moves every file out of `folder` (tree-relative).
 * @param {Map<string, string|null>} map Tree-relative old path to target.
 */
function emptiesFolder(map, folder) {
	const prefix = `${folder}/`;
	let leaves = false;
	for (const [o, t] of map) {
		if (t && t.startsWith(prefix)) return false;
		if (o.startsWith(prefix) && t !== o) leaves = true;
	}
	return leaves;
}

/**
 * True when `map` empties the shared Lua root: the step that does it carries
 * the switch.
 * @param {Map<string, string|null>} map Tree-relative old path to target.
 */
function switchesSharedRoot(map) {
	let leaves = false;
	for (const [o, t] of map) {
		if (t && t.startsWith(SHARED_LUA_ROOT)) return false;
		if (o.startsWith(SHARED_LUA_ROOT) && t !== o) leaves = true;
	}
	return leaves;
}

/**
 * Classifies one module a runtime edit expects.
 * @param {Map<string, Array>} byLuaName Moved modules by "<root>|<old name>".
 * @param {Set<string>} presentNames Module names the tree answers today.
 * @param {string} tree Driver root of the module.
 * @param {string} oldName Name the edit's source builds today.
 * @param {string} newName Name the edit writes.
 * @returns {'moving'|'moved'|'pending'|'wrong'} moving: this map renames it to
 *   newName; moved: an earlier step did; pending: a later step will; wrong: the
 *   plan sends it elsewhere.
 */
function runtimeEditState(byLuaName, presentNames, tree, oldName, newName) {
	const hit = byLuaName.get(`${tree}|${oldName}`);
	if (hit) return hit[2] === newName ? 'moving' : 'wrong';
	if (presentNames.has(`${tree}|${newName}`)) return 'moved';
	if (presentNames.has(`${tree}|${oldName}`)) return 'pending';
	return 'wrong';
}

// A call argument list that spells a path in pieces:
// path.join(ROOT, 'tree', 'folder', 'file.json'). The literals after any leading
// expression arguments are the path; at least two of them, since one literal is
// an ordinary path token.
const JOIN_CALL =
	/\b([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\(\s*((?:[A-Za-z_$][\w$.]*(?:\((?:\s*[A-Za-z_$][\w$]*\s*)?\))?\s*,\s*)*)/g;
const JOIN_LITERAL = /(['"])([\w@.-]+(?:\/[\w@.-]+)*)\1/y;
const JOIN_COMMA = /\s*,\s*/y;

/**
 * The path-shaped literal runs of a JavaScript file.
 * @returns {{text: string, parts: string[], quote: string, callee: string, separator: string}[]}
 */
function joinedPaths(text) {
	const out = [];
	for (const m of text.matchAll(JOIN_CALL)) {
		let at = m.index + m[0].length;
		const start = at;
		const parts = [];
		let quote = null;
		let separator = null;
		for (;;) {
			JOIN_LITERAL.lastIndex = at;
			const lit = JOIN_LITERAL.exec(text);
			if (!lit) break;
			quote = quote || lit[1];
			parts.push(lit[2]);
			at = JOIN_LITERAL.lastIndex;
			JOIN_COMMA.lastIndex = at;
			const comma = JOIN_COMMA.exec(text);
			if (!comma) break;
			JOIN_LITERAL.lastIndex = JOIN_COMMA.lastIndex;
			if (!JOIN_LITERAL.test(text)) break;
			separator = separator || comma[0];
			at = JOIN_COMMA.lastIndex;
		}
		// One literal joined onto a named base (path.join(DATA, 'x.json')) is a
		// path too, when the base is a constant the file defines.
		// shared('keymap', vector.file): a folder handed on with a name to join.
		const more = /^\s*,\s*[^\s'"`)]/.test(text.slice(at));
		const after = (text.slice(at).match(/^\s*,\s*([^\s,)]+)/) || [])[1] || null;
		if (parts.length < 2 && !(parts.length === 1 && (m[2].trim() || more))) continue;
		out.push({
			more,
			after,
			index: start,
			// The call up to the joined pieces: the row matches at this site only.
			prefix: text.slice(m.index, start),
			text: text.slice(start, at),
			parts,
			quote,
			callee: m[1],
			before: m[2],
			separator
		});
	}
	return out;
}

/**
 * Spells a path relative to a join's base in the join's own pieces: one
 * literal per segment, except where the run was one path argument
 * (shared_json("data/x.json", true) keeps a single argument before `true`).
 */
function renderJoin(j, rel) {
	// A lone literal that already holds a separator, or one followed by a
	// flag rather than a further piece, is one path argument.
	const single =
		j.parts.length === 1 &&
		(j.parts[0].includes('/') || /^(?:true|false|nil|null|undefined|\d+)$/.test(j.after || ''));
	const pieces = single ? [rel] : rel.split('/');
	return pieces.map((p) => `${j.quote}${p}${j.quote}`).join(j.separator || ', ');
}

/**
 * Resolves a joined literal run to a moved file or folder, and renders its
 * new spelling in the same pieces: one literal per path segment below the
 * base the run started from.
 */
function resolveJoinedPath(j, byRepoPath, byRepoDir, successors, env = new Map()) {
	const joined = path.posix.normalize(j.parts.join('/'));
	const named = (j.before || '')
		.split(',')
		.map((a) => a.trim())
		.filter(Boolean);
	const baseName = named[named.length - 1];
	if (baseName && env.has(baseName))
		return resolveOnBase(j, env.get(baseName), joined, byRepoPath, byRepoDir, successors);
	// path.join(path.dirname(FIXTURE_DIR), '..', 'x'): the folder of a known base.
	const ofDir = (baseName || '').match(/^path\.dirname\(\s*([A-Za-z_$][\w$]*)\s*\)$/);
	// Its pieces follow only a base that stays: nothing respells the base
	// expression itself, so a moving one is a refusal.
	if (ofDir && env.has(ofDir[1])) {
		const dir = path.posix.dirname(env.get(ofDir[1]));
		if (newFolder(dir, byRepoDir, successors) !== dir)
			return { kind: 'join-split', rendered: '(split)', oldRepo: dir, newRepo: null };
	}
	if (ofDir && env.has(ofDir[1]))
		return resolveOnBase(
			j,
			path.posix.dirname(env.get(ofDir[1])),
			joined,
			byRepoPath,
			byRepoDir,
			successors
		);
	// resolve(SHARED_ROOT, 'modules/llm'): a base the file imports, named for _shared.
	if (baseName && /^\w*shared\w*$/i.test(baseName))
		return resolveOnBase(j, `${PREFIX}_shared`, joined, byRepoPath, byRepoDir, successors);
	if (j.parts.length < 2 && !(j.more && /shared/i.test(j.callee))) return null;
	const bases = [];
	if (joined.startsWith(PREFIX)) bases.push('');
	if (Census.TREES.some((t) => joined === t || joined.startsWith(`${t}/`))) bases.push(PREFIX);
	// shared('modules', 'llm', 'x.json') or path.join(SHARED, 'data', …): a
	// helper or a base rooted at _shared.
	if (/shared/i.test(j.callee) || /shared/i.test(j.before || '')) bases.push(`${PREFIX}_shared/`);
	for (const base of bases) {
		const oldRepo = base + joined;
		if (!EXISTING.has(oldRepo)) {
			// A file the index does not hold (a fixture a test writes, a generated
			// output) in a folder that moves whole follows its folder.
			for (let d = path.posix.dirname(oldRepo); d.length > base.length; d = path.posix.dirname(d)) {
				if (!EXISTING.has(d)) continue;
				const to = byRepoDir.get(d);
				if (!to || to === SPLIT) break;
				const newRepo = to + oldRepo.slice(d.length);
				if (!newRepo.startsWith(base)) break;
				const rendered = renderJoin(j, newRepo.slice(base.length));
				return { kind: 'join', rendered, oldRepo: d, newRepo };
			}
			continue;
		}
		let newRepo = byRepoPath.get(oldRepo) || byRepoDir.get(oldRepo);
		if (!newRepo) return null;
		let kind = 'join';
		if (newRepo === SPLIT) {
			newRepo = successors.get(oldRepo);
			kind = 'join-successor';
		}
		if (!newRepo || newRepo === PREFIX || !newRepo.startsWith(base))
			return { kind: 'join-split', rendered: '(split)', oldRepo, newRepo: null };
		const rendered = renderJoin(j, newRepo.slice(base.length));
		return { kind, rendered, oldRepo, newRepo };
	}
	return null;
}

/**
 * What references() needs to judge a file: the moves by path, folder and Lua
 * name, and the names the tree answers before and after.
 * @param {Map<string, string|null>} map Tree-relative old path to target.
 */
function referenceContext(map) {
	const moved = new Map([...map].filter(([o, t]) => o !== t));
	const byRepoPath = new Map();
	const byLuaName = new Map(); // "<root>|<name>" -> [old, target]
	for (const [old, target] of moved) {
		byRepoPath.set(PREFIX + old, PREFIX + (target || ''));
		const name = luaModuleName(old);
		if (name) {
			const root = old.startsWith('_shared/') ? '_shared' : old.split('/')[0];
			byLuaName.set(`${root}|${name}`, [old, target, luaModuleName(target, true)]);
		}
	}
	// The module names the tree answers today, so a runtime edit can tell a
	// module a later step moves from one an earlier step already moved.
	const presentNames = new Set();
	for (const old of map.keys()) {
		const name = luaModuleName(old);
		if (!name) continue;
		const root = old.startsWith('_shared/') ? '_shared' : old.split('/')[0];
		presentNames.add(`${root}|${name}`);
	}
	const targetNames = new Set();
	for (const t of map.values()) {
		const name = t && luaModuleName(t, true);
		if (name) targetNames.add(`${t.split('/')[0]}|${name}`);
	}
	const byRepoDir = directoryMap(map);
	const successors = splitSuccessors(map, byRepoDir);
	const rootSwitch = switchesSharedRoot(map);
	// Each token starts where its run of path characters starts: a match from
	// a later position of the same run is the same match, and trying them all
	// is quadratic on a long run (a generated 400 KB table took minutes).
	const pathToken = /(?<![A-Za-z0-9_.%\\/-])[A-Za-z0-9_.%\\/-]*[A-Za-z0-9_-]\.[A-Za-z0-9]+/g;
	// A folder spelled with at least one separator, quoted or not.
	// Never the folder part of a longer path: _shared/data in
	// _shared/data/identifiers.py is the file's, not a folder reference.
	const dirToken =
		/(?<![A-Za-z0-9_.%\\-])[A-Za-z0-9_.%\\-]*[\\/][A-Za-z0-9_.%\\/-]*[A-Za-z0-9_]\/?(?![A-Za-z0-9_.]|[\\/](?:[A-Za-z0-9_%-]|\.[A-Za-z0-9_]))/g;
	const luaToken = /["']([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)["']/g;
	return {
		map,
		moved,
		byRepoPath,
		byLuaName,
		presentNames,
		targetNames,
		byRepoDir,
		successors,
		rootSwitch,
		pathToken,
		dirToken,
		luaToken
	};
}

/**
 * The references one file makes to moved files.
 * @param {string} file Repository path.
 * @param {string} text Its content.
 * @param {object} ctx referenceContext(map).
 * @returns {object[]} One row per (file, old token).
 */
function scanFile(file, text, ctx) {
	const {
		map,
		moved,
		byRepoPath,
		byLuaName,
		presentNames,
		targetNames,
		byRepoDir,
		successors,
		rootSwitch,
		pathToken,
		dirToken,
		luaToken
	} = ctx;
	const rows = [];
	const code = /\.(lua|ahk)$/.test(file) ? stripComments(text, path.extname(file)) : null;
	const inTree = file.startsWith(PREFIX) ? file.slice(PREFIX.length).split('/')[0] : null;
	const category = categoryOf(file);
	const seen = new Set();
	const add = (kind, oldToken, newToken, resolution = null) => {
		const key = `${kind}|${oldToken}`;
		if (seen.has(key)) return;
		seen.add(key);
		rows.push({ file, category, kind, old: oldToken, new: newToken, resolution });
	};
	if (rootSwitch && hasSharedRoot(text))
		add('shared-root', '_shared/lua', '_shared', { oldRepo: `${PREFIX}_shared/lua` });
	// The file itself moves: what it spells relative to its own place must
	// follow it even when the target stays.
	const selfOld = inTree ? file.slice(PREFIX.length) : null;
	const selfTarget = selfOld && moved.has(selfOld) ? moved.get(selfOld) : null;
	const stays = (token, hit) =>
		!hit && selfTarget && /^\.\.?[\\/]/.test(token)
			? resolveOwnRelative(token, file, selfTarget)
			: hit;
	const sharedFolders = new Set();
	for (const m of text.matchAll(pathToken)) {
		const hit = stays(
			m[0],
			resolvePathToken(m[0], file, inTree, byRepoPath, isSharedArgument(text, m.index), byRepoDir)
		);
		if (hit) add('path', m[0], hit.newRepo === PREFIX ? '(retired)' : hit.newRepo, hit);
		// base .. "/modules/llm/defaults.json" read as _shared: the same file's
		// base .. "/modules/llm" names that shared folder too, not the driver's.
		if (hit && hit.form === 'shared' && inTree)
			for (
				let d = path.posix.dirname(m[0].replace(/\\/g, '/'));
				d && d !== '.' && d !== '/';
				d = path.posix.dirname(d)
			)
				sharedFolders.add(d.replace(/^\//, ''));
	}
	// helpers.shared("keymap/" .. name): a one-folder prefix the folder token
	// cannot see (it needs a separator inside).
	for (const m of text.matchAll(
		/(\b\w*[sS]hared(?!_llm)\w*\(\s*)(["'`])([A-Za-z0-9_.-]+)\/(?=\2|\$\{)/g
	)) {
		const hit = resolvePathToken(m[3], file, inTree, byRepoDir, true);
		if (!hit || hit.form !== 'shared' || hit.newRepo === SPLIT) continue;
		const rel = hit.newRepo.slice(`${PREFIX}_shared/`.length);
		add('shared-prefix', m[0], `${m[1]}${m[2]}${rel}/`, hit);
	}
	// src.includes('tap_hold/one_shot_shift.json'): a test checks that a source
	// names a file by the tail of its path. A tail exactly one file of the
	// repository ends with follows that file, spelled from the same base.
	if (/\.(c?js|mjs)$/.test(file))
		for (const m of text.matchAll(
			/(\.(?:includes|indexOf|lastIndexOf|startsWith|endsWith)\(\s*)(["'`])([\w.-]+(?:\/[\w.-]+)+\.[A-Za-z0-9]+)\2/g
		)) {
			const tail = m[3];
			if (Census.TREES.some((t) => tail.startsWith(`${t}/`)) || tail.startsWith(PREFIX)) continue;
			const owners = filesEndingWith(tail);
			if (owners.length !== 1 || !byRepoPath.has(owners[0])) continue;
			const base = owners[0].slice(0, -tail.length - 1);
			const target = byRepoPath.get(owners[0]);
			if (!target || target === PREFIX || !target.startsWith(`${base}/`)) continue;
			const rendered = target.slice(base.length + 1);
			add('source-check', m[0], `${m[1]}${m[2]}${rendered}${m[2]}`, {
				oldRepo: owners[0],
				newRepo: target
			});
		}
	// p:match("/modules/network/route_origins%.json$"): a Lua pattern anchored
	// on the tail of a path. A tail exactly one file ends with follows that
	// file, spelled from the same base and escaped the same way.
	if (/\.(c?js|mjs|lua)$/.test(file))
		for (const m of text.matchAll(
			/((?::|\bstring\.)(?:match|find)\(\s*(?:[\w.]+\s*,\s*)?)(["'])\/((?:\w+\/)+\w+)%\.(\w+)\$\2/g
		)) {
			const tail = `${m[3]}.${m[4]}`;
			const owners = filesEndingWith(tail);
			if (owners.length !== 1 || !byRepoPath.has(owners[0])) continue;
			const base = owners[0].slice(0, -tail.length - 1);
			const target = byRepoPath.get(owners[0]);
			if (!target || target === PREFIX || !target.startsWith(`${base}/`)) continue;
			const rendered = target.slice(base.length + 1).replace(/\./g, '%.');
			if (!/^[\w/%.]+$/.test(rendered)) continue;
			add('source-check', m[0], `${m[1]}${m[2]}/${rendered}$${m[2]}`, {
				oldRepo: owners[0],
				newRepo: target
			});
		}
	// SPEC_ONLY = { 'modules/tooltip/tint.js': … } in a tool: a bare path that
	// names a file under _shared and nothing else follows that file.
	// A captured source (a .txt snapshot of a predecessor) keeps what it held.
	// copy_tree "${SHARED_SRC}/" … --exclude modules/features/behaviors.json:
	// the same bare path, unquoted, as a shell exclusion.
	const barePaths = [
		...(/^tools\//.test(file) && !/\.txt$/.test(file)
			? text.matchAll(/(["'`])([\w.-]+(?:\/[\w.-]+)+\.[A-Za-z0-9]+)\1/g)
			: []),
		...(/^tools\/.*\.sh$/.test(file)
			? [
					...text.matchAll(/(--exclude[= ])()([\w.-]+(?:\/[\w.-]+)+\.[A-Za-z0-9]+)(?![\w.\/-])/g)
				].map((x) => Object.assign([x[0], x[1], x[3]], { unquoted: true, index: x.index }))
			: [])
	];
	if (barePaths.length > 0)
		for (const m of barePaths) {
			const rel = m[2];
			if (Census.TREES.some((t) => rel.startsWith(`${t}/`)) || rel.startsWith('static/')) continue;
			const shared = `${PREFIX}_shared/${rel}`;
			if (!EXISTING.has(shared) || EXISTING.has(rel)) continue;
			if (Census.DRIVERS.some((d) => EXISTING.has(`${PREFIX}${d}/${rel}`))) continue;
			const target = byRepoPath.get(shared);
			if (!target || target === PREFIX || !target.startsWith(`${PREFIX}_shared/`)) continue;
			const respelled = target.slice(`${PREFIX}_shared/`.length);
			add('source-check', m[0], m.unquoted ? `${m[1]}${respelled}` : `${m[1]}${respelled}${m[1]}`, {
				oldRepo: shared,
				newRepo: target
			});
		}
	// Paths.shared("data") with the file name joined on later: a whole shared
	// folder. One the plan moves whole is respelled; one it scatters is a
	// refusal, never a silent pass (the locale order was read from a folder
	// S01 emptied).
	for (const m of text.matchAll(
		/(\b\w*[sS]hared(?!_llm)\w*\(\s*)(["'`])([A-Za-z0-9_-]+)\2(?=\s*\))/g
	)) {
		if (m[3] === 'lua' && rootSwitch) continue;
		const hit = resolvePathToken(m[3], file, inTree, byRepoDir, true);
		if (!hit || hit.form !== 'shared') continue;
		if (hit.newRepo === SPLIT) {
			if (!isProse(file, text, code, m.index)) add('dir-split', m[0], '(split)', hit);
			continue;
		}
		const rel = hit.newRepo.slice(`${PREFIX}_shared/`.length);
		add('shared-prefix', m[0], `${m[1]}${m[2]}${rel}${m[2]}`, hit);
	}
	if (selfTarget && file.endsWith('.lua')) {
		for (const t of ownTails(text, selfOld, selfTarget))
			add('lua-tail', t.old, t.new, { oldRepo: file });
		for (const c of ownClimbs(text, selfOld, selfTarget))
			add('lua-climb', c.old, c.new, { oldRepo: file });
	}
	for (const m of text.matchAll(dirToken)) {
		const raw = m[0].replace(/[\\/]$/, '');
		if (/\.[A-Za-z0-9]+$/.test(raw) || !/[A-Za-z]/.test(raw)) continue;
		// ${DRIVER_REL}/modules/llm: a base named for a driver keeps the folder
		// the driver's own, whatever the file reads from _shared elsewhere.
		const foreign = foreignBaseBefore(text, m.index);
		const explicit =
			isSharedArgument(text, m.index) ||
			(!foreign && sharedFolders.has(raw.replace(/\\/g, '/').replace(/^\//, '')));
		const hit = stays(raw, resolvePathToken(raw, file, inTree, byRepoDir, explicit));
		if (!hit) continue;
		// parent .. "/python" in live code: one folder name read against the
		// file's tree or _shared by guess alone is no reference to either.
		if (
			!explicit &&
			!['repo', 'tree', 'embedded', 'shared-alias'].includes(hit.form) &&
			raw
				.replace(/\\/g, '/')
				.replace(/^\/|\/$/g, '')
				.split('/').length === 1 &&
			!isProse(file, text, code, m.index)
		)
			continue;
		if (hit.newRepo !== SPLIT) {
			add('dir', raw, hit.newRepo, hit);
			continue;
		}
		// A folder the plan scatters: prose and comments name its nearest common
		// new folder; live code is a refusal until rules.cjs resolves the site.
		const prose = isProse(file, text, code, m.index);
		const successor = successors.get(hit.oldRepo);
		// A folder whose files only move within it (windows/tests/meta/adapters
		// to windows/tests/meta/core/crypto) keeps its name: nothing to respell,
		// and a respelling would lose the escapes of a regular expression.
		if (successor === hit.oldRepo) continue;
		const deep = successor && successor.split('/').length > 3;
		// A lone scattered folder whose nearest new folder is a tree root
		// itself names no folder at all in live code (tmp .. "/modules" became
		// tmp .. ""): a refusal, not an empty name.
		const rootOnly =
			successor &&
			Census.TREES.some((t) => successor === `${PREFIX}${t}`) &&
			raw
				.replace(/\\/g, '/')
				.replace(/^\/+|\/+$/g, '')
				.split('/').length === 1;
		// A scattered folder whose nearest new home is a driver root: in live
		// code, the root would widen a scan to the whole driver. An element of a
		// list on its own line becomes one element per real new home.
		if (!prose && successor && Census.DRIVERS.some((d) => successor === `${PREFIX}${d}`)) {
			const expanded = splitScopeLine(text, m.index, raw, hit.oldRepo, map);
			if (expanded) add('scope-split', expanded.old, expanded.new, hit);
			// A folder that keeps files keeps its name, for the reviewer and the
			// step's gates (a scan that must also read the new homes fails
			// there); one the step empties names nothing and is refused.
			else if (splitHomes(hit.oldRepo, map)[0] === hit.oldRepo.slice(PREFIX.length))
				add('dir-kept', raw, raw, hit);
			else add('dir-split', raw, '(split)', hit);
			continue;
		}
		if (prose && deep) add('dir', raw, successor, { ...hit, newRepo: successor });
		else if (prose) add('dir-split-prose', raw, '(split)', hit);
		else if (successor && !rootOnly)
			add('dir-successor', raw, successor, { ...hit, newRepo: successor });
		else add(prose ? 'dir-split-prose' : 'dir-split', raw, '(split)', hit);
	}
	const jsEnv = /\.(c?js|mjs)$/.test(file) ? jsConstants(text, file) : new Map();
	// path.join(root, `../data/locales/${code}.json`): the template's leading
	// folder joined onto a known base follows that folder.
	for (const m of text.matchAll(
		/\b(?:path\.)?(?:join|resolve)\(\s*([A-Za-z_$][\w$]*)\s*,\s*`((?:\.\.\/)*[\w.-]+(?:\/[\w.-]+)*)\/\$\{/g
	)) {
		if (!jsEnv.has(m[1])) continue;
		const j = { parts: [m[2]], quote: '`', separator: '', text: `\`${m[2]}` };
		const hit = resolveOnBase(j, jsEnv.get(m[1]), m[2], byRepoPath, byRepoDir, successors);
		if (!hit || hit.kind !== 'join') continue;
		const piece = hit.rendered.slice(1, -1);
		add('join', m[0], m[0].replace(`\`${m[2]}/`, `\`${piece}/`), hit);
	}
	// resolve(SHARED, 'data/locales/' + code + '.json'): a folder piece, kept
	// with its trailing slash, concatenated onto a name and joined onto a base.
	for (const m of text.matchAll(
		/\b(?:path\.)?(?:join|resolve)\(\s*([A-Za-z_$][\w$]*)\s*,\s*(['"])((?:\.\.\/)*[\w.-]+(?:\/[\w.-]+)*)\/\2\s*\+/g
	)) {
		if (!jsEnv.has(m[1])) continue;
		const j = { parts: [m[3]], quote: m[2], separator: '', text: `${m[2]}${m[3]}` };
		const hit = resolveOnBase(j, jsEnv.get(m[1]), m[3], byRepoPath, byRepoDir, successors);
		if (!hit || hit.kind !== 'join') continue;
		const piece = hit.rendered.slice(1, -1);
		add('join', m[0], m[0].replace(`${m[2]}${m[3]}/`, `${m[2]}${piece}/`), hit);
	}
	// root .. "locale_order.json" onto a folder constant of a Lua file.
	const luaEnv = luaConstants(text, file, inTree);
	for (const [name, base] of luaEnv) {
		const use = new RegExp(`\\b${name}\\s*\\.\\.\\s*(["'])([\\w.\\/-]+)\\1`, 'g');
		for (const m of text.matchAll(use)) {
			const lead = m[2].startsWith('/') ? '/' : '';
			// root .. "locales/" .. code: a folder piece keeps its trailing slash.
			const trail = m[2].length > 1 && m[2].endsWith('/') ? '/' : '';
			const j = {
				parts: [m[2].replace(/^\//, '').replace(/\/$/, '')],
				quote: m[1],
				separator: '',
				text: `${m[1]}${m[2]}${m[1]}`
			};
			const hit = resolveOnBase(j, base, j.parts[0], byRepoPath, byRepoDir, successors);
			if (!hit || hit.kind !== 'join') continue;
			const piece = hit.rendered.slice(1, -1);
			add('lua-concat', m[0], m[0].replace(j.text, `${m[1]}${lead}${piece}${trail}${m[1]}`), hit);
		}
	}
	// ROOT / "static" / "ergopti_plus" / "_shared" / "data" / "x.sql": a Python
	// path joined with the / operator, read from the tree it passes through;
	// os.path.join(root, "_shared", "data", "locales") the same with commas.
	// A script with a Python shebang and no extension is Python too.
	if (file.endsWith('.py') || /^#![^\n]*\bpython/.test(text))
		for (const m of text.matchAll(/\s*([/,])\s*(["'])[\w.?-]+\2(?:\s*\1\s*(["'])[\w.?-]+\3)*/g)) {
			const pieces = [...m[0].matchAll(/(["'])([\w.?-]+)\1/g)].map((x) => x[2]);
			const at = pieces.findIndex((p) => Census.TREES.includes(p));
			if (at < 0 || at === pieces.length - 1) continue;
			let tail = pieces.slice(at);
			let lua = false;
			if (rootSwitch && tail[0] === '_shared' && tail[1] === 'lua') {
				tail = ['_shared', ...tail.slice(2)];
				lua = true;
			}
			const wild = tail.some((p) => p.includes('?'));
			const repo = PREFIX + tail.join('/');
			let target = null;
			if (!wild) {
				// A whole move only: a scattered folder has no one new spelling here.
				const moved = byRepoPath.get(repo) || byRepoDir.get(repo);
				if (moved === SPLIT && !isProse(file, text, code, m.index)) {
					add('dir-split', m[0].trim(), '(split)', { oldRepo: repo });
					continue;
				}
				if (moved && moved !== SPLIT && moved !== repo && EXISTING.has(repo)) target = moved;
			}
			if (!target && !lua) continue;
			const quote = m[0].match(/["']/)[0];
			const kept = pieces.slice(0, at).map((p) => `${quote}${p}${quote}`);
			const fresh = (target ? target.slice(PREFIX.length).split('/') : tail).map(
				(p) => `${quote}${p}${quote}`
			);
			add(
				'join',
				m[0].trim().replace(/^[/,]\s*/, ''),
				[...kept, ...fresh].join(m[1] === '/' ? ' / ' : ', '),
				{
					oldRepo: repo,
					newRepo: target || repo
				}
			);
		}
	// /\\modules\\llm\\x\.json"/ in a tool: an AutoHotkey path, joined onto
	// _SharedDir (or the driver's own folder), checked with a regular expression.
	if (/^tools\/.*\.(c?js|mjs)$/.test(file))
		for (const m of text.matchAll(/(?<![\w\\])(?:\\\\[\w-]+)+(?:\\\.[A-Za-z0-9]+)(?![\w\\])/g)) {
			const plain = m[0].replace(/\\\\/g, '/').replace(/\\\./g, '.');
			const base = [`${PREFIX}_shared`, `${PREFIX}windows`].find((b) => EXISTING.has(b + plain));
			if (!base) continue;
			const target = byRepoPath.get(base + plain);
			if (!target || target === PREFIX || !target.startsWith(`${base}/`)) continue;
			const rel = target.slice(base.length);
			add('path-regex', m[0], rel.replace(/\./g, '\\.').replace(/\//g, '\\\\'), {
				oldRepo: base + plain,
				newRepo: target
			});
		}
	// /_shared\/data\/identifiers\.(py|sh)/: a regex path with an extension
	// alternation, respelled when every alternative moves to the same folder.
	if (/\.(c?js|mjs)$/.test(file))
		for (const m of text.matchAll(
			/(?<![\w-])([\w-]+(?:\\\/[\w-]+)+)\\\.\(((?:[A-Za-z0-9]+\|)+[A-Za-z0-9]+)\)/g
		)) {
			const stem = m[1].replace(/\\\//g, '/');
			const repo = stem.startsWith(PREFIX) ? stem : `${PREFIX}${stem}`;
			const targets = m[2].split('|').map((ext) => byRepoPath.get(`${repo}.${ext}`));
			if (targets.some((t) => !t || t === PREFIX)) continue;
			const stems = new Set(targets.map((t, i) => t.slice(0, -(m[2].split('|')[i].length + 1))));
			if (stems.size !== 1) continue;
			const fresh = [...stems][0];
			const spelled = stem.startsWith(PREFIX) ? fresh : fresh.slice(PREFIX.length);
			add('path-regex', m[1], spelled.replace(/\//g, '\\/'), { oldRepo: repo, newRepo: fresh });
		}
	// A Lua module name in a tool's regular expression: /tap_hold\.hold_options/.test(src).
	// Tools only: a page's /^network\.failure\./ matches a locale key.
	if (/^tools\/.*\.(c?js|mjs)$/.test(file))
		for (const rx of text.matchAll(/(?<=[(=!,:&|?]\s*)\/((?:\\.|[^/\\\n])+)\/[dgimsuy]*/g))
			for (const m of rx[1].matchAll(/(?<![\w\\])[A-Za-z_]\w*(?:\\\.[A-Za-z_]\w*)+(?![\w])/g)) {
				const name = m[0].replace(/\\\./g, '.');
				if (configKeys().has(name) || localeKeys().has(name)) continue;
				const hit = byLuaName.get(`_shared|${name}`);
				if (hit && hit[2] && hit[2] !== name)
					add('path-regex', m[0], hit[2].replace(/\./g, '\\.'), { oldRepo: PREFIX + hit[0] });
			}
	// A path in a regular expression: /static\/ergopti_plus\/_shared\/x\.json/.
	if (/\.(c?js|mjs)$/.test(file))
		for (const m of text.matchAll(/(?<![\w-])[\w-]+(?:\\\/[\w-]+)+(?:\\\.[A-Za-z0-9]+)?/g)) {
			const plain = m[0].replace(/\\\//g, '/').replace(/\\\./g, '.');
			const isFile = /\.[A-Za-z0-9]+$/.test(plain);
			// A tool's regex of a bare relative path (shared\("modules\/llm\/x\.json"\))
			// names it under _shared, where the drivers' resolvers read it.
			const hit = resolvePathToken(
				plain,
				file,
				inTree,
				isFile ? byRepoPath : byRepoDir,
				!inTree && /^tools\//.test(file) && !plain.startsWith('static/')
			);
			if (
				!hit ||
				hit.newRepo === SPLIT ||
				hit.newRepo === PREFIX ||
				!['repo', 'tree', 'shared'].includes(hit.form)
			)
				continue;
			const spelled =
				hit.form === 'repo'
					? hit.newRepo
					: hit.form === 'shared'
						? hit.newRepo.slice(`${PREFIX}_shared/`.length)
						: hit.newRepo.slice(PREFIX.length);
			add('path-regex', m[0], spelled.replace(/\./g, '\\.').replace(/\//g, '\\/'), hit);
		}
	if (/\.(c?js|mjs|lua|py)$/.test(file))
		for (const j of joinedPaths(text)) {
			const hit = resolveJoinedPath(j, byRepoPath, byRepoDir, successors, jsEnv);
			if (!hit) continue;
			// shared('lua', name): the root switch drops the 'lua' piece, so a
			// join onto the old root is respelled by the switch, not refused.
			if (
				rootSwitch &&
				hit.kind === 'join-split' &&
				`${hit.oldRepo}/` === PREFIX + SHARED_LUA_ROOT &&
				sharedRootRewrite(lineAt(text, j.index)) !== lineAt(text, j.index)
			)
				continue;
			// With its call prefix, so the same pieces elsewhere ('lua' in a file
			// name expression) are left alone.
			add(hit.kind, j.prefix + j.text, j.prefix + hit.rendered, hit);
		}
	// "ergopti_plus/_shared/modules/llm/validate_*.py": a glob whose last segment
	// holds the wildcard; its folder follows a folder that moves whole.
	for (const m of text.matchAll(/(["'])([\w.%\/-]+\/[\w.%-]+)\/([^\/"'\s*]*[*?][^\/"'\s]*)\1/g)) {
		const hit = resolvePathToken(m[2], file, inTree, byRepoDir);
		if (!hit || hit.newRepo === SPLIT || hit.newRepo === PREFIX) continue;
		// Never widened to a whole tree (_shared/lua/** is the root switch's).
		if (Census.TREES.some((t) => hit.newRepo === `${PREFIX}${t}`)) continue;
		const respelled =
			hit.form === 'repo'
				? hit.newRepo
				: hit.form === 'tree'
					? hit.newRepo.slice(PREFIX.length)
					: hit.form === 'embedded'
						? hit.keep + hit.newRepo.slice(PREFIX.length)
						: null;
		if (respelled && respelled !== m[2])
			add('source-check', m[0], `${m[1]}${respelled}/${m[3]}${m[1]}`, hit);
	}
	// SHARED_MODS=( "keycodes.evdev" … ) looped into pcall(require, '${mod}'): a
	// shell array of the module names a Lua one-liner loads.
	if (/\.sh$/.test(file))
		for (const m of text.matchAll(/\b([A-Za-z_]\w*)=\(([^()]*)\)/g)) {
			const loop = text.match(new RegExp(`\\bfor\\s+(\\w+)\\s+in\\s+"\\$\\{${m[1]}\\[@\\]\\}"`));
			if (!loop || !new RegExp(`require\\s*[,(]\\s*['"]\\$\\{${loop[1]}\\}['"]`).test(text))
				continue;
			const next = m[0].replace(/"([A-Za-z_][\w.]*)"/g, (whole, name) => {
				const hit = byLuaName.get(`_shared|${name}`);
				return hit && hit[2] ? `"${hit[2]}"` : whole;
			});
			if (next !== m[0]) add('lua-module-list', m[0], next, { oldRepo: `${PREFIX}_shared` });
		}
	// A scan scope over a folder the plan scatters (edits.cjs FOLDER_EDITS):
	// the step that empties the folder rewrites it as listed, and a listed
	// text that no longer matches refuses the step instead of passing silently.
	// An edit keyed on a file (`moves`) belongs to the step that moves it.
	for (const e of Edits.FOLDER_EDITS) {
		const due = e.moves
			? !!map.get(e.moves) && map.get(e.moves) !== e.moves
			: emptiesFolder(map, e.empties);
		if (e.file !== file || !due) continue;
		const oldRepo = PREFIX + (e.moves || e.empties);
		if (text.includes(e.from)) add('folder-edit', e.from, e.to, { oldRepo });
		else
			add('folder-edit-stale', e.from, `(${e.file} no longer holds the listed text)`, { oldRepo });
	}
	for (const e of Rules.RUNTIME_EDITS) {
		if (PREFIX + e.file !== file || !text.includes(e.from)) continue;
		const states = e.expect.map(([tree, oldName, newName]) =>
			runtimeEditState(byLuaName, presentNames, tree, oldName, newName)
		);
		// A step that leaves one of the edit's modules for a later step has
		// nothing to rewrite yet: the edit belongs to the step that moves the
		// last of them, and the whole-sequence map sees them all moved.
		if (!states.includes('wrong') && states.includes('pending')) continue;
		const wrong = e.expect.filter((_, i) => states[i] === 'wrong');
		const first = byLuaName.get(`${e.expect[0][0]}|${e.expect[0][1]}`);
		add(
			wrong.length ? 'lua-prefix-split' : 'lua-rewrite',
			e.from,
			wrong.length ? `(edit expects ${wrong.map((w) => w[1]).join(', ')})` : e.to,
			{
				oldRepo: first ? PREFIX + first[0] : null
			}
		);
	}
	// A Lua file outside the trees (a tool's fixture) loads the modules of the
	// drivers it names, shared ones first.
	const luaRoots = Census.DRIVERS.includes(inTree)
		? [inTree, '_shared']
		: inTree === '_shared'
			? ['_shared', 'macos', 'linux']
			: [
					'_shared',
					...['macos', 'linux'].filter((d) => file.includes(d) || text.includes(`/${d}`))
				];
	if (file.endsWith('.lua')) {
		// A quoted prefix completed by concatenation: "modules.llm." .. name.
		for (const m of text.matchAll(
			/(?:\brequire\s*\(?\s*|package\.loaded\s*\[\s*)["']((?:[A-Za-z_][A-Za-z0-9_]*\.)+)["']\s*\.\./g
		)) {
			if (Rules.RUNTIME_EDITS.some((e) => PREFIX + e.file === file && e.prefix === m[1])) continue;
			const site = Rules.RUNTIME_PREFIXES.find((r) => PREFIX + r.file === file && r.old === m[1]);
			const under = [...byLuaName.keys()].filter((k) => k.split('|')[1].startsWith(m[1]));
			if (under.length === 0) continue;
			if (!site) {
				add('lua-prefix-split', m[1], '(unlisted runtime prefix)');
				continue;
			}
			// Names with no module file are stubs of absent modules: they follow
			// the prefix and prove nothing either way.
			const found = site.names
				.map((n) => [
					n,
					[inTree, '_shared'].map((r) => byLuaName.get(`${r}|${m[1]}${n}`)).find(Boolean)
				])
				.filter(([, hit]) => hit);
			const news = found.map(([n, hit]) => [n, hit[2]]);
			const prefix = news.length
				? news[0][1].slice(0, news[0][1].length - news[0][0].length)
				: m[1];
			const ok = news.every(([n, full]) => full === prefix + n);
			const first = found.length ? found[0][1] : null;
			add(
				ok ? 'lua-prefix' : 'lua-prefix-split',
				m[1],
				ok ? prefix : `(names scatter: ${news.map((x) => x[1]).join(', ')})`,
				{
					oldRepo: first ? PREFIX + first[0] : null
				}
			);
		}
		const roots = luaRoots;
		// A name escaped for a Lua pattern: src:find('require%("test%.x"%)').
		for (const m of text.matchAll(/(?<![\w%.])([A-Za-z_]\w*(?:%\.[A-Za-z_]\w*)+)(?![\w])/g)) {
			const name = m[1].replace(/%\./g, '.');
			for (const r of roots) {
				const hit = byLuaName.get(`${r}|${name}`);
				if (hit && hit[2]) {
					add('lua-module-escaped', m[1], hit[2].replace(/\./g, '%.'), {
						oldRepo: PREFIX + hit[0]
					});
					break;
				}
			}
		}
		const lookup = (name) => {
			for (const r of roots) {
				const hit = byLuaName.get(`${r}|${name}`);
				if (hit) return hit;
			}
			return null;
		};
		// A load site quoted inside a string: 'params[require(\"config_keys\").KEY.X]',
		// or in a Lua pattern: 'require%(\"config_migrate\"%)%.boot%(' (an unescaped
		// dot of the new name still matches itself).
		for (const m of text.matchAll(
			/(\b(?:require\s*%?\(?|package\.(?:loaded|preload)\s*%?\[)\s*)\\(["'])([A-Za-z_][\w.]*)\\\2/g
		)) {
			const hit = lookup(m[3]);
			if (hit && hit[2])
				add('lua-module-quoted', m[0], `${m[1]}\\${m[2]}${hit[2]}\\${m[2]}`, {
					oldRepo: PREFIX + hit[0]
				});
		}
		// modules.json = {} where a require stand-in answers modules[name]: the
		// stand-in's table is keyed by module names, spelled as fields too.
		for (const table of standInTables(text)) {
			const field = new RegExp(`\\b${table}\\.([A-Za-z_]\\w*)(?=\\s*[,=])`, 'g');
			for (const m of text.matchAll(field)) {
				const hit = lookup(m[1]);
				if (hit && hit[2])
					add('lua-module-field', m[0], `${table}[${JSON.stringify(hit[2])}]`, {
						oldRepo: PREFIX + hit[0]
					});
			}
		}
		// package.loaded.logger: a module key spelled as a field.
		for (const m of text.matchAll(/\bpackage\.(loaded|preload)\.([A-Za-z_]\w*)(?!\w)/g)) {
			const hit = lookup(m[2]);
			if (hit && hit[2])
				add('lua-module-field', m[0], `package.${m[1]}[${JSON.stringify(hit[2])}]`, {
					oldRepo: PREFIX + hit[0]
				});
		}
		// A dotted module name inside a longer string: "infra.monotonic,keystats.x",
		// "require('keystats.x') loads". Strings only: in code, keystats.metrics
		// is a field of a local table that happens to share a module's name.
		for (const lit of text.matchAll(LUA_SHORT_STRING)) {
			if (/^[A-Za-z_][\w.]*$/.test(lit[2])) continue; // a whole name: luaToken below
			for (const m of lit[2].matchAll(INLINE_MODULE_NAME)) {
				const hit = configKeys().has(m[1]) ? null : lookup(m[1]);
				if (hit && hit[2]) add('lua-module-inline', m[1], hit[2], { oldRepo: PREFIX + hit[0] });
			}
		}
		// A table of module names ({ "keymap.terminators", "json", … }): every
		// entry is a module name the tree answers and one at least is dotted, so
		// its one-word entries are module names too. Rewritten as a whole.
		for (const t of text.matchAll(LUA_NAME_TABLE)) {
			const names = [...t[0].matchAll(/(["'])([A-Za-z_][\w.]*)\1/g)].map((x) => x[2]);
			// Names of an earlier step are already new: both spellings count.
			const known = (n) =>
				roots.some((r) => presentNames.has(`${r}|${n}`) || targetNames.has(`${r}|${n}`));
			// Or a table handed to a module helper (with_fresh_modules({ … })), or
			// iterated to load or purge each name (for _, n in ipairs({ … }) do
			// package.loaded[n] = nil).
			const lead = text.slice(Math.max(0, t.index - 60), t.index);
			const after = text.slice(t.index + t[0].length, t.index + t[0].length + 200);
			const helper = /\b\w*modules?\w*\s*\(\s*$/i.test(lead);
			// The loop variable itself is what is loaded or purged, not a piece of
			// a name it builds ("modules." .. name is a runtime site).
			const loopVar = (lead.match(/\bfor\s+\w+\s*,\s*(\w+)\s+in\s+i?pairs\s*\(\s*$/) || [])[1];
			const loop =
				!!loopVar &&
				new RegExp(
					`(?:package\\.(?:loaded|preload)\\s*\\[|\\brequire\\s*\\(|\\brawget\\s*\\(\\s*package\\.loaded\\s*,)\\s*${loopVar}\\s*[\\])]`
				).test(after);
			if (
				names.length < (helper || loop ? 1 : 2) ||
				!(helper || loop || names.some((n) => n.includes('.') && known(n) && !configKeys().has(n)))
			)
				continue;
			const words = names.filter((n) => !n.includes('.') && lookup(n) && lookup(n)[2]);
			if (words.length === 0) continue;
			// Inside a list of module names, a name that is also a config key
			// ("llm.app_profile_overrides") is the module.
			const next = t[0].replace(/(["'])([A-Za-z_][\w.]*)\1/g, (whole, q, n) => {
				const hit = lookup(n);
				return hit && hit[2] ? `${q}${hit[2]}${q}` : whole;
			});
			add('lua-module-list', t[0], next, { oldRepo: PREFIX + lookup(words[0])[0] });
		}
		for (const m of text.matchAll(luaToken)) {
			// A one-word string ("json", "chord", "logger") is a module name
			// only where it is loaded: elsewhere it is a file type, a slot kind
			// or a settings section that happens to share the name.
			// A config key that spells a module name ("llm.app_profile_overrides")
			// is a key everywhere but at a load site, like a one-word name.
			const loadOnly = !m[1].includes('.') || configKeys().has(m[1]);
			if (loadOnly && !isModuleLoadSite(text, m.index)) continue;
			for (const r of roots) {
				const hit = byLuaName.get(`${r}|${m[1]}`);
				if (hit) {
					add('lua-module', m[1], hit[2] || '(retired)', {
						oldRepo: PREFIX + hit[0],
						loadOnly
					});
					break;
				}
			}
		}
	} else if (/\.(c?js|mjs|py|sh|ya?ml|nix)$/.test(file)) {
		// Lua run from another language (luajit -e, a stdin chunk, a fixture
		// written to disk): its require sites, and only those, move. The driver
		// is the one the file names; a name both Lua drivers answer differently
		// is left alone rather than guessed.
		const drivers = ['macos', 'linux'].filter((d) => file.includes(d) || text.includes(`/${d}`));
		for (const m of text.matchAll(luaToken)) {
			// A dotted name a tool checks a source for (src.includes('keystats.x'))
			// is a module name too, unless it is a config or locale key.
			// Only as the argument of a source check: a registry key or a menu id
			// elsewhere in a tool may share a module's spelling ('updater.channels').
			const dotted =
				m[1].includes('.') &&
				/\.(c?js|mjs|py)$/.test(file) &&
				/\.(?:includes|indexOf|lastIndexOf|startsWith|endsWith|find|count)\(\s*$/.test(
					text.slice(Math.max(0, m.index - 40), m.index)
				) &&
				!configKeys().has(m[1]) &&
				!localeKeys().has(m[1]);
			// A tool listed in edits.cjs MODULE_NAME_FILES names Lua modules in
			// its own tables (new Set(['menu.personal_files', …])): every quoted
			// name of a moved module there is one.
			// Only the tool's own JavaScript values: a property, an element or a
			// comparison operand in single quotes.
			const listed = isListedModuleSite(file, text, m.index);
			// The log tag of an embedded Lua chunk (Logger.error("x.y", …)) is
			// the module's name, as in the Lua it mirrors, where it follows.
			const tag = m[1].includes('.') && isLuaLogTagSite(text, m.index);
			if (
				(!dotted && !listed && !tag && !isModuleLoadSite(text, m.index)) ||
				NODE_MODULES.has(m[1])
			)
				continue;
			const shared = byLuaName.get(`_shared|${m[1]}`);
			const own = drivers.map((d) => byLuaName.get(`${d}|${m[1]}`)).filter(Boolean);
			const targets = new Set(own.map((h) => h[2]));
			const hit = shared || (targets.size === 1 ? own[0] : null);
			if (hit && hit[2])
				add('lua-module', m[1], hit[2], {
					oldRepo: PREFIX + hit[0],
					loadOnly: !dotted && !listed && !tag,
					listed: listed && !dotted
				});
		}
		// 'text_utils").trim': the tail of a require call the file spells in
		// full elsewhere (require("text_utils").trim(text)), checked in a message.
		for (const m of text.matchAll(/(['`])([A-Za-z_][\w.]*)"\)\.([A-Za-z_]\w*)\1/g)) {
			if (!text.includes(`require("${m[2]}")`)) continue;
			const shared = byLuaName.get(`_shared|${m[2]}`);
			const own = drivers.map((d) => byLuaName.get(`${d}|${m[2]}`)).filter(Boolean);
			const hit = shared || (new Set(own.map((h) => h[2])).size === 1 ? own[0] : null);
			if (hit && hit[2])
				add('lua-module-quoted', m[0], `${m[1]}${hit[2]}").${m[3]}${m[1]}`, {
					oldRepo: PREFIX + hit[0]
				});
		}
		// case "$*" in *"\'keycodes.evdev\'"*): a dotted module name in escaped
		// quotes, inside a stand-in for the runtime that requires it, where the
		// file checks that require in another spelling.
		for (const m of text.matchAll(/\\(['"])([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+)\\\1/g)) {
			const escaped = m[2].replace(/\./g, '\\.');
			if (
				!new RegExp(
					`require[\\s\\S]{0,12}['"](?:${m[2]}|${escaped.replace(/\\/g, '\\\\')})['"]`
				).test(text)
			)
				continue;
			const hit = byLuaName.get(`_shared|${m[2]}`);
			if (hit && hit[2])
				add('lua-module-quoted', m[0], `\\${m[1]}${hit[2]}\\${m[1]}`, { oldRepo: PREFIX + hit[0] });
		}
		// 'string:layout.number_row_policy': the same module as a token of the
		// require call a tool matches token by token.
		for (const m of text.matchAll(/(['`])string:([A-Za-z_][\w.]*)\1/g)) {
			if (!text.includes(`require("${m[2]}")`)) continue;
			const shared = byLuaName.get(`_shared|${m[2]}`);
			const own = drivers.map((d) => byLuaName.get(`${d}|${m[2]}`)).filter(Boolean);
			const hit = shared || (new Set(own.map((h) => h[2])).size === 1 ? own[0] : null);
			if (hit && hit[2])
				add('lua-module-quoted', m[0], `${m[1]}string:${hit[2]}${m[1]}`, {
					oldRepo: PREFIX + hit[0]
				});
		}
		// package.loaded.json in an embedded Lua chunk: the module key spelled
		// as a field, as in a Lua file.
		for (const m of text.matchAll(/\bpackage\.(loaded|preload)\.([A-Za-z_]\w*)(?!\w)/g)) {
			const shared = byLuaName.get(`_shared|${m[2]}`);
			const own = drivers.map((d) => byLuaName.get(`${d}|${m[2]}`)).filter(Boolean);
			const hit = shared || (new Set(own.map((h) => h[2])).size === 1 ? own[0] : null);
			if (hit && hit[2])
				add('lua-module-field', m[0], `package.${m[1]}[${JSON.stringify(hit[2])}]`, {
					oldRepo: PREFIX + hit[0]
				});
		}
	}
	// require [[layouts.registry]]: the long-bracket spelling of a load site.
	for (const m of text.matchAll(/\brequire\s*\[(=*)\[([A-Za-z_][\w.]*)\]\1\]/g)) {
		const shared = byLuaName.get(`_shared|${m[2]}`);
		const own = Census.DRIVERS.map((d) => byLuaName.get(`${d}|${m[2]}`)).filter(Boolean);
		const hit = shared || (new Set(own.map((h) => h[2])).size === 1 ? own[0] : null);
		if (hit && hit[2])
			add('lua-module-quoted', m[0], m[0].replace(`[${m[1]}[${m[2]}]`, `[${m[1]}[${hit[2]}]`), {
				oldRepo: PREFIX + hit[0]
			});
	}
	// A tool listed in edits.cjs MODULE_MEMBER_FILES names a shared module's
	// method by the record name the menu delegation builds from the module
	// ('menu.personal_files.build'): its module part follows the module.
	if (Edits.MODULE_MEMBER_FILES.some((e) => e.file === file))
		for (const m of text.matchAll(/'([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+)\.([A-Za-z_]\w*)'/g)) {
			const hit = byLuaName.get(`_shared|${m[1]}`);
			if (hit && hit[2])
				add('lua-module-member', m[0], `'${hit[2]}.${m[2]}'`, { oldRepo: PREFIX + hit[0] });
		}
	// A file whose path literals are synthetic coordinates (edits.cjs
	// SYNTHETIC_PATHS) keeps them: only its module names, its own header and
	// the shared root follow the plan.
	if (Edits.SYNTHETIC_PATHS.some((e) => e.file === file))
		return rows.filter(
			(r) =>
				r.kind.startsWith('lua-module') ||
				r.kind === 'shared-root' ||
				(r.resolution && r.resolution.oldRepo === file)
		);
	return rows;
}

/**
 * The new homes of a folder the step scatters: the folder itself while it
 * keeps a file, then each new folder of a file it loses, outermost only.
 * @param {string} folderRepo Repository path of the folder.
 * @param {Map<string, string|null>} map Tree-relative old path to target.
 * @returns {string[]} Tree-relative folders.
 */
function splitHomes(folderRepo, map) {
	const rel = folderRepo.slice(PREFIX.length);
	const homes = [];
	for (const [old, target] of map) {
		if (!old.startsWith(`${rel}/`) || !target) continue;
		const home = target === old ? rel : path.posix.dirname(target);
		if (!homes.includes(home)) homes.push(home);
	}
	homes.sort((a, b) => (a === rel ? -1 : b === rel ? 1 : a < b ? -1 : a > b ? 1 : 0));
	return homes.filter((h) => !homes.some((o) => o !== h && h.startsWith(`${o}/`)));
}

/**
 * A list element on its own line naming a scattered folder, respelled as one
 * element per new home of the folder (splitHomes), in the element's own form.
 * @returns {{old: string, new: string}|null} The line and its expansion.
 */
function splitScopeLine(text, index, raw, folderRepo, map) {
	const line = lineAt(text, index);
	const rel = folderRepo.slice(PREFIX.length);
	if (line.split(raw).length !== 2 || !raw.replace(/\\/g, '/').endsWith(rel)) return null;
	const start = text.lastIndexOf('\n', index - 1) + 1;
	const before = text.slice(0, start).trimEnd();
	const after = text.slice(start + line.length).trimStart();
	const element = /[[,]$/.test(before) && (/,\s*$/.test(line) || after.startsWith(']'));
	if (!element) return null;
	const homes = splitHomes(folderRepo, map);
	if (homes.length === 0) return null;
	const stem = raw.slice(0, raw.length - rel.length);
	const lines = homes.map((h, i) => {
		const respelled = line.replace(raw, stem + h);
		// Every element but the last of a line without a comma needs one.
		return i < homes.length - 1 && !/,\s*$/.test(respelled) ? `${respelled},` : respelled;
	});
	return { old: line, new: lines.join('\n') };
}

/** The whole line of `text` that holds offset `index`. */
function lineAt(text, index) {
	const start = text.lastIndexOf('\n', index - 1) + 1;
	const end = text.indexOf('\n', index);
	return text.slice(start, end < 0 ? text.length : end);
}

/** The new place of a repository folder: itself, its target, or a split folder's successor. */
function newFolder(dir, byRepoDir, successors) {
	const hit = byRepoDir.get(dir);
	if (!hit) return dir;
	return hit === SPLIT ? successors.get(dir) || null : hit;
}

/**
 * A join onto a constant the file defines: the pieces are respelled from the
 * new place of that base, so `path.join(DATA, 'locale_order.json')` follows
 * both the file and `DATA = path.join(SHARED, 'data')`.
 */
function resolveOnBase(j, base, joined, byRepoPath, byRepoDir, successors) {
	const full = path.posix.normalize(base ? `${base}/${joined}` : joined);
	const newBase = newFolder(base, byRepoDir, successors);
	let newFull = null;
	if (EXISTING.has(full)) newFull = byRepoPath.get(full) || newFolder(full, byRepoDir, successors);
	else {
		// A fixture or a generated file in a folder that moves whole follows it.
		// Up to the base, and never past the top: dirname('.') is '.', and a
		// join that climbs out of the repository has no folder to follow.
		for (
			let d = path.posix.dirname(full);
			d.length > base.length && d !== '.' && d !== '/';
			d = path.posix.dirname(d)
		) {
			if (!EXISTING.has(d)) continue;
			const to = byRepoDir.get(d);
			if (to && to !== SPLIT) newFull = to + full.slice(d.length);
			break;
		}
		if (!newFull) return null;
	}
	if (newFull === full && newBase === base) return null;
	if (newBase === null || newFull === null || newFull === PREFIX)
		return { kind: 'join-split', rendered: '(split)', oldRepo: full, newRepo: null };
	// Relative to the base's new place, climbing out of it when the original
	// climbed too (path.join(WIN, '..', '_shared', …)).
	const rel = path.posix.relative(newBase || '.', newFull) || '.';
	const pieces = j.parts.length === 1 ? [rel] : rel.split('/');
	const rendered = pieces.map((p) => `${j.quote}${p}${j.quote}`).join(j.separator || ', ');
	if (rendered === j.text) return null;
	return { kind: 'join', rendered, oldRepo: full, newRepo: newFull };
}

/**
 * The folder constants a Lua file defines, evaluated to repository paths:
 * `local root = helpers.driver_root() .. "/../_shared/data/"`. A later
 * `root .. "locale_order.json"` is then respelled from the new place of root.
 * @returns {Map<string, string>}
 */
function luaConstants(text, file, inTree) {
	const env = new Map();
	if (!file.endsWith('.lua')) return env;
	const driverRoot = Census.DRIVERS.includes(inTree) ? `${PREFIX}${inTree}` : null;
	const term = (t) => {
		if (/^(?:[\w.]+\.)?driver_root\(\)$/.test(t)) return driverRoot;
		if (/^(?:[\w.]+\.)?shared_root\(\)$/.test(t)) return `${PREFIX}_shared`;
		const lit = t.match(/^(["'])([^"'\n]*)\1$/);
		if (lit) return { piece: lit[2] };
		return env.has(t) ? env.get(t) : undefined;
	};
	for (const m of text.matchAll(/^[ \t]*local\s+([A-Za-z_]\w*)\s*=\s*(.+?)\s*$/gm)) {
		// Split at the concatenations outside string literals ("/../" is a path).
		const terms = [...m[2].matchAll(/(["'])(?:(?!\1)[^\n])*\1|[^.'"]+(?:\.(?!\.)[^.'"]*)*/g)]
			.map((t) => t[0].trim())
			.filter(Boolean);
		let acc = null;
		let ok = terms.length > 1 || /^[\w.]+$/.test(terms[0]);
		for (const t of terms) {
			const v = term(t);
			if (v === undefined || v === null) {
				ok = false;
				break;
			}
			if (typeof v === 'string') {
				if (acc !== null) {
					ok = false;
					break;
				}
				acc = v;
			} else if (acc === null) {
				ok = false;
				break;
			} else acc += v.piece;
		}
		if (!ok || acc === null) continue;
		const norm = path.posix.normalize(acc).replace(/\/$/, '');
		if (norm.startsWith(PREFIX) && EXISTING.has(norm)) env.set(m[1], norm);
	}
	return env;
}

/**
 * The path constants a JavaScript file defines, evaluated to repository
 * paths ('' is the repository root): `ROOT = path.resolve(__dirname, '..', '..')`,
 * `SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared')`,
 * `DATA = path.join(SHARED, 'data')`, `` X = `${SHARED}/data` ``.
 * @returns {Map<string, string>}
 */
function jsConstants(text, file) {
	const env = new Map();
	const dir = path.posix.dirname(file);
	// path.join(__dirname, '..', '..', 'static', …): the file's own folder.
	env.set('__dirname', dir);
	const norm = (p) => {
		const n = path.posix.normalize(p);
		if (n === '.') return '';
		return n.startsWith('..') ? null : n.replace(/\/$/, '');
	};
	const argValue = (a) => {
		if (a === '__dirname') return dir;
		const lit = a.match(/^(['"])([^'"]*)\1$/);
		if (lit) return { piece: lit[2] };
		if (env.has(a)) return env.get(a);
		return undefined;
	};
	// const { resolve } = require('path'): the bare name is path.resolve.
	const imported = (text.match(
		/\bconst\s*\{([^}]*)\}\s*=\s*require\(\s*['"](?:node:)?path['"]\s*\)/
	) || [])[1];
	const bare = new Set(
		(imported || '')
			.split(',')
			.map((x) => x.trim())
			.filter((x) => x === 'join' || x === 'resolve')
	);
	const evaluate = (expr) => {
		const named = expr.match(/^(join|resolve)\(/);
		const call =
			named && !bare.has(named[1]) ? null : expr.match(/^(?:path\.)?(join|resolve)\(([^()]*)\)$/);
		if (call) {
			let acc = null;
			for (const raw of call[2]
				.split(',')
				.map((x) => x.trim())
				.filter(Boolean)) {
				const v = argValue(raw);
				if (v === undefined) return null;
				if (typeof v === 'string') acc = v;
				else if (acc === null) return null;
				else acc = acc ? `${acc}/${v.piece}` : v.piece;
			}
			return acc === null ? null : norm(acc || '.');
		}
		// shared('tests', 'corpus', 'x'): the tools' resolver of _shared paths.
		const sharedCall = expr.match(/^[\w$.]*\bshared\(([^()]*)\)$/);
		if (sharedCall) {
			const pieces = sharedCall[1]
				.split(',')
				.map((x) => x.trim())
				.filter(Boolean)
				.map((x) => (x.match(/^(['"])([^'"]*)\1$/) || [])[2]);
			if (pieces.every((x) => x !== undefined))
				return norm([`${PREFIX}_shared`, ...pieces].join('/'));
		}
		// path.dirname(X): the folder holding a known path.
		const dirnameCall = expr.match(/^path\.dirname\(\s*([A-Za-z_$][\w$]*)\s*\)$/);
		if (dirnameCall && env.has(dirnameCall[1]))
			return norm(path.posix.dirname(env.get(dirnameCall[1]) || '.'));
		const tpl = expr.match(/^`\$\{([A-Za-z_$][\w$]*)\}\/([^`$]*)`$/);
		if (tpl && env.has(tpl[1])) return norm(`${env.get(tpl[1]) || '.'}/${tpl[2]}`);
		const lit = expr.match(/^(['"])((?:static\/ergopti_plus|tools|docs)(?:\/[^'"]*)?)\1$/);
		if (lit) return norm(lit[2]);
		return null;
	};
	const constants = () => {
		for (const m of text.matchAll(
			/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*([^;\n]+?)\s*;?\s*$/gm
		)) {
			const v = evaluate(m[2].trim());
			if (v !== null && v !== undefined && !env.has(m[1])) env.set(m[1], v);
		}
	};
	constants();
	// function main(root = ROOT): a parameter that defaults to a known
	// constant holds it, and the constants derived from it inside follow.
	for (const m of text.matchAll(/\bfunction\s*[\w$]*\s*\(([^)]*)\)/g))
		for (const p of m[1].matchAll(/([A-Za-z_$][\w$]*)\s*=\s*([A-Za-z_$][\w$]*)/g))
			if (env.has(p[2]) && !env.has(p[1])) env.set(p[1], env.get(p[2]));
	constants();
	return env;
}

/**
 * The test data whose exact bytes another file pins by SHA-256 (a corpus
 * captured from a legacy reader): a rewrite would break the pin, and the old
 * paths it holds are history like an audit's.
 * @returns {Set<string>} Repository paths.
 */
function pinnedBytes() {
	const crypto = require('node:crypto');
	const pins = new Set();
	const hashes = new Map();
	for (const file of textFiles()) {
		let bytes;
		try {
			bytes = fs.readFileSync(path.join(ROOT, file));
		} catch {
			continue;
		}
		if (bytes.length > TEXT_LIMIT_BYTES) continue;
		hashes.set(file, crypto.createHash('sha256').update(bytes).digest('hex'));
		for (const m of bytes.toString('utf8').matchAll(/\b[0-9a-f]{64}\b/g)) pins.add(m[0]);
	}
	// Captured corpora only: a source or a test support file tracked by a digest
	// manifest moves and is rewritten like any other, and its manifest follows.
	return new Set(
		[...hashes].filter(([f, h]) => pins.has(h) && /(^|\/)tests\/corpus\//.test(f)).map(([f]) => f)
	);
}

/**
 * Finds the references to moved files.
 * @param {Map<string, string|null>} map Tree-relative old path to target.
 * @returns {object[]} One row per (file, old token).
 */
function references(map) {
	const ctx = referenceContext(map);
	const rows = [];
	const pinned = pinnedBytes();
	for (const file of textFiles()) {
		if (pinned.has(file)) continue;
		const abs = path.join(ROOT, file);
		let stat;
		try {
			stat = fs.statSync(abs);
		} catch {
			continue;
		}
		if (stat.size > TEXT_LIMIT_BYTES) continue;
		const text = fs.readFileSync(abs, 'utf8');
		rows.push(...scanFile(file, text, ctx));
	}
	return rows;
}

/**
 * Lua module names that a driver and _shared/lua would both answer once the
 * paths in `paths` exist. Both roots are on package.path, so the first one
 * wins silently; today these are driver shims re-exporting a shared module
 * under its own name, which the mirror makes identical.
 * @param {string[]} paths Tree-relative paths.
 * @returns {{driver: string, name: string, file: string}[]}
 */
function luaCollisions(paths, target = true) {
	const lib = (p) => !/\/tests?\//.test(`/${p}`);
	const shared = new Set(
		paths
			.filter((p) => p.startsWith(target ? '_shared/' : '_shared/lua/') && lib(p.slice(8)))
			.map((p) => luaModuleName(p, target))
			.filter(Boolean)
	);
	const out = [];
	for (const d of ['macos', 'linux']) {
		for (const p of paths) {
			if (!p.startsWith(`${d}/`) || !lib(p.slice(d.length + 1))) continue;
			const name = luaModuleName(p);
			if (name && shared.has(name)) out.push({ driver: d, name, file: p });
		}
	}
	return out.sort((a, b) => a.file.localeCompare(b.file));
}

/**
 * The step that must rewrite each reference: the one that moves the file it
 * names, or, for a folder, the last step that moves a file out of it (until
 * then the old folder still holds files). Mutates `row.step`.
 * @param {object[]} plan The ordered steps.
 * @param {object[]} refs The rows of references().
 */
function attributeSteps(plan, refs) {
	const stepOfFile = new Map();
	plan.forEach((s, index) => {
		for (const [o] of s.moves) stepOfFile.set(PREFIX + o, { id: s.id, index });
	});
	const lastUnder = new Map();
	for (const [file, step] of stepOfFile) {
		const parts = file.split('/');
		for (let i = 3; i < parts.length; i++) {
			const dir = parts.slice(0, i).join('/');
			const prev = lastUnder.get(dir);
			if (!prev || prev.index < step.index) lastUnder.set(dir, step);
		}
	}
	for (const r of refs) {
		const old = r.resolution && r.resolution.oldRepo;
		const hit = old ? stepOfFile.get(old) || lastUnder.get(old) : null;
		r.step = hit ? hit.id : 'unknown';
	}
	return refs;
}

/** The kinds a step cannot apply mechanically: phase 2 refuses them. */
const REFUSED_KINDS = new Set(['dir-split', 'lua-prefix-split', 'join-split', 'folder-edit-stale']);
/** The kinds the step applies but a reviewer reads. */
const REVIEWED_KINDS = new Set([
	'dir-kept',
	'dir-successor',
	'dir-split-prose',
	'join-successor',
	'scope-split'
]);

// ──────────────────────────────────────────────────────────────────────────────
// Gates
// ──────────────────────────────────────────────────────────────────────────────

// Every step runs the base gates; a step that rewrites a reference of a
// category also runs that category's gates. The ids are defined in
// docs/design/structure-plan.md, section "Gates".
const BASE_GATES = ['G-lint', 'G-tree', 'G-bounds', 'G-js'];

const CATEGORY_GATES = {
	'lua-require': ['G-macos', 'G-linux'],
	'driver-test': ['G-macos', 'G-linux', 'G-windows'],
	'ahk-include': ['G-windows', 'G-ahk-encoding'],
	'packaging-manifest': ['G-packaging'],
	build: ['G-packaging'],
	'ci-workflow': ['G-ci'],
	'repo-test': ['G-js'],
	tooling: ['G-js'],
	docs: ['G-docs'],
	other: ['G-review']
};

// ──────────────────────────────────────────────────────────────────────────────
// Reports
// ──────────────────────────────────────────────────────────────────────────────

function sideBySide(files, maxDepth) {
	const table = Census.folderTable(files);
	const rows = new Map();
	for (const [folder, entries] of table) {
		const [tree, ...rest] = folder.split('/');
		if (!Census.DRIVERS.includes(tree) || rest.length === 0 || rest.length > maxDepth) continue;
		const rel = rest.join('/');
		if (/^tests(\/|$)/.test(rel) || Census.exemptionOf(rel) || Census.exemptionOf(folder)) continue;
		if (!rows.has(rel)) rows.set(rel, {});
		rows.get(rel)[tree] = entries.size;
	}
	const mark = (n) =>
		n === undefined
			? '—'
			: n < Census.MIN_ENTRIES || n > Census.MAX_ENTRIES
				? `**${n}**`
				: String(n);
	const lines = ['| folder | windows | macos | linux |', '| --- | --: | --: | --: |'];
	for (const rel of [...rows.keys()].sort()) {
		const r = rows.get(rel);
		lines.push(`| \`${rel}\` | ${mark(r.windows)} | ${mark(r.macos)} | ${mark(r.linux)} |`);
	}
	return lines.join('\n');
}

function violationList(census, tests) {
	const lines = [];
	for (const f of census.folders.filter((x) => x.violation && x.tests === tests)) {
		lines.push(`- ${f.violation} (${f.entries}) \`${f.tree}/${f.folder}\``);
	}
	return lines.length ? lines.join('\n') : '- none';
}

/**
 * Lists the mismatched folders with the reason each one is, or is not, a
 * legitimate asymmetry.
 * @param {object} census A census of the tree.
 * @param {Set<string>} sharedLua The folders of _shared/lua, relative to it.
 */
function mismatchList(census, sharedLua) {
	const declared = (m) =>
		m.on.length === 1 &&
		Rules.OS_SPECIFIC[m.on[0]] &&
		Object.keys(Rules.OS_SPECIFIC[m.on[0]]).some(
			(k) => m.folder === k || m.folder.startsWith(`${k}/`)
		);
	return census.mismatches
		.map((m) => {
			let note = '';
			if (declared(m)) note = ' — declared OS-specific';
			else if (sharedLua.has(m.folder))
				note = ' — the Lua drivers share it from `_shared/lua/' + m.folder + '/`';
			else
				note =
					' — code exists on these drivers only; the counterpart gains the folder with its first file';
			return `- \`${m.folder}\` on ${m.on.join(' + ')}${note}`;
		})
		.join('\n');
}

function sharedLuaFolders(files) {
	const out = new Set();
	for (const folder of Census.folderTable(files).keys()) {
		const key = Census.counterpartKey('_shared', folder.slice('_shared/'.length));
		if (folder.startsWith('_shared/') && key) out.add(key);
	}
	return out;
}

function header(title, source) {
	return `<!-- ${source} -->\n\n# ${title}\n\nGENERATED by \`node tools/audit/structure/plan.cjs --write\` from the Git index; do not edit.\n`;
}

/** Formats one repository file in place with the repository's Prettier. */
function prettier(rel) {
	const bin = path.join(
		ROOT,
		'node_modules',
		'.bin',
		process.platform === 'win32' ? 'prettier.cmd' : 'prettier'
	);
	if (!fs.existsSync(bin)) throw new Error('Prettier is not installed: run npm ci before --write');
	require('node:child_process').execFileSync(bin, ['--write', '--log-level', 'warn', rel], {
		cwd: ROOT,
		stdio: 'inherit'
	});
}

function write(rel, text) {
	const abs = path.join(ROOT, rel);
	fs.mkdirSync(path.dirname(abs), { recursive: true });
	fs.writeFileSync(abs, text.endsWith('\n') ? text : text + '\n', 'utf8');
	// The repository formats Markdown with Prettier; the appendix is written
	// in that form so the format gate holds it like any other document.
	if (rel.endsWith('.md')) prettier(rel);
	console.log(`wrote ${rel}`);
}

/** The rows of the move map, optionally with the files that stay. */
function moveMapRows(files, map, plan, all) {
	const rows = ['old\tnew\tstep'];
	const stepOf = new Map();
	for (const s of plan) for (const [o] of s.moves) stepOf.set(o, s.id);
	for (const f of [...files].sort()) {
		const t = map.get(f);
		if (t === f && !all) continue;
		rows.push(
			`${PREFIX}${f}\t${t === f ? '=' : t === null ? '(retired)' : PREFIX + t}\t${stepOf.get(f) || '-'}`
		);
	}
	return rows;
}

function main() {
	const { files, map } = moveMap();
	if (process.argv.includes('--map-all')) {
		process.stdout.write(moveMapRows(files, map, steps(map), true).join('\n') + '\n');
		return;
	}
	const before = Census.measure(files);
	const after = Census.measure([...map.values()].filter(Boolean));
	const plan = steps(map);
	const movedCount = plan.reduce((n, s) => n + s.moves.length, 0);
	const retired = [...map].filter(([, t]) => t === null).map(([o]) => o);
	console.log(
		`files: ${files.length}; moved: ${movedCount}; retired: ${retired.length}; steps: ${plan.length}`
	);
	for (const [label, c] of [
		['now', before],
		['target', after]
	]) {
		const s = Object.values(c.summary);
		const sum = (k) => s.reduce((n, x) => n + x[k], 0);
		console.log(
			`${label}: code ${sum('code_oversized')} oversized, ${sum('code_singleton')} singleton; tests ` +
				`${sum('tests_oversized')} oversized, ${sum('tests_singleton')} singleton; ` +
				`${c.mismatches.length} mismatched architecture folders`
		);
	}
	if (!process.argv.includes('--write')) return;

	const refs = attributeSteps(plan, references(map));
	const renamedCount = plan.reduce(
		(n, s) =>
			n + s.moves.filter(([o, t]) => t && path.posix.basename(o) !== path.posix.basename(t)).length,
		0
	);
	const reviewed = refs.filter((r) => REVIEWED_KINDS.has(r.kind)).length;
	const refused = refs.filter((r) => REFUSED_KINDS.has(r.kind)).length;
	const refsByStep = new Map();
	for (const r of refs) {
		if (!refsByStep.has(r.step)) refsByStep.set(r.step, []);
		refsByStep.get(r.step).push(r);
	}

	write(
		`${OUT_DIR}/current-trees.md`,
		[
			header('Current driver trees (structure plan, appendix 1)', `${OUT_DIR}/current-trees.md`),
			`Bounds: ${Census.MIN_ENTRIES} to ${Census.MAX_ENTRIES} direct entries per folder. Bold counts are outside them; — means the folder does not exist on that driver. Architecture folders only (tests and exempt folders are listed below).\n`,
			sideBySide(files, 3),
			'\n## Folders outside the bounds (code)\n',
			violationList(before, false),
			'\n## Folders outside the bounds (tests)\n',
			violationList(before, true),
			'\n## Architecture folders on one or two drivers only\n',
			mismatchList(before, sharedLuaFolders(files))
		].join('\n')
	);
	write(
		`${OUT_DIR}/target-tree.md`,
		[
			header('Target driver trees (structure plan, appendix 2)', `${OUT_DIR}/target-tree.md`),
			'The same rules (tools/audit/structure/rules.cjs) applied to the three drivers. Bold counts are outside the bounds.\n',
			sideBySide([...map.values()].filter(Boolean), 3),
			'\n## Residual folders outside the bounds (code)\n',
			violationList(after, false),
			'\n## Residual folders outside the bounds (tests)\n',
			violationList(after, true),
			'\n## Architecture folders on one or two drivers only, after the moves\n',
			mismatchList(after, sharedLuaFolders([...map.values()].filter(Boolean))),
			'\n## Lua module names both roots would answer\n',
			'Both the driver root and `_shared/lua` are on `package.path`, so the first wins silently. Each of these is a driver shim that re-exports the shared module under the same name; the step that creates the collision retires the shim (callers already use that name) or renames it, and apply-step.cjs refuses until it does.\n',
			luaCollisions([...map.values()].filter(Boolean))
				.map((c) => `- \`${c.name}\` — \`${c.file}\``)
				.join('\n')
		].join('\n')
	);
	// Moved and retired files only: every other tracked file stays where it
	// is, and `--map-all` prints the full list with `=` for those.
	write(`${OUT_DIR}/move-map.tsv`, moveMapRows(files, map, plan, false).join('\n'));
	// One row per rewritten token: the files that carry it are counted per
	// category rather than listed, which apply-step.cjs recomputes anyway.
	const tokens = new Map();
	for (const r of refs) {
		const key = [r.step, r.kind, r.old, r.new].join('\t');
		if (!tokens.has(key)) tokens.set(key, {});
		const cats = tokens.get(key);
		cats[r.category] = (cats[r.category] || 0) + 1;
	}
	const rtsv = ['step\tkind\told\tnew\tfiles\tby_category'];
	for (const key of [...tokens.keys()].sort()) {
		const cats = tokens.get(key);
		const total = Object.values(cats).reduce((n, v) => n + v, 0);
		const by = Object.entries(cats)
			.sort((x, y) => y[1] - x[1])
			.map(([k, v]) => `${k}:${v}`)
			.join(',');
		rtsv.push(`${key}\t${total}\t${by}`);
	}
	write(`${OUT_DIR}/rewrites.tsv`, rtsv.join('\n'));

	// The files outside the driver code that name moved paths: the ones a
	// move breaks without any Lua or AHK error to say so.
	const outside = ['ci-workflow', 'packaging-manifest', 'build', 'tooling', 'repo-test', 'other'];
	const byFile = new Map();
	for (const r of refs) {
		if (!outside.includes(r.category)) continue;
		const key = `${r.category}\t${r.file}`;
		if (!byFile.has(key)) byFile.set(key, new Set());
		byFile.get(key).add(r.step);
	}
	const fileLines = [
		header(
			'Files outside the drivers that name moved paths (structure plan, appendix 4)',
			`${OUT_DIR}/referencing-files.md`
		),
		'Workflows, packaging manifests, build scripts, tools and repository tests that spell a path the plan moves. A move that misses one of these fails at packaging or CI time, not at load time.\n'
	];
	for (const cat of outside) {
		const rows = [...byFile].filter(([k]) => k.startsWith(`${cat}\t`)).sort();
		if (rows.length === 0) continue;
		fileLines.push(`\n## ${cat} (${rows.length} file${rows.length === 1 ? '' : 's'})\n`);
		for (const [k, set] of rows)
			fileLines.push(`- \`${k.split('\t')[1]}\` — ${[...set].sort().join(', ')}`);
	}
	write(`${OUT_DIR}/referencing-files.md`, fileLines.join('\n'));

	const lines = [
		header('Ordered steps (structure plan, appendix 3)', `${OUT_DIR}/steps.md`),
		`${plan.length} steps, ${movedCount} moved files (${renamedCount} of them renamed), ${retired.length} retired files, ${refs.length} reference rewrites (${reviewed} to read in review, ${refused} refused). Each step moves one feature on every tree at once and is applied by \`node tools/audit/structure/apply-step.cjs <feature>\`.\n`,
		'| step | feature | moves | renames | rewrites | review | rewrite categories | gates beyond the base set |',
		'| --- | --- | --: | --: | --: | --: | --- | --- |'
	];
	for (const s of plan) {
		const own = refsByStep.get(s.id) || [];
		const cats = {};
		for (const r of own) cats[r.category] = (cats[r.category] || 0) + 1;
		const catText = Object.entries(cats)
			.sort((a, b) => b[1] - a[1])
			.map(([k, v]) => `${k} ${v}`)
			.join(', ');
		const gates = [...new Set(Object.keys(cats).flatMap((k) => CATEGORY_GATES[k] || []))]
			.sort()
			.join(', ');
		const renames = s.moves.filter(
			([o, t]) => t && path.posix.basename(o) !== path.posix.basename(t)
		).length;
		const review = own.filter(
			(r) => REVIEWED_KINDS.has(r.kind) || REFUSED_KINDS.has(r.kind)
		).length;
		lines.push(
			`| ${s.id} | \`${s.key}\` | ${s.moves.length} | ${renames} | ${own.length} | ${review} | ${catText || '—'} | ${gates || '—'} |`
		);
	}
	lines.push(
		'',
		`Base gates of every step: ${BASE_GATES.join(', ')} (defined in docs/design/structure-plan.md).`
	);
	lines.push('', '## Retired files', '', ...retired.map((r) => `- \`${PREFIX}${r}\``));
	write(`${OUT_DIR}/steps.md`, lines.join('\n'));
}

if (require.main === module) main();

module.exports = {
	SPLIT,
	neverRewritten,
	foreignBaseBefore,
	isListedModuleSite,
	isLuaLogTagSite,
	EXISTING,
	referenceContext,
	scanFile,
	SHARED_LUA_ROOT,
	pinnedBytes,
	LUA_SHORT_STRING,
	ownTails,
	ownClimbs,
	joinedPaths,
	jsConstants,
	sharedRootRewrite,
	switchesSharedRoot,
	attributeSteps,
	REFUSED_KINDS,
	runtimeEditState,
	isModuleLoadSite,
	REVIEWED_KINDS,
	directoryMap,
	moveMap,
	steps,
	references,
	luaModuleName,
	luaCollisions,
	stepKeyOf,
	BASE_GATES,
	CATEGORY_GATES
};
