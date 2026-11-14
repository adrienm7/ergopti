// tools/codegen/codegen-app-dirs.cjs

/**
 * ==============================================================================
 * MODULE: Application Folders Codegen
 * DESCRIPTION:
 * Emits the application folder name, the per-OS default logs folder and the
 * log file-name prefixes from the canonical _shared/core/fs/data/paths/app_dirs.toml
 * for every consumer: the shared Lua tree (macOS and Linux drivers), the
 * AutoHotkey driver and the native macOS launcher.
 *
 * WHY THIS EXISTS:
 * Each driver spelled these values itself. The macOS log folder formula was
 * re-derived in four files, the Windows one in four more, and the dated-name
 * prefixes appeared as literals in about twenty. When the macOS menu kept the
 * path chosen at boot while the native worker rolled files at midnight, the
 * copies disagreed and "Open today's log" opened yesterday's file. The
 * generated files are committed, so no driver needs a TOML reader for them and
 * none keeps a fallback copy that could drift.
 *
 * USAGE:  node tools/codegen/codegen-app-dirs.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, '_shared/core/fs/data/paths/app_dirs.toml');

const APP_PLACEHOLDER = '{app}';

/** Stops generation with one exact reason. */
function fail(message) {
	console.error(`[ERROR] app_dirs.toml: ${message}`);
	process.exit(1);
}

/** Returns a required non-empty string field. */
function requireString(table, key, where) {
	const value = table ? table[key] : undefined;
	if (typeof value !== 'string' || value === '')
		fail(`${where}.${key} must be a non-empty string.`);
	return value;
}

/** Returns a required non-empty array of non-empty strings. */
function requireSegments(table, key, where) {
	const value = table ? table[key] : undefined;
	if (!Array.isArray(value) || value.length === 0)
		fail(`${where}.${key} must be a non-empty array.`);
	for (const segment of value) {
		if (typeof segment !== 'string' || segment === '' || /[\\/]/.test(segment)) {
			fail(`${where}.${key} holds an invalid segment ${JSON.stringify(segment)}.`);
		}
	}
	return value;
}

const parsed = toml.parse(fs.readFileSync(SOURCE, 'utf8'));
const folderName = requireString(parsed.app, 'folder_name', 'app');
if (/[\\/]/.test(folderName)) fail('app.folder_name must be one path component.');
const linuxFolderName = requireString(parsed.app, 'linux_folder_name', 'app');
if (/[\\/]/.test(linuxFolderName)) fail('app.linux_folder_name must be one path component.');
if (linuxFolderName !== linuxFolderName.toLowerCase())
	fail('app.linux_folder_name must be lower case, as XDG folder names are.');
if (linuxFolderName !== folderName.toLowerCase())
	fail('app.linux_folder_name must be app.folder_name in lower case: one name on every OS.');

// The folder name "{app}" stands for in each OS's segments.
const FOLDER_BY_OS = { macos: folderName, windows: folderName, linux: linuxFolderName };

/** Returns the isolated Windows runtime directory component. */
function requireWindowsRuntimeFolder(value, appFolder) {
	if (
		typeof value !== 'string' ||
		value === '' ||
		value === '.' ||
		value === '..' ||
		/[<>:"/\\|?*\p{Cc}]/u.test(value) ||
		/[. ]$/.test(value) ||
		/^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³]|conin\$|conout\$)(?:\.|$)/i.test(value)
	) {
		fail(
			'runtime.windows.managed_ollama_folder_name must be a valid single Windows directory component.'
		);
	}
	if (value.toLowerCase() === appFolder.toLowerCase())
		fail('runtime.windows.managed_ollama_folder_name must differ from app.folder_name.');
	return value;
}

const managedOllamaFolder = requireWindowsRuntimeFolder(
	parsed.runtime?.windows?.managed_ollama_folder_name,
	folderName
);

const logs = parsed.logs || fail('[logs] is missing.');
const files = logs.files || fail('[logs.files] is missing.');
const data = {
	folderName,
	overrideKey: requireString(logs, 'override_key', 'logs'),
	linuxStorageKey: requireString(logs, 'linux_storage_key', 'logs'),
	crashReportsDir: requireString(logs, 'crash_reports_dir', 'logs'),
	unifiedPrefix: requireString(files, 'unified_prefix', 'logs.files'),
	errorsPrefix: requireString(files, 'errors_prefix', 'logs.files'),
	topicalPrefix: requireString(files, 'topical_prefix', 'logs.files'),
	extension: requireString(files, 'extension', 'logs.files'),
	bootstrapLog: requireString(files, 'bootstrap_log', 'logs.files'),
	macos: logs.macos || fail('[logs.macos] is missing.'),
	windows: logs.windows || fail('[logs.windows] is missing.'),
	linux: logs.linux || fail('[logs.linux] is missing.')
};
if (data.unifiedPrefix === data.errorsPrefix) fail('the unified and errors prefixes must differ.');

/**
 * Resolves one segment list of an OS into its relative path, naming the OS
 * application folder exactly once.
 */
function resolveSegments(table, key, where, osName, separator) {
	const segments = requireSegments(table, key, where);
	if (segments.filter((s) => s === APP_PLACEHOLDER).length !== 1) {
		fail(`${where}.${key} must name "${APP_PLACEHOLDER}" exactly once.`);
	}
	return segments.map((s) => (s === APP_PLACEHOLDER ? FOLDER_BY_OS[osName] : s)).join(separator);
}

/** Resolves an OS logs segment list into its relative path. */
function relative(osName, separator) {
	return resolveSegments(data[osName], 'segments', `logs.${osName}`, osName, separator);
}

/** Returns a required table of the parsed TOML, by dotted name. */
function requireTable(dotted) {
	let table = parsed;
	for (const part of dotted.split('.')) table = table ? table[part] : undefined;
	if (!table || typeof table !== 'object') fail(`[${dotted}] is missing.`);
	return table;
}

/** A purpose folder of macOS or Windows: its base variable and relative path. */
function purposeFolder(dotted, osName, separator) {
	const table = requireTable(dotted);
	return {
		base: requireString(table, 'base', dotted),
		relative: resolveSegments(table, 'segments', dotted, osName, separator)
	};
}

const macos = {
	base: requireString(data.macos, 'base', 'logs.macos'),
	relative: relative('macos', '/'),
	launcherLog: requireString(data.macos, 'launcher_log', 'logs.macos'),
	fatalReport: requireString(data.macos, 'fatal_report', 'logs.macos'),
	reloadBreadcrumb: requireString(data.macos, 'reload_breadcrumb', 'logs.macos')
};
const windows = {
	base: requireString(data.windows, 'base', 'logs.windows'),
	relative: relative('windows', '\\')
};
const linux = {
	base: requireString(data.linux, 'base', 'logs.linux'),
	baseFallback: requireSegments(data.linux, 'base_fallback', 'logs.linux').join('/'),
	relative: relative('linux', '/')
};
const configSection = requireTable('config');
const configMacos = purposeFolder('config.macos', 'macos', '/');
const configWindows = purposeFolder('config.windows', 'windows', '\\');
const config = {
	overrideKey: requireString(configSection, 'override_key', 'config'),
	hotstringsDir: requireString(configSection, 'hotstrings_dir', 'config'),
	personalHotstringsFile: requireString(configSection, 'personal_hotstrings_file', 'config'),
	macosBase: configMacos.base,
	macosRelative: configMacos.relative,
	macosPathsFile: resolveSegments(
		requireTable('config.macos'),
		'paths_file',
		'config.macos',
		'macos',
		'/'
	),
	windowsBase: configWindows.base,
	windowsRelative: configWindows.relative,
	windowsPathsFile: resolveSegments(
		requireTable('config.windows'),
		'paths_file',
		'config.windows',
		'windows',
		'\\'
	)
};
if (!macos.relative.endsWith(folderName)) {
	fail(
		'logs.macos.segments must end with the application folder: the launcher restricts only that folder.'
	);
}

const support = {
	macos: purposeFolder('support.macos', 'macos', '/'),
	windows: purposeFolder('support.windows', 'windows', '\\')
};
const cache = {
	macos: purposeFolder('cache.macos', 'macos', '/'),
	windows: purposeFolder('cache.windows', 'windows', '\\')
};
// One root per OS: the configuration and the paths.toml of macOS and Windows
// live inside the support root, never in a second folder.
for (const [osName, root, configRelative, pathsFile] of [
	['macos', support.macos.relative + '/', config.macosRelative, config.macosPathsFile],
	['windows', support.windows.relative + '\\', config.windowsRelative, config.windowsPathsFile]
]) {
	if (!configRelative.startsWith(root) || !pathsFile.startsWith(root))
		fail(`config.${osName} must live inside support.${osName}: one root folder per OS.`);
}
const xdgTable = requireTable('xdg.linux');
const xdg = {
	configBase: requireString(xdgTable, 'config_base', 'xdg.linux'),
	configFallback: requireSegments(xdgTable, 'config_fallback', 'xdg.linux').join('/'),
	dataBase: requireString(xdgTable, 'data_base', 'xdg.linux'),
	dataFallback: requireSegments(xdgTable, 'data_fallback', 'xdg.linux').join('/'),
	cacheBase: requireString(xdgTable, 'cache_base', 'xdg.linux'),
	cacheFallback: requireSegments(xdgTable, 'cache_fallback', 'xdg.linux').join('/'),
	runtimeBase: requireString(xdgTable, 'runtime_base', 'xdg.linux')
};
const ownedRuntimeFolder = requireString(
	requireTable('owned_runtime.macos'),
	'folder_name',
	'owned_runtime.macos'
);

const migrationTable = requireTable('migration');
const migrationMacos = requireTable('migration.macos');
const migrationWindows = requireTable('migration.windows');
const migrationLinux = requireTable('migration.linux');
const migration = {
	backupSuffix: requireString(migrationTable, 'backup_suffix', 'migration'),
	backupFolder: requireString(migrationTable, 'backup_folder', 'migration'),
	macos: {
		legacySupportRelative: support.macos.relative.replace(
			new RegExp(`${folderName}$`),
			requireString(migrationMacos, 'legacy_support_folder', 'migration.macos')
		),
		movedSupportEntries: requireSegments(
			migrationMacos,
			'moved_support_entries',
			'migration.macos'
		),
		legacyConfigRelative: requireSegments(migrationMacos, 'legacy_config', 'migration.macos').join(
			'/'
		),
		legacyLogsRelative: requireSegments(migrationMacos, 'legacy_logs', 'migration.macos').join('/'),
		legacyCacheRelative: requireSegments(migrationMacos, 'legacy_cache', 'migration.macos').join(
			'/'
		),
		legacyControlRelative: requireSegments(
			migrationMacos,
			'legacy_control',
			'migration.macos'
		).join('/')
	},
	windows: {
		legacyPathsFileBase: requireString(
			migrationWindows,
			'legacy_paths_file_base',
			'migration.windows'
		),
		legacyPathsFile: requireSegments(
			migrationWindows,
			'legacy_paths_file',
			'migration.windows'
		).join('\\'),
		legacyConfigBase: requireString(migrationWindows, 'legacy_config_base', 'migration.windows'),
		legacyConfig: requireSegments(migrationWindows, 'legacy_config', 'migration.windows').join(
			'\\'
		),
		legacyLocalFolder: requireString(migrationWindows, 'legacy_local_folder', 'migration.windows'),
		legacyOllamaFolders: requireSegments(
			migrationWindows,
			'legacy_ollama_folders',
			'migration.windows'
		)
	},
	linux: {
		legacyFolder: requireString(migrationLinux, 'legacy_folder', 'migration.linux')
	}
};
if (!support.macos.relative.endsWith(folderName))
	fail('support.macos.segments must end with the application folder.');
// The backup folder is one entry of each new root: a rename into it stays on
// the volume of that root.
if (!/^[A-Za-z0-9._-]+$/.test(migration.backupFolder))
	fail('migration.backup_folder must be one plain folder name.');
// The Lua and Swift consumers join every macOS folder to the one home folder.
for (const [name, base] of [
	['support.macos', support.macos.base],
	['cache.macos', cache.macos.base],
	['config.macos', config.macosBase]
]) {
	if (base !== macos.base) fail(`${name}.base must be ${macos.base}, as logs.macos.base is.`);
}
for (const legacy of [
	migration.macos.legacySupportRelative.split('/').pop(),
	migration.windows.legacyLocalFolder,
	...migration.windows.legacyOllamaFolders,
	migration.linux.legacyFolder
]) {
	if (legacy === folderName || legacy === linuxFolderName)
		fail(`the legacy folder "${legacy}" must differ from the current folder name.`);
}
for (const legacy of migration.windows.legacyOllamaFolders) {
	if (legacy.toLowerCase() === managedOllamaFolder.toLowerCase())
		fail(`the legacy Ollama folder "${legacy}" must differ from the managed runtime folder.`);
}

/** A Lua double-quoted string literal. */
function luaStr(s) {
	return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

/** An AHK v2 double-quoted string literal (backtick is the escape character). */
function ahkStr(s) {
	return '"' + s.replace(/`/g, '``').replace(/"/g, '`"') + '"';
}

/** A Swift double-quoted string literal. */
function swiftStr(s) {
	return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

// ── Shared Lua (macOS and Linux) ────────────────────────────────────────────

function emitLua() {
	return (
		'--- _shared/core/fs/engine/app_dirs.lua\n' +
		'--- AUTO-GENERATED from _shared/core/fs/data/paths/app_dirs.toml.\n' +
		'--- DO NOT EDIT BY HAND — run `npm run codegen:app-dirs` to refresh.\n' +
		'\n' +
		'--- ==============================================================================\n' +
		'--- DATA: Application Folders and Log File Names\n' +
		'--- DESCRIPTION:\n' +
		'--- The application folder name of each Lua driver, its root and purpose\n' +
		'--- folders, the log file-name prefixes and the old folder names the one-time\n' +
		'--- boot migration moves away from. Each driver has ONE logs-folder resolver\n' +
		'--- built on this table (macOS infra/logger.lua, Linux infra/logger_sink.lua);\n' +
		'--- nothing else spells a prefix or a folder formula. The folder name lives\n' +
		'--- under the OS table (`macos.folder_name`, `linux.folder_name`) because it\n' +
		'--- differs in case between the two Lua drivers.\n' +
		'--- ==============================================================================\n' +
		'\n' +
		'return {\n' +
		`\toverride_key = ${luaStr(data.overrideKey)},\n` +
		`\tlinux_storage_key = ${luaStr(data.linuxStorageKey)},\n` +
		`\tcrash_reports_dir = ${luaStr(data.crashReportsDir)},\n` +
		'\tfiles = {\n' +
		`\t\tunified_prefix = ${luaStr(data.unifiedPrefix)},\n` +
		`\t\terrors_prefix = ${luaStr(data.errorsPrefix)},\n` +
		`\t\ttopical_prefix = ${luaStr(data.topicalPrefix)},\n` +
		`\t\textension = ${luaStr(data.extension)},\n` +
		`\t\tbootstrap_log = ${luaStr(data.bootstrapLog)},\n` +
		'\t},\n' +
		'\tmacos = {\n' +
		`\t\tfolder_name = ${luaStr(folderName)},\n` +
		`\t\tbase_env = ${luaStr(macos.base)},\n` +
		`\t\trelative = ${luaStr(macos.relative)},\n` +
		`\t\tsupport_relative = ${luaStr(support.macos.relative)},\n` +
		`\t\tcache_relative = ${luaStr(cache.macos.relative)},\n` +
		`\t\tlauncher_log = ${luaStr(macos.launcherLog)},\n` +
		`\t\tfatal_report = ${luaStr(macos.fatalReport)},\n` +
		`\t\treload_breadcrumb = ${luaStr(macos.reloadBreadcrumb)},\n` +
		'\t},\n' +
		'\tlinux = {\n' +
		`\t\tfolder_name = ${luaStr(linuxFolderName)},\n` +
		`\t\tbase_env = ${luaStr(linux.base)},\n` +
		`\t\tbase_fallback = ${luaStr(linux.baseFallback)},\n` +
		`\t\trelative = ${luaStr(linux.relative)},\n` +
		`\t\tconfig_env = ${luaStr(xdg.configBase)},\n` +
		`\t\tconfig_fallback = ${luaStr(xdg.configFallback)},\n` +
		`\t\tdata_env = ${luaStr(xdg.dataBase)},\n` +
		`\t\tdata_fallback = ${luaStr(xdg.dataFallback)},\n` +
		`\t\tcache_env = ${luaStr(xdg.cacheBase)},\n` +
		`\t\tcache_fallback = ${luaStr(xdg.cacheFallback)},\n` +
		`\t\truntime_env = ${luaStr(xdg.runtimeBase)},\n` +
		'\t},\n' +
		'\tconfig = {\n' +
		`\t\toverride_key = ${luaStr(config.overrideKey)},\n` +
		`\t\thotstrings_dir = ${luaStr(config.hotstringsDir)},\n` +
		`\t\tpersonal_hotstrings_file = ${luaStr(config.personalHotstringsFile)},\n` +
		`\t\tmacos_base_env = ${luaStr(config.macosBase)},\n` +
		`\t\tmacos_relative = ${luaStr(config.macosRelative)},\n` +
		`\t\tmacos_paths_file = ${luaStr(config.macosPathsFile)},\n` +
		'\t},\n' +
		'\towned_runtime = {\n' +
		`\t\tmacos_folder_name = ${luaStr(ownedRuntimeFolder)},\n` +
		'\t},\n' +
		'\tmigration = {\n' +
		`\t\tbackup_suffix = ${luaStr(migration.backupSuffix)},\n` +
		`\t\tbackup_folder = ${luaStr(migration.backupFolder)},\n` +
		'\t\tmacos = {\n' +
		`\t\t\tlegacy_support_relative = ${luaStr(migration.macos.legacySupportRelative)},\n` +
		`\t\t\tmoved_support_entries = { ${migration.macos.movedSupportEntries.map(luaStr).join(', ')} },\n` +
		`\t\t\tlegacy_config_relative = ${luaStr(migration.macos.legacyConfigRelative)},\n` +
		`\t\t\tlegacy_logs_relative = ${luaStr(migration.macos.legacyLogsRelative)},\n` +
		`\t\t\tlegacy_cache_relative = ${luaStr(migration.macos.legacyCacheRelative)},\n` +
		`\t\t\tlegacy_control_relative = ${luaStr(migration.macos.legacyControlRelative)},\n` +
		'\t\t},\n' +
		'\t\tlinux = {\n' +
		`\t\t\tlegacy_folder = ${luaStr(migration.linux.legacyFolder)},\n` +
		'\t\t},\n' +
		'\t},\n' +
		'}\n'
	);
}

// ── Windows ─────────────────────────────────────────────────────────────────

function emitAhk() {
	const fn = (name, value, doc) => `; ${doc}\n${name}() {\n\treturn ${ahkStr(value)}\n}\n`;
	return (
		'﻿; _generated/app_dirs.ahk\n' +
		'; AUTO-GENERATED from _shared/core/fs/data/paths/app_dirs.toml.\n' +
		'; DO NOT EDIT BY HAND — run `npm run codegen:app-dirs` to refresh.\n' +
		'#Requires AutoHotkey v2.0\n' +
		'\n' +
		'; ==============================================================================\n' +
		'; MODULE: Application Folders and Log File Names (Windows)\n' +
		'; DESCRIPTION:\n' +
		'; The application folder name, the default logs folder and the log file-name\n' +
		'; prefixes. core/logger/engine/logger.ahk owns the one logs-folder resolver built on them;\n' +
		'; nothing else spells a prefix or a folder formula.\n' +
		';\n' +
		'; Functions rather than global initialisers so include ORDER cannot matter:\n' +
		'; boot reads them before the logger include has run its own top level.\n' +
		'; ==============================================================================\n' +
		'\n' +
		fn(
			'AppDirsFolderName',
			data.folderName,
			'Folder named after the application on Windows (and macOS).'
		) +
		'\n' +
		fn(
			'AppDirsWindowsManagedOllamaFolderName',
			managedOllamaFolder,
			'Protected managed Windows runtime folder inside the Ergopti root.'
		) +
		'\n' +
		fn(
			'AppDirsLogsOverrideKey',
			data.overrideKey,
			'paths.toml key of the optional logs-folder override.'
		) +
		'\n' +
		fn(
			'AppDirsCrashReportsDir',
			data.crashReportsDir,
			'Subfolder of the logs folder receiving crash reports.'
		) +
		'\n' +
		fn(
			'AppDirsLogUnifiedPrefix',
			data.unifiedPrefix,
			'Daily unified log: <prefix>yyyy-MM-dd<extension>.'
		) +
		'\n' +
		fn(
			'AppDirsLogErrorsPrefix',
			data.errorsPrefix,
			'Daily WARNING and ERROR mirror: <prefix>yyyy-MM-dd<extension>.'
		) +
		'\n' +
		fn(
			'AppDirsLogTopicalPrefix',
			data.topicalPrefix,
			'Topical sub-files: <prefix><name><extension>.'
		) +
		'\n' +
		fn('AppDirsLogExtension', data.extension, 'Extension of every log file.') +
		'\n' +
		fn(
			'AppDirsLogBootstrapName',
			data.bootstrapLog,
			'Pre-configuration log, always in the default logs folder.'
		) +
		'\n' +
		fn(
			'AppDirsWindowsLogsBaseEnv',
			windows.base,
			'Environment variable holding the default logs root.'
		) +
		'\n' +
		fn(
			'AppDirsWindowsLogsRelative',
			windows.relative,
			'Default logs folder, relative to that root.'
		) +
		'\n' +
		fn(
			'AppDirsWindowsSupportBaseEnv',
			support.windows.base,
			'Environment variable holding the Ergopti root.'
		) +
		'\n' +
		fn(
			'AppDirsWindowsSupportRelative',
			support.windows.relative,
			'The Ergopti root, relative to that variable.'
		) +
		'\n' +
		fn(
			'AppDirsWindowsConfigBaseEnv',
			config.windowsBase,
			'Environment variable holding the default configuration folder.'
		) +
		'\n' +
		fn(
			'AppDirsWindowsConfigRelative',
			config.windowsRelative,
			'Default configuration folder, relative to that variable.'
		) +
		'\n' +
		fn(
			'AppDirsWindowsPathsFileRelative',
			config.windowsPathsFile,
			'The installed paths.toml, relative to the configuration variable.'
		) +
		'\n' +
		fn(
			'AppDirsWindowsCacheBaseEnv',
			cache.windows.base,
			'Environment variable holding the cache folder.'
		) +
		'\n' +
		fn(
			'AppDirsWindowsCacheRelative',
			cache.windows.relative,
			'Cache folder, relative to that variable.'
		) +
		'\n' +
		fn(
			'AppDirsMigrationBackupSuffix',
			migration.backupSuffix,
			'Suffix of the copy the legacy folder migration keeps of a rewritten paths.toml.'
		) +
		'\n' +
		fn(
			'AppDirsMigrationBackupFolder',
			migration.backupFolder,
			'Folder of the root that receives an old entry whose destination is taken.'
		) +
		'\n' +
		fn(
			'AppDirsMigrationWindowsLegacyPathsFileBaseEnv',
			migration.windows.legacyPathsFileBase,
			'Environment variable holding the paths.toml of the builds before the single folder.'
		) +
		'\n' +
		fn(
			'AppDirsMigrationWindowsLegacyPathsFileRelative',
			migration.windows.legacyPathsFile,
			'That legacy paths.toml, relative to its variable.'
		) +
		'\n' +
		fn(
			'AppDirsMigrationWindowsLegacyConfigBaseEnv',
			migration.windows.legacyConfigBase,
			'Environment variable holding the legacy default configuration folder.'
		) +
		'\n' +
		fn(
			'AppDirsMigrationWindowsLegacyConfigRelative',
			migration.windows.legacyConfig,
			'That legacy configuration folder, relative to its variable.'
		) +
		'\n' +
		fn(
			'AppDirsMigrationWindowsLegacyLocalFolder',
			migration.windows.legacyLocalFolder,
			'Legacy LocalApplicationData folder whose entries move into the root.'
		) +
		'\n' +
		'; Legacy managed Ollama folders, LocalApplicationData children moved in order\n' +
		'; into the managed runtime folder.\n' +
		'AppDirsMigrationWindowsLegacyOllamaFolders() {\n' +
		`\treturn [${migration.windows.legacyOllamaFolders.map(ahkStr).join(', ')}]\n` +
		'}\n'
	);
}

// ── Native macOS launcher ───────────────────────────────────────────────────

function emitSwift() {
	const constant = (name, value, doc) => `/// ${doc}\nlet ${name} = ${swiftStr(value)}\n`;
	return (
		'// Sources/ErgoptiPlus/AppDirs.generated.swift\n' +
		'// AUTO-GENERATED from _shared/core/fs/data/paths/app_dirs.toml.\n' +
		'// DO NOT EDIT BY HAND -- run `npm run codegen:app-dirs` to refresh.\n' +
		'\n' +
		'// ==============================================================================\n' +
		'// MODULE: Application Folders and Log File Names\n' +
		'// DESCRIPTION:\n' +
		'// The launcher writes launcher.log and the fatal report in the default logs\n' +
		'// folder, names the dated files the Lua runtime reads back, and restricts\n' +
		'// only a folder named after the application to its owner. Generating these\n' +
		'// keeps the native side from becoming a second source for any of them.\n' +
		'// ==============================================================================\n' +
		'\n' +
		constant(
			'kAppFolderName',
			data.folderName,
			'Folder named after the application on macOS (and Windows).'
		) +
		'\n' +
		constant(
			'kLogUnifiedPrefix',
			data.unifiedPrefix,
			'Daily unified log: <prefix>yyyy-MM-dd<extension>.'
		) +
		'\n' +
		constant(
			'kLogErrorsPrefix',
			data.errorsPrefix,
			'Daily WARNING and ERROR mirror: <prefix>yyyy-MM-dd<extension>.'
		) +
		'\n' +
		constant(
			'kLogTopicalPrefix',
			data.topicalPrefix,
			'Topical sub-files: <prefix><name><extension>.'
		) +
		'\n' +
		constant('kLogFileExtension', data.extension, 'Extension of every log file.') +
		'\n' +
		constant(
			'kMacOSLogsHomeRelativePath',
			macos.relative,
			'Default logs folder, relative to the home folder.'
		) +
		'\n' +
		constant(
			'kLauncherLogFileName',
			macos.launcherLog,
			'Launcher diagnostic log, always in the default logs folder.'
		) +
		'\n' +
		constant(
			'kFatalReportFileName',
			macos.fatalReport,
			'Per-launch fatal report, beside launcher.log.'
		) +
		'\n' +
		constant(
			'kMacOSPathsFileHomeRelativePath',
			config.macosPathsFile,
			'The paths.toml that may move the configuration folder, relative to the home folder.'
		) +
		'\n' +
		constant(
			'kMacOSSupportHomeRelativePath',
			support.macos.relative,
			'The Ergopti root (managed runtimes, locks, control), relative to the home folder.'
		) +
		'\n' +
		constant(
			'kMacOSCacheHomeRelativePath',
			cache.macos.relative,
			'The cache folder, relative to the home folder.'
		) +
		'\n' +
		constant(
			'kMacOSOwnedRuntimeFolderName',
			ownedRuntimeFolder,
			'Folder name the owned Karabiner runtime is compiled with, kept until its rebuild.'
		)
	);
}

// ── Write ───────────────────────────────────────────────────────────────────

const targets = [
	[path.join(SP, '_shared/core/fs/engine/app_dirs.lua'), emitLua()],
	[path.join(SP, 'windows/_generated/app_dirs.ahk'), emitAhk()],
	[path.join(SP, 'macos/launcher/Sources/ErgoptiPlus/AppDirs.generated.swift'), emitSwift()]
];

for (const [abs, content] of targets) {
	fs.mkdirSync(path.dirname(abs), { recursive: true });
	// LF everywhere; the AHK payload carries its required UTF-8 BOM as the first
	// character.
	fs.writeFileSync(abs, content.replace(/\r\n/g, '\n'), 'utf8');
	console.log(`  wrote ${path.relative(ROOT, abs).split(path.sep).join('/')}`);
}

console.log(
	`[OK] application folders generated: folder "${folderName}" (Linux "${linuxFolderName}"), ` +
		`macOS ~/${macos.relative}, Windows %${windows.base}%\\${windows.relative}, ` +
		`Linux $${linux.base}/${linux.relative}.`
);
