/**
 ; tools/lint/audit-gui-titles.cjs
 ;
 ; DESCRIPTION:
 ; Scans AHK and Lua source files for Gui creation and windowTitle settings.
 ; Verifies that all window titles follow the mandatory format: "ErgoptiPlus — Nom".
 ; Fails if any title uses a hardcoded string that doesn't include the prefix.
 */

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '../../');
const WINDOWS_DIR = path.join(REPO_ROOT, 'static/ergopti_plus/windows');
const MACOS_DIR = path.join(REPO_ROOT, 'static/ergopti_plus/macos');

let totalViolations = 0;

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
			e === 'vendor' ||
			e === 'tests'
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

function auditAhkFile(filePath) {
	const content = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
	const cleanContent = content.replace(/;.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

	// Check for raw Gui(..., "Title") calls.
	// We now mandate Gui_Create or similar helpers that enforce the prefix.
	const guiRegex = /\bGui\(\s*["'][^"']*["']\s*,\s*["']([^"']+)["']\s*\)/g;
	let match;
	while ((match = guiRegex.exec(cleanContent)) !== null) {
		const title = match[1];
		if (!title.startsWith('ErgoptiPlus')) {
			console.error(
				`\x1b[31m[FAIL]\x1b[0m ${path.relative(REPO_ROOT, filePath)}: Raw Gui() title "${title}" missing "ErgoptiPlus" prefix.`
			);
			totalViolations++;
		}
	}
}

function auditLuaFile(filePath) {
	const content = fs.readFileSync(filePath, 'utf8');
	const cleanContent = content.replace(/--.*$/gm, '').replace(/--\[\[[\s\S]*?\]\]/g, '');

	// Check for windowTitle calls that don't use the prefix.
	// ui_builder.lua is the centralized place now, but let's check others.
	if (filePath.endsWith('ui_builder.lua')) return;

	const titleRegex = /:windowTitle\(\s*["']([^"']+)["']\s*\)/g;
	let match;
	while ((match = titleRegex.exec(cleanContent)) !== null) {
		const title = match[1];
		if (!title.startsWith('ErgoptiPlus')) {
			console.error(
				`\x1b[31m[FAIL]\x1b[0m ${path.relative(REPO_ROOT, filePath)}: :windowTitle() "${title}" missing "ErgoptiPlus" prefix.`
			);
			totalViolations++;
		}
	}
}

const ahkFiles = walkFiles(WINDOWS_DIR, ['.ahk']);
const luaFiles = walkFiles(MACOS_DIR, ['.lua']);

ahkFiles.forEach(auditAhkFile);
luaFiles.forEach(auditLuaFile);

if (totalViolations > 0) {
	console.error(`\x1b[31m[ERROR] Found ${totalViolations} window title violation(s).\x1b[0m`);
	console.error(`Mandatory format: "ErgoptiPlus — Name"`);
	process.exit(1);
} else {
	console.log(
		'\x1b[32m[OK] All scanned window titles respect the "ErgoptiPlus" prefix convention.\x1b[0m'
	);
}
