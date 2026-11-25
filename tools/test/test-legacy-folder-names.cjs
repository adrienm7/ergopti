// tools/test/test-legacy-folder-names.cjs

/**
 * ==============================================================================
 * MODULE: Legacy Folder Names Gate
 * DESCRIPTION:
 * Fails when anything but the one-time migration spells a data folder of the
 * builds before the single folder name (maintainer decision, 2026-11-03), or
 * spells a root with another case or a "Plus" form of the name: `Ergopti` on
 * macOS and Windows, `ergopti` under XDG on Linux, every folder named once in
 * _shared/core/fs/data/paths/app_dirs.toml.
 *
 * FEATURES & RATIONALE:
 * 1. Old Spellings: the old names come from the app_dirs [migration] table, so
 *    the gate follows the migration rather than a list of its own.
 * 2. Owners Only: the TOML, its generated files, the migration modules, their
 *    tests and vectors, the handoff, the TODO item and the TODO-tests checks
 *    may name the old folders; history (docs/audits) is not rewritten. Every
 *    other tracked text file is read: a list of scanned folders once left
 *    static/ergopti/ out, where a stale ~/.config/ergopti_plus stayed.
 * 3. Deferred Owned Runtime: the owned Karabiner runtime keeps its compiled
 *    folder (app_dirs [owned_runtime.macos]) until its next rebuild, so its
 *    system tree and per-user karabiner home are not old spellings.
 * 4. Hand Spellings Follow the Root: the shell, Python and Go helpers that
 *    cannot read the generated files spell the macOS support root by hand;
 *    each must spell the current one.
 * 5. One Spelling per OS: a root followed by the name in another case or with
 *    "Plus" (~/.local/state/Ergopti, ~/Library/Logs/ergopti,
 *    %LOCALAPPDATA%\ErgoptiPlus) is a divergent folder even when no build
 *    used it, so a doc or a fixture cannot drift from the declared name.
 * 6. Cannot Pass Vacuously: a planted line of each old and divergent spelling
 *    must be caught before the tree is judged.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { data } = require('./lib/app-dirs.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const OWNERS = new Set([
	'static/ergopti_plus/_shared/core/fs/data/paths/app_dirs.toml',
	'static/ergopti_plus/_shared/core/fs/engine/app_dirs.lua',
	'static/ergopti_plus/windows/_generated/app_dirs.ahk',
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/AppDirs.generated.swift',
	'static/ergopti_plus/_shared/settings/engine/migration/legacy_folder_migration_core.lua',
	'static/ergopti_plus/_shared/tests/lua/settings/legacy_folder_migration_contract.lua',
	'static/ergopti_plus/_shared/tests/corpus/paths/legacy_folder_migration_vectors.json',
	'static/ergopti_plus/macos/core/fs/adapters/legacy_folder_migration.lua',
	'static/ergopti_plus/macos/tests/unit/core/fs/adapters/test_legacy_folder_migration.lua',
	'static/ergopti_plus/linux/settings/engine/migration/legacy_folder_migration.lua',
	'static/ergopti_plus/linux/tests/unit/settings/migration/test_legacy_folder_migration.lua',
	'static/ergopti_plus/windows/settings/engine/migration/legacy_folder_migration.ahk',
	'static/ergopti_plus/windows/tests/unit/settings/engine/migration/test_legacy_folder_migration.ahk',
	'docs/tooling/one-folder-name-handoff.md',
	'TODO.md',
	'TODO-tests-linux.md',
	'TODO-tests-macos.md',
	'TODO-tests-windows.md',
	'tools/test/test-legacy-folder-names.cjs'
]);
const HISTORY = /^docs\/audits\//;
// The helpers that cannot read the generated files and spell the macOS
// support root themselves.
const HAND_SPELLED_SUPPORT =
	/(^|\/)(ensure-[^/]+\.sh|native_python_bootstrap\.sh|managed_ollama_runtime\.py|managed_ollama_hint\.py|network_bootstrap_posix\.go)$/;

const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const SEP = '[\\\\/]+';
// The system tree and the per-user karabiner home of the owned runtime, which
// keep their compiled folder (feature 3).
const NOT_SYSTEM_TREE = '(?<!(^|[\\s`\'"(=:])/Library/)';

/** The regular expressions of every old data-folder spelling. */
function oldSpellings() {
	const macos = data.migration.macos;
	const windows = data.migration.windows;
	const linux = data.migration.linux;
	const owned = data.owned_runtime.macos.folder_name;
	const rows = [];
	const add = (label, source) => rows.push({ label, pattern: new RegExp(source) });
	for (const segments of [
		macos.legacy_config,
		macos.legacy_logs,
		macos.legacy_cache,
		macos.legacy_control
	])
		add(segments.join('/'), segments.map(escape).join(SEP) + '(?![\\w-])');
	// The old support folder, except the owned runtime that keeps it: the
	// root-owned system tree and the per-user karabiner home.
	add(
		`Application Support/${macos.legacy_support_folder}`,
		`${NOT_SYSTEM_TREE}Application Support${SEP}${escape(
			macos.legacy_support_folder
		)}(?![\\w-])(?!${SEP}karabiner)`
	);
	if (owned !== macos.legacy_support_folder)
		throw new Error(
			'the gate exempts the owned runtime only while it keeps the old support folder'
		);
	for (const folder of windows.legacy_ollama_folders) add(folder, `${escape(folder)}(?![\\w-])`);
	add(
		`%${windows.legacy_paths_file_base}%\\${windows.legacy_paths_file.join('\\')}`,
		`(?<!LOCAL)${escape(windows.legacy_paths_file_base)}%?${SEP}${windows.legacy_paths_file.map(escape).join(SEP)}`
	);
	add('A_AppData data folder', `A_AppData\\s*\\.\\s*"\\\\${escape(windows.legacy_paths_file[0])}`);
	add(
		`LOCALAPPDATA/${windows.legacy_local_folder}`,
		`(LOCALAPPDATA|LocalAppData|AppData${SEP}Local)%?["']?\\)?\\s*(\\.\\s*"|,\\s*['"]|${SEP})${SEP.replace('+', '*')}${escape(
			windows.legacy_local_folder
		)}(?![\\w-])`
	);
	for (const base of [['.local', 'state'], ['.local', 'share'], ['.cache']])
		add(
			`${base.join('/')}/${linux.legacy_folder}`,
			base.map(escape).join(SEP) + SEP + escape(linux.legacy_folder) + '(?![\\w-])'
		);
	add(
		`$XDG_*/${linux.legacy_folder}`,
		`XDG_[A-Z]+_(HOME|DIR)\\}?(:-[^}]*\\})?${SEP}${escape(linux.legacy_folder)}(?![\\w-])`
	);
	return rows.concat(divergentSpellings());
}

/**
 * The regular expressions of an OS root followed by the application name in
 * another case or with "Plus" (feature 5). Each captures the folder name as
 * `name`; `allowed` keeps the OS spelling and the owned runtime's folder.
 */
function divergentSpellings() {
	const anyCase = (name) =>
		[...name].map((char) => `[${char.toLowerCase()}${char.toUpperCase()}]`).join('');
	const leaf = `(?<name>${anyCase(data.app.linux_folder_name)}(?:[_-]?${anyCase('plus')})?)(?![\\w-])`;
	const owned = data.owned_runtime.macos.folder_name;
	const linux = data.app.linux_folder_name;
	const app = data.app.folder_name;
	return [
		{
			label: `Linux root not named "${linux}"`,
			pattern: new RegExp(
				`(?:\\.local${SEP}(?:state|share)|\\.cache|\\.config|XDG_[A-Z]+_(?:HOME|DIR)\\}?(?::-[^}]*\\})?)${SEP}${leaf}`,
				'g'
			),
			allowed: (groups) => groups.name === linux
		},
		{
			label: `macOS root not named "${app}"`,
			pattern: new RegExp(
				`(?<system>(?:^|(?<=[\\s\`'"(=:]))/)?Library${SEP}(?<base>Logs|Caches|Application Support)${SEP}${leaf}(?<karabiner>${SEP}karabiner)?`,
				'g'
			),
			// The owned runtime keeps its compiled support folder (feature 3).
			allowed: (groups) =>
				groups.name === app ||
				(groups.name === owned &&
					groups.base === 'Application Support' &&
					Boolean(groups.system || groups.karabiner))
		},
		{
			label: `Windows root not named "${app}"`,
			pattern: new RegExp(
				`(?:LOCALAPPDATA|LocalAppData|AppData${SEP}Local)%?["']?\\)?\\s*(?:\\.\\s*"|,\\s*['"]|${SEP})${SEP.replace('+', '*')}${leaf}`,
				'g'
			),
			allowed: (groups) => groups.name === app
		}
	];
}

/** Every line of a text that spells an old or a divergent folder. */
function findings(text, rows) {
	const out = [];
	text.split('\n').forEach((line, index) => {
		for (const row of rows) {
			const hit = row.allowed
				? [...line.matchAll(row.pattern)].some((match) => !row.allowed(match.groups))
				: row.pattern.test(line);
			if (hit) out.push({ line: index + 1, label: row.label, text: line.trim() });
		}
	});
	return out;
}

const rows = oldSpellings();

// 6. Cannot pass vacuously: every spelling is caught in a planted line, and
// the owned runtime and the new names are not.
for (const planted of [
	'~/.config/ergopti_plus/config.toml',
	'~/Library/Logs/ergopti_plus/launcher.log',
	'~/Library/Caches/ergopti_plus/metrics',
	'~/Library/Application Support/ergopti_plus/control',
	'~/Library/Application Support/ErgoptiPlus/paths.toml',
	'%LOCALAPPDATA%\\ergopti_plus_ollama',
	'%LOCALAPPDATA%\\Ergopti-ollama\\versions',
	'%APPDATA%\\Ergopti\\paths.toml',
	'EnvGet("LOCALAPPDATA") . "\\ergopti_plus\\cache"',
	'path.join(process.env.LOCALAPPDATA, "ergopti_plus", "logs")',
	'A_AppData . "\\Ergopti\\paths.toml"',
	'~/.local/state/ergopti_plus/logs',
	'${XDG_STATE_HOME}/ergopti_plus/logs',
	'~/.local/state/Ergopti/logs',
	'${XDG_CONFIG_HOME:-$HOME/.config}/ErgoptiPlus/config.toml',
	'~/Library/Logs/ergopti/launcher.log',
	'/Users/u/Library/Caches/ergopti/dev/db.sqlite',
	'~/Library/Application Support/ErgoptiPlus/paths.toml',
	'%LOCALAPPDATA%\\ErgoptiPlus\\logs',
	'EnvGet("LOCALAPPDATA") . "\\ergopti\\logs"'
])
	assert(findings(planted, rows).length > 0, `the gate must catch: ${planted}`);
for (const allowed of [
	'/Library/Application Support/ErgoptiPlus/Runtime',
	'~/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json',
	'~/Library/Application Support/Ergopti/config',
	'%LOCALAPPDATA%\\Ergopti\\logs',
	'%LOCALAPPDATA%\\Ergopti\\ollama',
	'~/.local/state/ergopti/logs',
	'${XDG_RUNTIME_DIR}/ergopti-proof',
	'~/.cache/ergopti_updater_etag_main.txt',
	'static/ergopti_plus/_shared',
	'layout = "ergopti_plus"'
])
	assert.deepEqual(findings(allowed, rows), [], `the gate must allow: ${allowed}`);

const tracked = execFileSync('git', ['ls-files', '-z'], { cwd: ROOT, maxBuffer: 1 << 28 })
	.toString()
	.split('\0')
	.filter(Boolean)
	.filter((file) => !OWNERS.has(file) && !HISTORY.test(file))
	.filter(
		(file) =>
			!/\.(png|jpe?g|gif|ico|icns|webp|woff2?|ttf|otf|zip|gz|exe|dll|bin|mp4|webm|keylayout|pdf)$/i.test(
				file
			)
	);

const failures = [];
const support = `Application Support/${data.app.folder_name}`;
let handSpelled = 0;
for (const file of tracked) {
	let text;
	try {
		text = fs.readFileSync(path.join(ROOT, file), 'utf8');
	} catch {
		continue;
	}
	for (const found of findings(text, rows))
		failures.push(`${file}:${found.line}: ${found.label}: ${found.text}`);
	if (HAND_SPELLED_SUPPORT.test(file) && /Application Support\//.test(text)) {
		handSpelled++;
		for (const match of text.matchAll(/Application Support\/([A-Za-z_]+)/g))
			if (match[1] !== data.app.folder_name && match[1] !== data.owned_runtime.macos.folder_name)
				failures.push(
					`${file}: spells "Application Support/${match[1]}", not the support root "${support}"`
				);
	}
}

if (failures.length) {
	console.error(`[ERROR] ${failures.length} old data-folder spelling(s) outside the migration:`);
	for (const failure of failures) console.error('  ' + failure);
	process.exit(1);
}
console.log(
	`[OK] no old data-folder name outside the migration (${tracked.length} files, ${rows.length} spellings, ${handSpelled} hand-spelled support roots).`
);
