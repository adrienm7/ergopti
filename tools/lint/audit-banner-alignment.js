#!/usr/bin/env node
// tools/lint/audit-banner-alignment.js
// Audit (and optionally fix) banner-comment alignment across .toml files following
// the CLAUDE.md rules:
//   - Major section: 5 lines (2 banner + 1 title + 2 banner), 7 ``=`` on each side
//                    of the title; banner length matches the title line length exactly.
//   - Minor section: 3 lines (1 banner + 1 title + 1 banner), 5 ``=`` on each side
//                    of the title; banner length matches the title line length.
//
// Usage:
//   node scripts/audit-banner-alignment.js [--fix] <file_or_dir> [...]
//   Exit code 0 = all aligned (or fixed), 1 = misalignments found and not fixed.

import { readFileSync, writeFileSync, readdirSync, statSync } from 'fs';
import { join } from 'path';

const TITLE_MAJOR_RE = /^# ======= (.+) =======$/;
const TITLE_MINOR_RE = /^# ===== (.+) =====$/;
const BANNER_RE = /^# =+$/;

function makeBanner(length) {
	return '# ' + '='.repeat(length - 2);
}

function processFile(filePath, fix) {
	const lines = readFileSync(filePath, 'utf8').split(/\r?\n/);
	const errors = [];
	let mutated = false;

	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		const majorMatch = line.match(TITLE_MAJOR_RE);
		const minorMatch = line.match(TITLE_MINOR_RE);

		if (majorMatch) {
			const title = majorMatch[1];
			const expected = 18 + title.length;
			for (const offset of [-2, -1, 1, 2]) {
				const idx = i + offset;
				const banner = lines[idx];
				if (!banner || !BANNER_RE.test(banner)) {
					errors.push(`${filePath}:${idx + 1}  missing major-banner line around "${title}"`);
					continue;
				}
				if (banner.length !== expected) {
					errors.push(
						`${filePath}:${idx + 1}  major-banner length=${banner.length} expected=${expected}`
					);
					if (fix) {
						lines[idx] = makeBanner(expected);
						mutated = true;
					}
				}
			}
		} else if (minorMatch) {
			const title = minorMatch[1];
			const expected = 14 + title.length;
			for (const offset of [-1, 1]) {
				const idx = i + offset;
				const banner = lines[idx];
				if (!banner || !BANNER_RE.test(banner)) {
					errors.push(`${filePath}:${idx + 1}  missing minor-banner line around "${title}"`);
					continue;
				}
				if (banner.length !== expected) {
					errors.push(
						`${filePath}:${idx + 1}  minor-banner length=${banner.length} expected=${expected}`
					);
					if (fix) {
						lines[idx] = makeBanner(expected);
						mutated = true;
					}
				}
			}
		}
	}

	if (fix && mutated) {
		writeFileSync(filePath, lines.join('\n'), 'utf8');
	}

	return { errors, mutated };
}

function walk(target, fix) {
	const result = { errors: [], mutated: [] };
	const stat = statSync(target);
	if (stat.isDirectory()) {
		for (const entry of readdirSync(target)) {
			const sub = walk(join(target, entry), fix);
			result.errors.push(...sub.errors);
			result.mutated.push(...sub.mutated);
		}
	} else if (stat.isFile() && target.endsWith('.toml')) {
		const { errors, mutated } = processFile(target, fix);
		result.errors.push(...errors);
		if (mutated) result.mutated.push(target);
	}
	return result;
}

const rawArgs = process.argv.slice(2);
const fix = rawArgs.includes('--fix');
const targets = rawArgs.filter((a) => a !== '--fix');

if (targets.length === 0) {
	console.error('Usage: node scripts/audit-banner-alignment.js [--fix] <file_or_dir> [...]');
	process.exit(2);
}

const { errors, mutated } = (() => {
	const out = { errors: [], mutated: [] };
	for (const t of targets) {
		const sub = walk(t, fix);
		out.errors.push(...sub.errors);
		out.mutated.push(...sub.mutated);
	}
	return out;
})();

if (fix) {
	if (mutated.length === 0) {
		console.log('No banner-alignment issues — nothing to fix.');
		process.exit(0);
	}
	console.log(`Fixed banner alignment in ${mutated.length} file(s):`);
	for (const f of mutated) console.log('  ' + f);
	// Re-audit to confirm nothing remains unfixable (e.g. missing banners).
	const recheck = (() => {
		const out = { errors: [] };
		for (const t of targets) {
			const sub = walk(t, false);
			out.errors.push(...sub.errors);
		}
		return out;
	})();
	if (recheck.errors.length > 0) {
		console.error('Remaining issues after --fix:');
		for (const e of recheck.errors) console.error('  ' + e);
		process.exit(1);
	}
	console.log('All banners aligned after fix.');
	process.exit(0);
}

if (errors.length === 0) {
	console.log('All banners are correctly aligned.');
	process.exit(0);
}
console.error('Misalignments detected:');
for (const err of errors) console.error('  ' + err);
console.error(`\nRun with --fix to auto-correct.`);
process.exit(1);
