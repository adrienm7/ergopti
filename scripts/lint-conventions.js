#!/usr/bin/env node
// scripts/lint-conventions.js
// Cross-platform convention linter for .ahk and .lua source files.
//
// Checks enforced:
//   1. File header   — first non-empty line must be a comment containing a relative path
//   2. No Co-Authored-By — recent commits must not contain Co-Authored-By trailers
//   3. No PascalCase TOML keys — keys in config/**/*.toml must start with lowercase
//   4. Section spacing — major sections need 5 blank lines before, minor 3
//   5. Banner alignment — = counts must match title line length exactly
//
// Usage:
//   node scripts/lint-conventions.js [--fail-on-violations] [--warn-only]
//   Exit code 0 = clean (or warn-only), 1 = violations found (when --fail-on-violations).

import { readFileSync, writeFileSync, readdirSync, statSync } from 'fs';
import { join, relative, extname } from 'path';
import { execSync } from 'child_process';

const REPO_ROOT = new URL('..', import.meta.url).pathname.replace(/\/$/, '').replace(/^\/([A-Z]:)/, '$1');

const FAIL_ON_VIOLATIONS  = process.argv.includes('--fail-on-violations');
const WARN_ONLY           = process.argv.includes('--warn-only');
const FIX_BANNERS         = process.argv.includes('--fix-banners');
const FIX_SPACING         = process.argv.includes('--fix-spacing');
const FIX_UNBALANCED      = process.argv.includes('--fix-unbalanced');

let totalViolations = 0;

function warn(file, line, msg) {
	const rel = relative(REPO_ROOT, file).replace(/\\/g, '/');
	const loc = line != null ? `:${line}` : '';
	console.warn(`  WARN  ${rel}${loc}  ${msg}`);
	totalViolations++;
}

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────

function walkFiles(dir, ext, out = []) {
	let entries;
	try { entries = readdirSync(dir); } catch { return out; }
	for (const e of entries) {
		if (e === 'node_modules' || e === '.git' || e === 'vendor') continue;
		const full = join(dir, e);
		let st;
		try { st = statSync(full); } catch { continue; }
		if (st.isDirectory()) walkFiles(full, ext, out);
		else if (ext.includes(extname(e))) out.push(full);
	}
	return out;
}

function readLines(file) {
	// Strip UTF-8 BOM (﻿) before splitting so checks see clean content
	return readFileSync(file, 'utf8').replace(/^﻿/, '').replace(/\r\n/g, '\n').split('\n');
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 1 — File header comment
// ──────────────────────────────────────────────────────────────────────────────

const AHK_COMMENT  = /^;\s*\S/;
const LUA_COMMENT  = /^---?\s*\S/;
// Path-like: contains a slash and a dot (e.g. "lib/logger.ahk")
const PATH_LIKE    = /[/\\][^/\\]+\.[a-z]+/i;

function checkFileHeader(file) {
	const lines = readLines(file);
	// Find first non-empty line
	let first = null;
	let firstIdx = 0;
	for (let i = 0; i < Math.min(lines.length, 5); i++) {
		if (lines[i].trim() !== '') { first = lines[i]; firstIdx = i + 1; break; }
	}
	if (first === null) { warn(file, 1, 'File is empty or has no content in first 5 lines'); return; }

	const ext = extname(file);
	const isComment = ext === '.ahk' ? AHK_COMMENT.test(first) : LUA_COMMENT.test(first);
	if (!isComment) {
		warn(file, firstIdx, `First non-empty line is not a comment: ${first.slice(0, 60)}`);
		return;
	}
	if (!PATH_LIKE.test(first)) {
		warn(file, firstIdx, `Header comment does not look like a file path: ${first.slice(0, 60)}`);
	}
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 2 — No Co-Authored-By in recent commits
// ──────────────────────────────────────────────────────────────────────────────

function checkNoCoAuthor() {
	let log = '';
	try {
		// Try from origin/dev, fall back to last 20 commits
		try {
			log = execSync('git log origin/dev..HEAD --format=%B', { cwd: REPO_ROOT, encoding: 'utf8', stdio: ['pipe','pipe','pipe'] });
		} catch {
			log = execSync('git log -20 --format=%B', { cwd: REPO_ROOT, encoding: 'utf8', stdio: ['pipe','pipe','pipe'] });
		}
	} catch {
		return; // git not available
	}

	const lines = log.split('\n');
	lines.forEach((line, i) => {
		if (/co-authored-by/i.test(line)) {
			console.warn(`  WARN  git-log:${i + 1}  Co-Authored-By trailer found in recent commit: ${line.trim()}`);
			totalViolations++;
		}
	});
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 3 — No PascalCase TOML keys
// ──────────────────────────────────────────────────────────────────────────────

const TOML_KEY_RE = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=/;

function checkTomlKeys(file) {
	const lines = readLines(file);
	lines.forEach((line, i) => {
		// Skip comments and section headers
		if (/^\s*[#\[]/.test(line)) return;
		const m = TOML_KEY_RE.exec(line);
		if (!m) return;
		const key = m[1];
		if (/^[A-Z]/.test(key)) {
			warn(file, i + 1, `PascalCase TOML key: "${key}" — use snake_case`);
		}
	});
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 4 — Section spacing (AHK and Lua)
// ──────────────────────────────────────────────────────────────────────────────

// Major: ======= Title ======= (7 = on each side)
const MAJOR_TITLE_AHK = /^; ={7} .+ ={7}$/;
const MAJOR_TITLE_LUA = /^--- ={7} .+ ={7}$/;
// Minor: ===== Title ===== (5 = on each side)
const MINOR_TITLE_AHK = /^; ={5} .+ ={5}$/;
const MINOR_TITLE_LUA = /^--- ={5} .+ ={5}$/;

function countTrailingBlanks(lines, idx) {
	let count = 0;
	for (let i = idx - 1; i >= 0; i--) {
		if (lines[i].trim() === '') count++;
		else break;
	}
	return count;
}

function checkSectionSpacing(file) {
	const ext   = extname(file);
	const isAhk = ext === '.ahk';
	const lines = readLines(file);

	lines.forEach((line, i) => {
		const isMajor = isAhk ? MAJOR_TITLE_AHK.test(line) : MAJOR_TITLE_LUA.test(line);
		const isMinor = isAhk ? MINOR_TITLE_AHK.test(line) : MINOR_TITLE_LUA.test(line);

		if (!isMajor && !isMinor) return;

		// The title line is preceded by 2 (major) or 1 (minor) banner lines.
		// We check blank lines before the first banner line.
		const bannerCount  = isMajor ? 2 : 1;
		const bannerIdx    = i - bannerCount; // 0-based index of first banner line
		if (bannerIdx < 0) return;

		const blanks       = countTrailingBlanks(lines, bannerIdx);
		const required     = isMajor ? 5 : 3;

		if (blanks < required) {
			warn(file, i + 1, `${isMajor ? 'Major' : 'Minor'} section needs ${required} blank lines before it, found ${blanks}`);
		}
	});
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 5 — Banner alignment
// ──────────────────────────────────────────────────────────────────────────────

function checkBannerAlignment(file) {
	const ext   = extname(file);
	const isAhk = ext === '.ahk';
	const prefix = isAhk ? '; ' : '--- ';
	const lines  = readLines(file);

	lines.forEach((line, i) => {
		// Match a title line: prefix + 5 or 7 = + space + title + space + 5 or 7 =
		const m = line.match(/^(;|---?) (={5,7}) (.+) (={5,7})$/);
		if (!m) return;
		const leftEq  = m[2].length;
		const title   = m[3];
		const rightEq = m[4].length;

		if (leftEq !== rightEq) {
			warn(file, i + 1, `Unbalanced = counts: ${leftEq} left vs ${rightEq} right`);
			return;
		}

		// Expected banner length = prefix + leftEq + 1 + title + 1 + rightEq
		const expectedBannerLen = prefix.length + leftEq + 1 + title.length + 1 + rightEq;
		// Check adjacent banner lines (look up and down)
		for (const adj of [i - 1, i + 1]) {
			if (adj < 0 || adj >= lines.length) continue;
			const adjLine = lines[adj];
			// A banner line: prefix + one or more =
			if (!/^(;|---?) =+$/.test(adjLine)) continue;
			if (adjLine.length !== expectedBannerLen) {
				warn(file, adj + 1, `Banner line length ${adjLine.length} does not match title line length ${expectedBannerLen}`);
			}
		}
	});
}

// ──────────────────────────────────────────────────────────────────────────────
// Fix — Banner alignment auto-fixer
// ──────────────────────────────────────────────────────────────────────────────

function fixBannersInFile(file) {
	const ext    = extname(file);
	const isAhk  = ext === '.ahk';
	const prefix = isAhk ? '; ' : '--- ';
	const raw    = readFileSync(file, 'utf8');
	const hasBom = raw.startsWith('﻿');
	const lines  = raw.replace(/^﻿/, '').replace(/\r\n/g, '\n').split('\n');
	let changed  = false;

	for (let i = 0; i < lines.length; i++) {
		const m = lines[i].match(/^(;|---?) (={5,7}) (.+) (={5,7})$/);
		if (!m) continue;
		const leftEq = m[2].length;
		const title  = m[3];
		const rightEq = m[4].length;
		if (leftEq !== rightEq) continue; // unbalanced — skip

		const expectedLen = prefix.length + leftEq + 1 + title.length + 1 + rightEq;
		const bannerBody  = '='.repeat(expectedLen - prefix.length);
		const bannerLine  = prefix + bannerBody;

		for (const adj of [i - 1, i + 1]) {
			if (adj < 0 || adj >= lines.length) continue;
			if (!/^(;|---?) =+$/.test(lines[adj])) continue;
			if (lines[adj].length !== expectedLen) {
				lines[adj] = bannerLine;
				changed = true;
			}
		}
	}

	if (!changed) return false;

	const enc     = isAhk ? 'utf8' : 'utf8'; // both UTF-8
	const content = (hasBom ? '﻿' : '') + lines.join('\n');
	// Preserve original line endings
	const crlf = raw.includes('\r\n');
	writeFileSync(file, crlf ? content.replace(/\n/g, '\r\n') : content, enc);
	return true;
}

// ──────────────────────────────────────────────────────────────────────────────
// Fix — Section spacing auto-fixer (insert missing blank lines before banners)
// ──────────────────────────────────────────────────────────────────────────────

function fixSpacingInFile(file) {
	const ext   = extname(file);
	const isAhk = ext === '.ahk';
	const raw   = readFileSync(file, 'utf8');
	const hasBom = raw.startsWith('﻿');
	const lines = raw.replace(/^﻿/, '').replace(/\r\n/g, '\n').split('\n');
	let changed = false;

	// Walk backwards so insertions don't shift indices
	for (let i = lines.length - 1; i >= 0; i--) {
		const line = lines[i];
		const isMajor = isAhk ? MAJOR_TITLE_AHK.test(line) : MAJOR_TITLE_LUA.test(line);
		const isMinor = isAhk ? MINOR_TITLE_AHK.test(line) : MINOR_TITLE_LUA.test(line);
		if (!isMajor && !isMinor) continue;

		const bannerCount = isMajor ? 2 : 1;
		const bannerIdx   = i - bannerCount;
		if (bannerIdx < 0) continue;

		const blanks   = countTrailingBlanks(lines, bannerIdx);
		const required = isMajor ? 5 : 3;
		if (blanks >= required) continue;

		// Insert (required - blanks) empty lines before bannerIdx
		const toInsert = required - blanks;
		lines.splice(bannerIdx, 0, ...Array(toInsert).fill(''));
		changed = true;
	}

	if (!changed) return false;

	const content = (hasBom ? '﻿' : '') + lines.join('\n');
	const crlf    = raw.includes('\r\n');
	writeFileSync(file, crlf ? content.replace(/\n/g, '\r\n') : content, 'utf8');
	return true;
}

// ──────────────────────────────────────────────────────────────────────────────
// Fix — Unbalanced = counts (balance title lines, then fix adjacent banners)
// ──────────────────────────────────────────────────────────────────────────────

function fixUnbalancedInFile(file) {
	const ext    = extname(file);
	const isAhk  = ext === '.ahk';
	const prefix = isAhk ? '; ' : '--- ';
	const raw    = readFileSync(file, 'utf8');
	const hasBom = raw.startsWith('﻿');
	const lines  = raw.replace(/^﻿/, '').replace(/\r\n/g, '\n').split('\n');
	let changed  = false;

	for (let i = 0; i < lines.length; i++) {
		const m = lines[i].match(/^(;|---?) (={5,7}) (.+) (={5,7})$/);
		if (!m) continue;
		const leftEq  = m[2].length;
		const title   = m[3];
		const rightEq = m[4].length;
		if (leftEq === rightEq) continue; // already balanced

		// Use the larger side as the canonical count
		const eq = Math.max(leftEq, rightEq);
		const newTitle = `${prefix}${'='.repeat(eq)} ${title} ${'='.repeat(eq)}`;
		lines[i] = newTitle;

		// Also fix adjacent banner lines
		const expectedLen = prefix.length + eq + 1 + title.length + 1 + eq;
		const bannerBody  = '='.repeat(expectedLen - prefix.length);
		const bannerLine  = prefix + bannerBody;
		for (const adj of [i - 1, i + 1]) {
			if (adj < 0 || adj >= lines.length) continue;
			if (!/^(;|---?) =+$/.test(lines[adj])) continue;
			lines[adj] = bannerLine;
		}
		changed = true;
	}

	if (!changed) return false;

	const content = (hasBom ? '﻿' : '') + lines.join('\n');
	const crlf    = raw.includes('\r\n');
	writeFileSync(file, crlf ? content.replace(/\n/g, '\r\n') : content, 'utf8');
	return true;
}

// ──────────────────────────────────────────────────────────────────────────────
// Runner
// ──────────────────────────────────────────────────────────────────────────────

console.log('lint-conventions: scanning…');

// AHK files — lib/ and modules/ only (skip vendor/, tests/ for header check)
const ahkSourceDirs = [
	join(REPO_ROOT, 'static/drivers/autohotkey/lib'),
	join(REPO_ROOT, 'static/drivers/autohotkey/modules'),
	join(REPO_ROOT, 'static/drivers/autohotkey/ui'),
];
const ahkTestDirs = [
	join(REPO_ROOT, 'static/drivers/autohotkey/tests'),
];
const ahkAll = [
	...ahkSourceDirs.flatMap(d => walkFiles(d, ['.ahk'])),
	...ahkTestDirs.flatMap(d => walkFiles(d, ['.ahk'])),
];

// Lua files — hammerspoon driver only (skip vendor/)
const luaDirs = [
	join(REPO_ROOT, 'static/drivers/hammerspoon/lib'),
	join(REPO_ROOT, 'static/drivers/hammerspoon/modules'),
	join(REPO_ROOT, 'static/drivers/hammerspoon/ui'),
	join(REPO_ROOT, 'static/drivers/hammerspoon/tests'),
];
const luaAll = luaDirs.flatMap(d => walkFiles(d, ['.lua']));

// TOML files — config repo sibling
const tomlDirs = [
	join(REPO_ROOT, '..', 'config', 'ergopti_plus'),
	join(REPO_ROOT, 'static', 'drivers', '_shared'),
];
const tomlAll = tomlDirs.flatMap(d => walkFiles(d, ['.toml']));

console.log(`  AHK files : ${ahkAll.length}`);
console.log(`  Lua files : ${luaAll.length}`);
console.log(`  TOML files: ${tomlAll.length}`);
console.log('');

// Auto-fix banner alignment before linting
if (FIX_BANNERS) {
	let fixed = 0;
	for (const f of [...ahkAll, ...luaAll]) {
		if (fixBannersInFile(f)) fixed++;
	}
	console.log(`  Fixed banners in ${fixed} file(s).`);
	console.log('');
}

// Auto-fix unbalanced = counts (balance title line, update adjacent banners)
if (FIX_UNBALANCED) {
	let fixed = 0;
	for (const f of [...ahkAll, ...luaAll]) {
		if (fixUnbalancedInFile(f)) fixed++;
	}
	console.log(`  Fixed unbalanced = counts in ${fixed} file(s).`);
	console.log('');
}

// Auto-fix section spacing (insert missing blank lines before banners)
if (FIX_SPACING) {
	let fixed = 0;
	for (const f of [...ahkAll, ...luaAll]) {
		if (fixSpacingInFile(f)) fixed++;
	}
	console.log(`  Fixed section spacing in ${fixed} file(s).`);
	console.log('');
}

// Run checks
for (const f of ahkAll)  checkFileHeader(f);
for (const f of luaAll)  checkFileHeader(f);
for (const f of tomlAll) checkTomlKeys(f);
for (const f of [...ahkAll, ...luaAll]) {
	checkSectionSpacing(f);
	checkBannerAlignment(f);
}
checkNoCoAuthor();

// Report
console.log('');
if (totalViolations === 0) {
	console.log('lint-conventions: OK — no violations found.');
	process.exit(0);
} else {
	console.log(`lint-conventions: ${totalViolations} violation(s) found.`);
	if (FAIL_ON_VIOLATIONS && !WARN_ONLY) {
		process.exit(1);
	} else {
		console.log('  (running in warn-only mode — exit 0)');
		process.exit(0);
	}
}
