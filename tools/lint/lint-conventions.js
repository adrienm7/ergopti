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
import sharedPaths from '../lib/paths.cjs';

const { shared } = sharedPaths;

// This script lives at <repo>/tools/lint/, so the repo root is two levels up.
const REPO_ROOT = new URL('../..', import.meta.url).pathname
	.replace(/\/$/, '')
	.replace(/^\/([A-Z]:)/, '$1');

const FAIL_ON_VIOLATIONS = process.argv.includes('--fail-on-violations');
const WARN_ONLY = process.argv.includes('--warn-only');
const FIX_BANNERS = process.argv.includes('--fix-banners');
const FIX_SPACING = process.argv.includes('--fix-spacing');
const FIX_UNBALANCED = process.argv.includes('--fix-unbalanced');

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
	try {
		entries = readdirSync(dir);
	} catch {
		return out;
	}
	for (const e of entries) {
		if (e === 'node_modules' || e === '.git' || e === 'vendor') continue;
		const full = join(dir, e);
		let st;
		try {
			st = statSync(full);
		} catch {
			continue;
		}
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

const AHK_COMMENT = /^;\s*\S/;
const LUA_COMMENT = /^---?\s*\S/;
// Path-like: contains a slash and a dot (e.g. "lib/logger.ahk")
const PATH_LIKE = /[/\\][^/\\]+\.[a-z]+/i;

function checkFileHeader(file) {
	const lines = readLines(file);
	// Find first non-empty line
	let first = null;
	let firstIdx = 0;
	for (let i = 0; i < Math.min(lines.length, 5); i++) {
		if (lines[i].trim() !== '') {
			first = lines[i];
			firstIdx = i + 1;
			break;
		}
	}
	if (first === null) {
		warn(file, 1, 'File is empty or has no content in first 5 lines');
		return;
	}

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
			log = execSync('git log origin/dev..HEAD --format=%B', {
				cwd: REPO_ROOT,
				encoding: 'utf8',
				stdio: ['pipe', 'pipe', 'pipe']
			});
		} catch {
			log = execSync('git log -20 --format=%B', {
				cwd: REPO_ROOT,
				encoding: 'utf8',
				stdio: ['pipe', 'pipe', 'pipe']
			});
		}
	} catch {
		return; // git not available
	}

	const lines = log.split('\n');
	lines.forEach((line, i) => {
		if (/co-authored-by/i.test(line)) {
			console.warn(
				`  WARN  git-log:${i + 1}  Co-Authored-By trailer found in recent commit: ${line.trim()}`
			);
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

// Major: ======= Title ======= (7 = on each side). Lua banners legitimately use
// either "--" (the language's own comment marker, the dominant convention) or
// "---" (the EmmyLua docstring marker, used where a banner opens right after a
// module docstring) — both must be recognized, or spacing goes unchecked.
const MAJOR_TITLE_AHK = /^; ={7} .+ ={7}$/;
const MAJOR_TITLE_LUA = /^---? ={7} .+ ={7}$/;
// Minor: ===== Title ===== (5 = on each side)
const MINOR_TITLE_AHK = /^; ={5} .+ ={5}$/;
const MINOR_TITLE_LUA = /^---? ={5} .+ ={5}$/;

function countTrailingBlanks(lines, idx) {
	let count = 0;
	for (let i = idx - 1; i >= 0; i--) {
		if (lines[i].trim() === '') count++;
		else break;
	}
	return count;
}

function checkSectionSpacing(file) {
	const ext = extname(file);
	const isAhk = ext === '.ahk';
	const lines = readLines(file);

	lines.forEach((line, i) => {
		const isMajor = isAhk ? MAJOR_TITLE_AHK.test(line) : MAJOR_TITLE_LUA.test(line);
		const isMinor = isAhk ? MINOR_TITLE_AHK.test(line) : MINOR_TITLE_LUA.test(line);

		if (!isMajor && !isMinor) return;

		// The title line is preceded by 2 (major) or 1 (minor) banner lines.
		// We check blank lines before the first banner line.
		const bannerCount = isMajor ? 2 : 1;
		const bannerIdx = i - bannerCount; // 0-based index of first banner line
		if (bannerIdx < 0) return;

		const blanks = countTrailingBlanks(lines, bannerIdx);
		const required = isMajor ? 5 : 3;

		if (blanks < required) {
			warn(
				file,
				i + 1,
				`${isMajor ? 'Major' : 'Minor'} section needs ${required} blank lines before it, found ${blanks}`
			);
		}
	});
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 5 — Banner alignment
// ──────────────────────────────────────────────────────────────────────────────

function checkBannerAlignment(file) {
	const lines = readLines(file);

	lines.forEach((line, i) => {
		// Match a title line: marker + 5 or 7 = + space + title + space + 5 or 7 =
		const m = line.match(/^(;|---?) (={5,7}) (.+) (={5,7})$/);
		if (!m) return;
		// The real prefix is THIS line's own marker + space — never assumed from
		// the file extension. Lua banners legitimately use "--" or "---" (see
		// MAJOR_TITLE_LUA); hardcoding one produced a false "length mismatch" on
		// every correctly-aligned "--"-marker banner (marker.length off by one).
		const prefix = m[1] + ' ';
		const leftEq = m[2].length;
		const title = m[3];
		const rightEq = m[4].length;

		if (leftEq !== rightEq) {
			warn(file, i + 1, `Unbalanced = counts: ${leftEq} left vs ${rightEq} right`);
			return;
		}

		// Expected banner length = prefix + leftEq + 1 + title + 1 + rightEq
		const expectedBannerLen = prefix.length + leftEq + 1 + title.length + 1 + rightEq;

		// Convention 2: a MAJOR banner (7 "=" either side of the title) carries 2
		// rule lines above and 2 below; a MINOR banner (5 "=") carries 1 and 1.
		const expectedRules = leftEq === 7 ? 2 : 1;

		// Walks the contiguous run of rule lines away from the title and returns
		// them in the order they appear in the file.
		const runFrom = (start, step) => {
			const run = [];
			for (let k = start; k >= 0 && k < lines.length; k += step) {
				if (!/^(;|---?) (=+)$/.test(lines[k])) break;
				run.push(k);
			}
			return run;
		};

		// The old check looked at lines i-1 and i+1 ONLY, and `continue`d when
		// either was not a rule line. So it verified the LENGTH of whichever rule
		// lines happened to be adjacent and never the COUNT — a major banner with
		// one rule line, or with none at all, passed in complete silence. That is
		// how 68 non-conforming major banners coexisted with a linter reporting
		// zero violations.
		const above = runFrom(i - 1, -1);
		const below = runFrom(i + 1, 1);
		for (const [side, run] of [['above', above], ['below', below]]) {
			if (run.length !== expectedRules) {
				warn(
					file,
					i + 1,
					`${leftEq === 7 ? 'Major' : 'Minor'} banner needs ${expectedRules} rule line(s) ${side} the title, found ${run.length}`
				);
			}
			for (const adj of run) {
				const adjMatch = lines[adj].match(/^(;|---?) (=+)$/);
				if (adjMatch[1] !== m[1]) {
					warn(file, adj + 1, `Banner marker '${adjMatch[1]}' does not match title line marker '${m[1]}'`);
					continue;
				}
				if (lines[adj].length !== expectedBannerLen) {
					warn(
						file,
						adj + 1,
						`Banner line length ${lines[adj].length} does not match title line length ${expectedBannerLen}`
					);
				}
			}
		}
	});
}

// ──────────────────────────────────────────────────────────────────────────────
// Fix — Banner alignment auto-fixer
// ──────────────────────────────────────────────────────────────────────────────

function fixBannersInFile(file) {
	const raw = readFileSync(file, 'utf8');
	const hasBom = raw.startsWith('﻿');
	const lines = raw.replace(/^﻿/, '').replace(/\r\n/g, '\n').split('\n');
	let changed = false;

	for (let i = 0; i < lines.length; i++) {
		const m = lines[i].match(/^(;|---?) (={5,7}) (.+) (={5,7})$/);
		if (!m) continue;
		const leftEq = m[2].length;
		const title = m[3];
		const rightEq = m[4].length;
		if (leftEq !== rightEq) continue; // unbalanced — skip

		// The real prefix is THIS line's own marker + space — never assumed from
		// the file extension (see checkBannerAlignment). Using a hardcoded "--- "
		// on a file whose banners use "--" rewrote correctly-aligned fill lines
		// with a mismatched marker, turning an aligned banner into a broken one.
		const prefix = m[1] + ' ';
		const expectedLen = prefix.length + leftEq + 1 + title.length + 1 + rightEq;
		const bannerBody = '='.repeat(expectedLen - prefix.length);
		const bannerLine = prefix + bannerBody;
		// Convention 2: 2 rule lines each side of a major title, 1 each side of a
		// minor one. The checker used to look at i-1 and i+1 only, so it repaired
		// the LENGTH of whichever rule lines happened to be adjacent and never the
		// COUNT.
		const expectedRules = leftEq === 7 ? 2 : 1;

		const isRule = (s) => /^(;|---?) (=+)$/.test(s || '');
		const runFrom = (start, step) => {
			const run = [];
			for (let k = start; k >= 0 && k < lines.length; k += step) {
				if (!isRule(lines[k])) break;
				run.push(k);
			}
			return run;
		};

		// Repair BOTH a wrong marker and a wrong length on every rule line of the
		// run — a fill line belongs to this title's banner and must match it on
		// both. This is what heals the accumulated damage from the old
		// hardcoded-prefix bug, rather than just refusing to touch it.
		for (const adj of [...runFrom(i - 1, -1), ...runFrom(i + 1, 1)]) {
			if (lines[adj] !== bannerLine) {
				lines[adj] = bannerLine;
				changed = true;
			}
		}

		// INSERT the missing rule lines; never delete a surplus one. Every
		// violation measured in this repo is "too few" (0 or 1 where 2 are due),
		// and a delete could eat the closing rule of a module docstring sitting
		// directly above a banner in a file whose blank-line spacing is also
		// wrong. A surplus stays a warning for a human to read.
		const below = runFrom(i + 1, 1);
		if (below.length < expectedRules) {
			lines.splice(i + 1, 0, ...Array(expectedRules - below.length).fill(bannerLine));
			changed = true;
		}
		const above = runFrom(i - 1, -1);
		if (above.length < expectedRules) {
			const insertAt = i - above.length;
			lines.splice(insertAt, 0, ...Array(expectedRules - above.length).fill(bannerLine));
			// The title moved down by however many lines were inserted above it.
			i += expectedRules - above.length;
			changed = true;
		}
	}

	if (!changed) return false;

	const content = (hasBom ? '﻿' : '') + lines.join('\n');
	// Preserve original line endings
	const crlf = raw.includes('\r\n');
	writeFileSync(file, crlf ? content.replace(/\n/g, '\r\n') : content, 'utf8');
	return true;
}

// ──────────────────────────────────────────────────────────────────────────────
// Fix — Section spacing auto-fixer (insert missing blank lines before banners)
// ──────────────────────────────────────────────────────────────────────────────

function fixSpacingInFile(file) {
	const ext = extname(file);
	const isAhk = ext === '.ahk';
	const raw = readFileSync(file, 'utf8');
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
		const bannerIdx = i - bannerCount;
		if (bannerIdx < 0) continue;

		const blanks = countTrailingBlanks(lines, bannerIdx);
		const required = isMajor ? 5 : 3;
		if (blanks >= required) continue;

		// Insert (required - blanks) empty lines before bannerIdx
		const toInsert = required - blanks;
		lines.splice(bannerIdx, 0, ...Array(toInsert).fill(''));
		changed = true;
	}

	if (!changed) return false;

	const content = (hasBom ? '﻿' : '') + lines.join('\n');
	const crlf = raw.includes('\r\n');
	writeFileSync(file, crlf ? content.replace(/\n/g, '\r\n') : content, 'utf8');
	return true;
}

// ──────────────────────────────────────────────────────────────────────────────
// Fix — Unbalanced = counts (balance title lines, then fix adjacent banners)
// ──────────────────────────────────────────────────────────────────────────────

function fixUnbalancedInFile(file) {
	const raw = readFileSync(file, 'utf8');
	const hasBom = raw.startsWith('﻿');
	const lines = raw.replace(/^﻿/, '').replace(/\r\n/g, '\n').split('\n');
	let changed = false;

	for (let i = 0; i < lines.length; i++) {
		const m = lines[i].match(/^(;|---?) (={5,7}) (.+) (={5,7})$/);
		if (!m) continue;
		const leftEq = m[2].length;
		const title = m[3];
		const rightEq = m[4].length;
		if (leftEq === rightEq) continue; // already balanced

		// The real prefix is THIS line's own marker + space — never assumed from
		// the file extension (see checkBannerAlignment / fixBannersInFile).
		const prefix = m[1] + ' ';
		// Use the larger side as the canonical count
		const eq = Math.max(leftEq, rightEq);
		const newTitle = `${prefix}${'='.repeat(eq)} ${title} ${'='.repeat(eq)}`;
		lines[i] = newTitle;

		// Also fix adjacent banner lines
		const expectedLen = prefix.length + eq + 1 + title.length + 1 + eq;
		const bannerBody = '='.repeat(expectedLen - prefix.length);
		const bannerLine = prefix + bannerBody;
		for (const adj of [i - 1, i + 1]) {
			if (adj < 0 || adj >= lines.length) continue;
			const adjMatch = lines[adj].match(/^(;|---?) (=+)$/);
			if (!adjMatch) continue;
			lines[adj] = bannerLine; // repair marker + length to match this title
		}
		changed = true;
	}

	if (!changed) return false;

	const content = (hasBom ? '﻿' : '') + lines.join('\n');
	const crlf = raw.includes('\r\n');
	writeFileSync(file, crlf ? content.replace(/\n/g, '\r\n') : content, 'utf8');
	return true;
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 6 — AHK Anti-patterns
// ──────────────────────────────────────────────────────────────────────────────

function checkAhkAntiPatterns(file) {
	const raw = readFileSync(file, 'utf8');
	// Strip comments to check for code anti-patterns
	const codeOnly = raw.replace(/;.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
	
	if (codeOnly.includes('JSON.parse(')) {
		warn(file, null, `JSON.parse() is not valid AHK. Use JsonParse() instead.`);
	}
	
	// Check for UIA wrapper guard in hotstring_prefix_watcher.ahk.
	// The guard was originally _UIA_WRAP_PAIRS.Has; after the refactor to
	// WrapSymbols_GetActivePairs() the equivalent check is .Has(Char) on that call.
	// The map may also be snapshotted into a local first — `X := WrapSymbols_GetActivePairs()`
	// then `X.Has(Char)` — which is the preferred form (one lookup, consistent
	// membership-vs-value read), so that pattern counts as a valid guard too.
	if (file.includes('hotstring_prefix_watcher.ahk')) {
		const hasUiaCall  = codeOnly.includes('GetUIASelection');
		const hasOldGuard = codeOnly.includes('_UIA_WRAP_PAIRS.Has');
		const hasNewGuard = codeOnly.includes('WrapSymbols_GetActivePairs().Has');
		// Snapshot form: any var assigned from WrapSymbols_GetActivePairs() whose .Has is checked.
		let hasSnapshotGuard = false;
		const snapRe = /(\w+)\s*:=\s*WrapSymbols_GetActivePairs\(\)/g;
		let snap;
		while ((snap = snapRe.exec(codeOnly)) !== null) {
			if (codeOnly.includes(`${snap[1]}.Has`)) { hasSnapshotGuard = true; break; }
		}
		if (hasUiaCall && !hasOldGuard && !hasNewGuard && !hasSnapshotGuard) {
			warn(file, null, `GetUIASelection used without an active-pairs .Has guard. This causes severe lag.`);
		}
	}

	// Check for Lua-style comments in AHK files which evaluate as pre-decrements
	const lines = raw.replace(/^﻿/, '').replace(/\r\n/g, '\n').split('\n');
	lines.forEach((line, i) => {
		if (/^\s*--\s/.test(line)) {
			warn(file, i + 1, `Lua-style comment (-- comment) found in AHK file.`);
		}
	});
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 7 — Lua Anti-patterns
// ──────────────────────────────────────────────────────────────────────────────

function checkLuaAntiPatterns(file) {
	const raw = readFileSync(file, 'utf8');
	
	if (file.includes('healthcheck.lua')) {
		if (!raw.includes('title = "ErgoptiPlus — " .. title') && !raw.includes('title = "ErgoptiPlus ??? " .. title')) {
			warn(file, null, `Healthcheck window title does not enforce ErgoptiPlus prefix.`);
		}
	}
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 8 — Web UI Checks
// ──────────────────────────────────────────────────────────────────────────────

function checkWebUiAntiPatterns() {
	const scriptPath = shared('ui/changelog/script.js');
	const stylePath = shared('ui/changelog/style.css');

	try {
		const script = readFileSync(scriptPath, 'utf8');
		if (!script.includes('btnGh.style.display = "none"') && !script.includes("btnGh.style.display = 'none'")) {
			warn(scriptPath, null, `Does not hide GitHub button on clearContent().`);
		}
	} catch (e) { /* ignore if missing */ }

	try {
		const style = readFileSync(stylePath, 'utf8');
		if (!style.match(/#btn-github\s*\{[^}]*display:\s*none;/)) {
			warn(stylePath, null, `Does not hide #btn-github by default.`);
		}
	} catch (e) { /* ignore if missing */ }
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 9 — macOS Gesture Defaults
// ──────────────────────────────────────────────────────────────────────────────

function checkMacOsGestureDefaults() {
	const manifestPath = shared('modules/features/manifest.toml');
	try {
		const content = readFileSync(manifestPath, 'utf8');
		// Only look at the hs.gestures section
		const hsBlock = content.split('# ===== 5.1 hs.gestures =====')[1].split('# =================================')[0];
		
		const ids = ['swipe_4_up', 'swipe_4_down', 'swipe_4_left', 'swipe_4_right', 'swipe_5_up', 'swipe_5_down', 'swipe_5_left', 'swipe_5_right'];
		
		for (const id of ids) {
			const regex = new RegExp(`id\\s*=\\s*"${id}"\\s*default\\s*=\\s*"([^"]+)"`, 'm');
			const match = hsBlock.match(regex);
			if (match && match[1] !== 'none') {
				warn(manifestPath, null, `macOS gesture default for ${id} is "${match[1]}", expected "none".`);
			}
		}
	} catch (e) { /* ignore */ }
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 10 — AHK String Escaping (v2 style)
// ──────────────────────────────────────────────────────────────────────────────

function checkAhkStringEscaping(file) {
	const raw = readFileSync(file, 'utf8');
	// wrap_symbols_config.ahk legitimately uses `" to embed literal double-quotes
	// inside TOML strings built via concatenation — no single-quote alternative exists.
	if (file.includes('wrap_symbols_config.ahk')) return;
	if (raw.includes('`"')) {
		warn(file, null, `Found backtick-escaped quote (\`"). Prefer single-quoted strings '...' for cleaner Regex/literals in AHK v2.`);
	}
}

// ──────────────────────────────────────────────────────────────────────────────
// Check 11 — macOS Path Integrity
// ──────────────────────────────────────────────────────────────────────────────

function checkMacOsPathIntegrity() {
	const kbdMenu = join(REPO_ROOT, 'static/ergopti_plus/macos/ui/menu/menu_keyboard_layout.lua');
	try {
		const content = readFileSync(kbdMenu, 'utf8');
		if (content.includes('local BUNDLES_RELDIR = "../macos/bundles/"')) {
			warn(kbdMenu, null, `BUNDLES_RELDIR is incorrect (relative to static/ergopti_plus/macos/). Use "../../ergopti/macos/bundles/".`);
		}
	} catch (e) { /* ignore */ }
}

// ──────────────────────────────────────────────────────────────────────────────
// Runner
// ──────────────────────────────────────────────────────────────────────────────

console.log('lint-conventions: scanning…');

// AHK files — lib/ and modules/ only (skip vendor/, tests/ for header check)
const ahkSourceDirs = [
	join(REPO_ROOT, 'static/ergopti_plus/windows/lib'),
	join(REPO_ROOT, 'static/ergopti_plus/windows/modules'),
	join(REPO_ROOT, 'static/ergopti_plus/windows/ui')
];
const ahkTestDirs = [join(REPO_ROOT, 'static/ergopti_plus/windows/tests')];
const ahkAll = [
	...ahkSourceDirs.flatMap((d) => walkFiles(d, ['.ahk'])),
	...ahkTestDirs.flatMap((d) => walkFiles(d, ['.ahk']))
];

// Lua files — every Lua tree the repo owns (walkFiles skips vendor/).
//
// This used to be the macOS driver alone, so the Linux driver and _shared/lua
// were never checked for file-path headers, banner alignment or section
// spacing — the two trees that grew most recently, held to no convention at
// all. The conventions are language-wide, not driver-wide.
const luaDirs = [
	join(REPO_ROOT, 'static/ergopti_plus/macos/lib'),
	join(REPO_ROOT, 'static/ergopti_plus/macos/modules'),
	join(REPO_ROOT, 'static/ergopti_plus/macos/ui'),
	join(REPO_ROOT, 'static/ergopti_plus/macos/tests'),
	join(REPO_ROOT, 'static/ergopti_plus/linux/adapters'),
	join(REPO_ROOT, 'static/ergopti_plus/linux/lib'),
	join(REPO_ROOT, 'static/ergopti_plus/linux/modules'),
	join(REPO_ROOT, 'static/ergopti_plus/linux/ui'),
	join(REPO_ROOT, 'static/ergopti_plus/linux/tests'),
	join(REPO_ROOT, 'static/ergopti_plus/_shared/lua')
];
const luaAll = luaDirs.flatMap((d) => walkFiles(d, ['.lua']));

// Same guard as the TOML one below, for the same reason: a stale path makes
// walkFiles() return [] and the whole Lua half pass over an empty set. Every
// directory listed above is expected to hold Lua today, so an empty one is a
// wrong selector rather than an empty tree.
for (const dir of luaDirs) {
	if (walkFiles(dir, ['.lua']).length === 0) {
		console.error(
			`lint-conventions: FATAL — no .lua found under ${dir}. ` +
			'The scan path is stale; fix it rather than letting the Lua checks pass on an empty set.'
		);
		process.exit(1);
	}
}

// TOML files — the shared data tree, plus the maintainer's sibling config repo
// when it happens to be checked out next door.
//
// The second entry used to be static/drivers/_shared, a path deleted in the
// static/ reorg. walkFiles() returns [] for a missing directory, so the ADR-003
// snake_case check silently covered ZERO repository files: in CI the count was 0,
// and locally the non-zero count came entirely from the sibling repo, which made
// the hole invisible. The sibling stays (it is a genuine convenience) but it is
// never the reason this list is non-empty.
const tomlDirs = [
	join(REPO_ROOT, 'static', 'ergopti_plus', '_shared'),
	join(REPO_ROOT, '..', 'config', 'ergopti_plus')
];
const tomlAll = tomlDirs.flatMap((d) => walkFiles(d, ['.toml']));

// Guard against the exact regression above: a stale path makes walkFiles() return
// [] and the whole TOML check pass vacuously. The shared tree always has TOMLs, so
// finding none means the selector is wrong, not the tree.
const sharedTomlCount = walkFiles(join(REPO_ROOT, 'static', 'ergopti_plus', '_shared'), ['.toml']).length;
if (sharedTomlCount === 0) {
	console.error(
		'lint-conventions: FATAL — no .toml found under static/ergopti_plus/_shared. ' +
		'The scan path is stale; fix it rather than letting the TOML checks pass on an empty set.'
	);
	process.exit(1);
}

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
for (const f of ahkAll) {
	checkFileHeader(f);
	checkAhkAntiPatterns(f);
	checkAhkStringEscaping(f);
}
for (const f of luaAll) {
	checkFileHeader(f);
	checkLuaAntiPatterns(f);
}
for (const f of tomlAll) checkTomlKeys(f);
for (const f of [...ahkAll, ...luaAll]) {
	checkSectionSpacing(f);
	checkBannerAlignment(f);
}
checkNoCoAuthor();
checkWebUiAntiPatterns();
checkMacOsGestureDefaults();
checkMacOsPathIntegrity();

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
