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
const { stripComments } = require('../../lib/script-source.cjs');

// A feature's sub-folders: a one-file sub-folder folds into the feature and
// its file keeps its own name (clipboard/engine/x.lua → clipboard/x.lua).
const SUB_NAMES = new Set(Rules.SUBS);

const ROOT = path.resolve(__dirname, '..', '..', '..');
const OUT_DIR = 'docs/design/structure-plan';
const PREFIX = `${Census.BASE}/`;

// History is not rewritten: dated audit records name the paths of their day.
const NEVER_REWRITTEN = [/^docs\/audits\//, /^docs\/design\/structure-plan\//, /^CHANGELOG/];
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
		if (rel.startsWith('lua/')) rel = rel.slice(4);
		else if (!target || /^tests\//.test(rel)) return null;
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
				.filter((f) => !BINARY.test(f) && !NEVER_REWRITTEN.some((re) => re.test(f)))
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
function resolvePathToken(raw, file, inTree, byRepoPath) {
	const token = raw.replace(/\\/g, '/');
	const candidates = [];
	if (token.startsWith(PREFIX)) candidates.push({ form: 'repo', lead: '', abs: token });
	const tree = Census.TREES.find((t) => token.startsWith(`${t}/`));
	if (tree) candidates.push({ form: 'tree', lead: '', abs: PREFIX + token });
	if (inTree && !token.startsWith(PREFIX)) {
		const lead = (token.match(/^(%A_LineFile%\/\.\.\/|%A_ScriptDir%\/)/) || [''])[0];
		const rest = token.slice(lead.length);
		const dir = path.posix.dirname(file);
		if (lead !== '%A_ScriptDir%/')
			candidates.push({ form: 'file', lead, abs: path.posix.normalize(`${dir}/${rest}`) });
		candidates.push({
			form: 'root',
			lead,
			abs: path.posix.normalize(`${PREFIX}${inTree}/${rest}`)
		});
		// Paths.shared("modules/llm/x.json") and its peers resolve against _shared/.
		if (inTree !== '_shared' && !lead)
			candidates.push({
				form: 'shared',
				lead,
				abs: path.posix.normalize(`${PREFIX}_shared/${rest}`)
			});
		// SHARED_LUA_DIR .. "/toml_codec/source_open.lua": relative to today's
		// shared Lua root, which S00 turns into _shared itself.
		if (!lead)
			candidates.push({
				form: 'shared',
				lead,
				abs: path.posix.normalize(`${PREFIX}_shared/lua/${rest}`)
			});
	}
	// The token names the first of its readings that exists today; only then
	// is it looked up. Otherwise SCRIPT_DIR .. "/modules/hotstrings" (the
	// driver's own folder) would read as _shared/modules/hotstrings whenever
	// only the shared one moves.
	const existing = candidates.find((c) => EXISTING.has(c.abs));
	if (!existing || !byRepoPath.has(existing.abs)) return null;
	return {
		form: existing.form,
		lead: existing.lead,
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

/**
 * Finds the references to moved files.
 * @param {Map<string, string|null>} map Tree-relative old path to target.
 * @returns {object[]} One row per (file, old token).
 */
function references(map) {
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
	const byRepoDir = directoryMap(map);
	const successors = splitSuccessors(map, byRepoDir);
	const rows = [];
	const pathToken = /[A-Za-z0-9_.%\\/-]*[A-Za-z0-9_-]\.[A-Za-z0-9]+/g;
	// A folder spelled with at least one separator, quoted or not.
	const dirToken = /[A-Za-z0-9_.%\\-]*[\\/][A-Za-z0-9_.%\\/-]*[A-Za-z0-9_]\/?(?![A-Za-z0-9_.])/g;
	const luaToken = /["']([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)["']/g;
	for (const file of textFiles()) {
		const abs = path.join(ROOT, file);
		let stat;
		try {
			stat = fs.statSync(abs);
		} catch {
			continue;
		}
		if (stat.size > TEXT_LIMIT_BYTES) continue;
		const text = fs.readFileSync(abs, 'utf8');
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
		for (const m of text.matchAll(pathToken)) {
			const hit = resolvePathToken(m[0], file, inTree, byRepoPath);
			if (hit) add('path', m[0], hit.newRepo === PREFIX ? '(retired)' : hit.newRepo, hit);
		}
		for (const m of text.matchAll(dirToken)) {
			const raw = m[0].replace(/[\\/]$/, '');
			if (/\.[A-Za-z0-9]+$/.test(raw) || !/[A-Za-z]/.test(raw)) continue;
			const hit = resolvePathToken(raw, file, inTree, byRepoDir);
			if (!hit) continue;
			if (hit.newRepo !== SPLIT) {
				add('dir', raw, hit.newRepo, hit);
				continue;
			}
			// A folder the plan scatters: prose and comments name its nearest common
			// new folder; live code is a refusal until rules.cjs resolves the site.
			const prose = isProse(file, text, code, m.index);
			const successor = successors.get(hit.oldRepo);
			const deep = successor && successor.split('/').length > 3;
			if (prose && deep) add('dir', raw, successor, { ...hit, newRepo: successor });
			else if (prose) add('dir-split-prose', raw, '(split)', hit);
			else if (successor) add('dir-successor', raw, successor, { ...hit, newRepo: successor });
			else add(prose ? 'dir-split-prose' : 'dir-split', raw, '(split)', hit);
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
		if (file.endsWith('.lua') && inTree) {
			// A quoted prefix completed by concatenation: "modules.llm." .. name.
			for (const m of text.matchAll(
				/(?:\brequire\s*\(?\s*|package\.loaded\s*\[\s*)["']((?:[A-Za-z_][A-Za-z0-9_]*\.)+)["']\s*\.\./g
			)) {
				if (Rules.RUNTIME_EDITS.some((e) => PREFIX + e.file === file && e.prefix === m[1]))
					continue;
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
			const roots = inTree === '_shared' ? ['_shared', 'macos', 'linux'] : [inTree, '_shared'];
			for (const m of text.matchAll(luaToken)) {
				for (const r of roots) {
					const hit = byLuaName.get(`${r}|${m[1]}`);
					if (hit) {
						add('lua-module', m[1], hit[2] || '(retired)', { oldRepo: PREFIX + hit[0] });
						break;
					}
				}
			}
		}
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
const REFUSED_KINDS = new Set(['dir-split', 'lua-prefix-split']);
/** The kinds the step applies but a reviewer reads. */
const REVIEWED_KINDS = new Set(['dir-successor', 'dir-split-prose']);

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
	attributeSteps,
	REFUSED_KINDS,
	runtimeEditState,
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
