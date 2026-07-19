/**
 ; tools/lint/audit-translations.cjs
 ;
 ; DESCRIPTION:
 ; Scans AHK and Lua source files for t("key") or t('key') calls and verifies
 ; that all keys exist in the shared localization JSON files.
 ; Fails if any key is missing or if the manifest references dead keys.
 */

const fs = require('fs');
const path = require('path');
const { shared, sharedRel } = require('../lib/paths.cjs');

const REPO_ROOT = path.resolve(__dirname, '../../');
const LOCALES_DIR = shared('data/locales');
const WINDOWS_DIR = path.join(REPO_ROOT, 'static/ergopti_plus/windows');
const MACOS_DIR = path.join(REPO_ROOT, 'static/ergopti_plus/macos');
const MANIFEST_PATH = shared('modules/menu/menu_manifest.json');

// 1. Load the reference locale (English)
const enLocalePath = path.join(LOCALES_DIR, 'en.json');
const enLocale = JSON.parse(fs.readFileSync(enLocalePath, 'utf8').replace(/^\uFEFF+/, ''));
const availableKeys = new Set(Object.keys(enLocale));

const missingKeys = new Map(); // key -> file[]

function walkFiles(dir, ext, out = []) {
	let entries;
	try {
		entries = fs.readdirSync(dir);
	} catch {
		return out;
	}
	for (const e of entries) {
		if (
			e === 'node_modules' ||
			e === '.git' ||
			e === '_generated' ||
			e === 'tests' ||
			e === 'vendor'
		)
			continue;
		const full = path.join(dir, e);
		let st;
		try {
			st = fs.statSync(full);
		} catch {
			continue;
		}
		if (st.isDirectory()) walkFiles(full, ext, out);
		else if (ext.includes(path.extname(e))) out.push(full);
	}
	return out;
}

function auditFile(filePath) {
	const content = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');

	// Remove comments to avoid false positives (e.g. documentation t("sg_actions.X"))
	const isAhk = path.extname(filePath) === '.ahk';

	const cleanContent = isAhk
		? content.replace(/;.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '')
		: content.replace(/--.*$/gm, '').replace(/--\[\[[\s\S]*?\]\]/g, '');

	// Regex for t("key"), i18n.get("key") or locale_mod.get("key")
	const regex = /\b(t|i18n\.get|locale_mod\.get)\(\s*["']([^"']+)["']\s*\)/g;
	let match;
	while ((match = regex.exec(cleanContent)) !== null) {
		const key = match[2];
		// Skip dynamic keys (containing %s or variable lookups that are hard to audit statically)
		if (key.includes('%') || key.startsWith('category.')) continue;

		if (!availableKeys.has(key)) {
			if (!missingKeys.has(key)) missingKeys.set(key, []);
			missingKeys.get(key).push(path.relative(REPO_ROOT, filePath));
		}
	}
}

// Audit Menu Manifest
const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8').replace(/^\uFEFF+/, ''));
function auditManifest(obj) {
	if (Array.isArray(obj)) {
		obj.forEach(auditManifest);
	} else if (typeof obj === 'object' && obj !== null) {
		if (obj.i18n && !availableKeys.has(obj.i18n)) {
			if (!missingKeys.has(obj.i18n)) missingKeys.set(obj.i18n, []);
			missingKeys.get(obj.i18n).push(sharedRel('modules/menu/menu_manifest.json'));
		}
		Object.values(obj).forEach(auditManifest);
	}
}
auditManifest(manifest);

// Scan all source files
const ahkFiles = walkFiles(WINDOWS_DIR, ['.ahk']);
const luaFiles = walkFiles(MACOS_DIR, ['.lua']);
const allFiles = [...ahkFiles, ...luaFiles];

allFiles.forEach(auditFile);

const REQUIRED_DYNAMIC_KEYS = [
	'menu.about.frequency.1m',
	'menu.about.frequency.5m',
	'menu.about.frequency.10m',
	'menu.about.frequency.1h',
	'menu.about.frequency.2h',
	'menu.about.frequency.3h',
	'menu.about.frequency.6h',
	'menu.about.frequency.12h',
	'menu.about.frequency.24h',
	'menu.about.frequency.2d',
	'menu.about.frequency.7d',
	'menu.about.frequency.never',
	'menu.layout.no_bundle'
];

REQUIRED_DYNAMIC_KEYS.forEach(key => {
	if (!availableKeys.has(key)) {
		if (!missingKeys.has(key)) missingKeys.set(key, []);
		missingKeys.get(key).push('Dynamic key check');
	}
});

if (missingKeys.size > 0) {
	console.error('\x1b[31m[ERROR] Missing translation keys detected:\x1b[0m');
	for (const [key, locations] of missingKeys) {
		console.error(`  - \x1b[33m${key}\x1b[0m referenced in:`);
		[...new Set(locations)].forEach((loc) => console.error(`      ${loc}`));
	}
	process.exit(1);
} else {
	console.log('\x1b[32m[OK] All static translation keys are present in en.json.\x1b[0m');
}
