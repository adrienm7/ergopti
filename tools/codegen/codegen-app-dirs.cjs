// tools/codegen/codegen-app-dirs.cjs

/**
 * ==============================================================================
 * MODULE: Application Folders Codegen
 * DESCRIPTION:
 * Emits the application folder name, the per-OS default logs folder and the
 * log file-name prefixes from the canonical _shared/modules/paths/app_dirs.toml
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
const SOURCE = path.join(SP, '_shared/modules/paths/app_dirs.toml');

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
	macos: logs.macos || fail('[logs.macos] is missing.'),
	windows: logs.windows || fail('[logs.windows] is missing.'),
	linux: logs.linux || fail('[logs.linux] is missing.')
};
if (data.unifiedPrefix === data.errorsPrefix) fail('the unified and errors prefixes must differ.');

/** Resolves an OS segment list into its relative path, checking the app folder. */
function relative(osName, separator) {
	const segments = requireSegments(data[osName], 'segments', `logs.${osName}`);
	if (segments.filter((s) => s === APP_PLACEHOLDER).length !== 1) {
		fail(`logs.${osName}.segments must name "${APP_PLACEHOLDER}" exactly once.`);
	}
	return segments.map((s) => (s === APP_PLACEHOLDER ? folderName : s)).join(separator);
}

const macos = {
	base: requireString(data.macos, 'base', 'logs.macos'),
	relative: relative('macos', '/'),
	launcherLog: requireString(data.macos, 'launcher_log', 'logs.macos'),
	fatalReport: requireString(data.macos, 'fatal_report', 'logs.macos')
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
if (!macos.relative.endsWith(folderName)) {
	fail(
		'logs.macos.segments must end with the application folder: the launcher restricts only that folder.'
	);
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
		'--- _shared/lua/app_dirs.lua\n' +
		'--- AUTO-GENERATED from _shared/modules/paths/app_dirs.toml.\n' +
		'--- DO NOT EDIT BY HAND — run `npm run codegen:app-dirs` to refresh.\n' +
		'\n' +
		'--- ==============================================================================\n' +
		'--- DATA: Application Folders and Log File Names\n' +
		'--- DESCRIPTION:\n' +
		'--- The application folder name, the default logs folder of each Lua driver and\n' +
		'--- the log file-name prefixes. Each driver has ONE logs-folder resolver built on\n' +
		'--- this table (macOS infra/logger.lua, Linux infra/logger_sink.lua); nothing\n' +
		'--- else spells a prefix or a folder formula.\n' +
		'--- ==============================================================================\n' +
		'\n' +
		'return {\n' +
		`\tfolder_name = ${luaStr(data.folderName)},\n` +
		`\toverride_key = ${luaStr(data.overrideKey)},\n` +
		`\tlinux_storage_key = ${luaStr(data.linuxStorageKey)},\n` +
		`\tcrash_reports_dir = ${luaStr(data.crashReportsDir)},\n` +
		'\tfiles = {\n' +
		`\t\tunified_prefix = ${luaStr(data.unifiedPrefix)},\n` +
		`\t\terrors_prefix = ${luaStr(data.errorsPrefix)},\n` +
		`\t\ttopical_prefix = ${luaStr(data.topicalPrefix)},\n` +
		`\t\textension = ${luaStr(data.extension)},\n` +
		'\t},\n' +
		'\tmacos = {\n' +
		`\t\tbase_env = ${luaStr(macos.base)},\n` +
		`\t\trelative = ${luaStr(macos.relative)},\n` +
		`\t\tlauncher_log = ${luaStr(macos.launcherLog)},\n` +
		`\t\tfatal_report = ${luaStr(macos.fatalReport)},\n` +
		'\t},\n' +
		'\tlinux = {\n' +
		`\t\tbase_env = ${luaStr(linux.base)},\n` +
		`\t\tbase_fallback = ${luaStr(linux.baseFallback)},\n` +
		`\t\trelative = ${luaStr(linux.relative)},\n` +
		'\t},\n' +
		'}\n'
	);
}

// ── Windows ─────────────────────────────────────────────────────────────────

function emitAhk() {
	const fn = (name, value, doc) => `; ${doc}\n${name}() {\n\treturn ${ahkStr(value)}\n}\n`;
	return (
		'﻿; _generated/app_dirs.ahk\n' +
		'; AUTO-GENERATED from _shared/modules/paths/app_dirs.toml.\n' +
		'; DO NOT EDIT BY HAND — run `npm run codegen:app-dirs` to refresh.\n' +
		'#Requires AutoHotkey v2.0\n' +
		'\n' +
		'; ==============================================================================\n' +
		'; MODULE: Application Folders and Log File Names (Windows)\n' +
		'; DESCRIPTION:\n' +
		'; The application folder name, the default logs folder and the log file-name\n' +
		'; prefixes. infra/logger.ahk owns the one logs-folder resolver built on them;\n' +
		'; nothing else spells a prefix or a folder formula.\n' +
		';\n' +
		'; Functions rather than global initialisers so include ORDER cannot matter:\n' +
		'; boot reads them before the logger include has run its own top level.\n' +
		'; ==============================================================================\n' +
		'\n' +
		fn('AppDirsFolderName', data.folderName, 'Folder named after the application, on every OS.') +
		'\n' +
		fn(
			'AppDirsWindowsManagedOllamaFolderName',
			managedOllamaFolder,
			'Separate direct LocalApplicationData child for the managed Windows runtime.'
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
			'AppDirsWindowsLogsBaseEnv',
			windows.base,
			'Environment variable holding the default logs root.'
		) +
		'\n' +
		fn(
			'AppDirsWindowsLogsRelative',
			windows.relative,
			'Default logs folder, relative to that root.'
		)
	);
}

// ── Native macOS launcher ───────────────────────────────────────────────────

function emitSwift() {
	const constant = (name, value, doc) => `/// ${doc}\nlet ${name} = ${swiftStr(value)}\n`;
	return (
		'// Sources/ErgoptiPlus/AppDirs.generated.swift\n' +
		'// AUTO-GENERATED from _shared/modules/paths/app_dirs.toml.\n' +
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
			'Folder named after the application, on every OS.'
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
		)
	);
}

// ── Write ───────────────────────────────────────────────────────────────────

const targets = [
	[path.join(SP, '_shared/lua/app_dirs.lua'), emitLua()],
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
	`[OK] application folders generated: folder "${folderName}", ` +
		`macOS ~/${macos.relative}, Windows %${windows.base}%\\${windows.relative}, ` +
		`Linux $${linux.base}/${linux.relative}.`
);
