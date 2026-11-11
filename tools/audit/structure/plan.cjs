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
 * The full move map of the index.
 * @returns {{files: string[], map: Map<string, string|null>}} Tree-relative paths.
 */
function moveMap(files = Census.trackedFiles(ROOT).map((f) => f.slice(PREFIX.length))) {
	const map = new Map(files.map((f) => [f, Rules.mapPath(f)]));
	foldSingletons(map, new Map([...Census.folderTable(files)].map(([k, v]) => [k, v.size])));
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
const LAYER_ORDER = ['core', 'platform', 'settings', 'menu', 'tray', '*', 'tests'];

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
	}
	for (const c of candidates) {
		if (byRepoPath.has(c.abs))
			return { form: c.form, lead: c.lead, oldRepo: c.abs, newRepo: byRepoPath.get(c.abs) };
	}
	return null;
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
	const rows = [];
	const pathToken = /[A-Za-z0-9_.%\\/-]*[A-Za-z0-9_-]\.[A-Za-z0-9]+/g;
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
		if (file.endsWith('.lua') && inTree) {
			const roots = inTree === '_shared' ? ['_shared', 'macos', 'linux'] : [inTree, '_shared'];
			for (const m of text.matchAll(luaToken)) {
				for (const r of roots) {
					const hit = byLuaName.get(`${r}|${m[1]}`);
					if (hit) {
						add('lua-module', m[1], hit[2] || '(retired)');
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

	const refs = references(map);
	const refsByStep = new Map();
	const stepOfOld = new Map();
	for (const s of plan) for (const [o] of s.moves) stepOfOld.set(PREFIX + o, s.id);
	const luaStep = new Map();
	for (const s of plan)
		for (const [o] of s.moves) {
			const n = luaModuleName(o);
			if (n) luaStep.set(n, s.id);
		}
	for (const r of refs) {
		let id = null;
		if (r.kind === 'lua-module') id = luaStep.get(r.old);
		else {
			const repo = r.new === '(retired)' ? null : r.new;
			for (const s of plan) if (s.moves.some(([, t]) => PREFIX + t === repo)) id = s.id;
			if (!id) id = 'retire';
		}
		r.step = id || 'unknown';
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
		`${plan.length} steps, ${movedCount} moved files, ${retired.length} retired README markers, ${refs.length} reference rewrites. Each step moves one target module on every tree at once and is applied by \`node tools/audit/structure/apply-step.cjs <id>\`.\n`,
		'| step | module | moves | rewrites | rewrite categories | gates beyond the base set |',
		'| --- | --- | --: | --: | --- | --- |'
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
		lines.push(
			`| ${s.id} | \`${s.key}\` | ${s.moves.length} | ${own.length} | ${catText || '—'} | ${gates || '—'} |`
		);
	}
	lines.push(
		'',
		`Base gates of every step: ${BASE_GATES.join(', ')} (defined in docs/design/structure-plan.md).`
	);
	lines.push('', '## Retired README markers', '', ...retired.map((r) => `- \`${PREFIX}${r}\``));
	write(`${OUT_DIR}/steps.md`, lines.join('\n'));
}

if (require.main === module) main();

module.exports = {
	moveMap,
	steps,
	references,
	luaModuleName,
	luaCollisions,
	stepKeyOf,
	BASE_GATES,
	CATEGORY_GATES
};
