// tools/test/test-no-plan-refs-in-source.cjs

/**
 * ==============================================================================
 * MODULE: No Plan-Item References In Source (Convention Gate)
 * DESCRIPTION:
 * The project convention forbids refactor/delivery plan-item tokens in source and
 * commit messages: they are meaningless to anyone reading the code later and rot
 * as the plan they referenced disappears. This gate scans the tracked source tree
 * and fails if any survive, so a purge stays purged and no new token can slip in.
 *
 * WHAT COUNTS AS A PLAN-ITEM TOKEN:
 *   - P#.#  /  P#-X.#         e.g. P2.5, P0-G.4, P10.1
 *   - DL-#                    e.g. DL-2, DL-3
 *   - REFACTOR_GUIDE          pointers into the historical refactor doc
 *   - "Phase 2B" / "Phase P#" the plan-phase spellings
 *   - a bare "Phase <n>"      UNLESS the file is on the CAT-B allowlist below,
 *                             where "Phase 1/2/3" is a genuine algorithm-step
 *                             label (tap-vs-hold, erase-then-type, poll loop, …).
 *
 * The allowlist is curated by hand on purpose: any NEW file that wants to use a
 * bare "Phase N" must be reviewed and added here, so the token cannot silently
 * become a backdoor for reintroducing plan refs.
 * ==============================================================================
 */

'use strict';

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

// Files where a bare "Phase N" is a legitimate algorithm-step label (CAT-B),
// not a refactor-plan reference. Verified by reading each site.
const PHASE_ALLOWLIST = new Set([
	'static/ergopti_plus/linux/modules/hotstrings/injector.lua',
	'static/ergopti_plus/macos/platform/remap/ke_lifecycle.lua',
	'static/ergopti_plus/macos/modules/llm/api_mlx_discovery.lua',
	'static/ergopti_plus/macos/tests/unit/modules/keylogger/test_keylogger_privacy.lua',
	'static/ergopti_plus/windows/modules/keylogger/keylogger_webview.ahk',
	'static/ergopti_plus/windows/modules/llm/ollama_deps_checker.ahk',
	'static/ergopti_plus/windows/platform/remap/backspace.ahk',
	'static/ergopti_plus/windows/platform/remap/delete.ahk',
	'static/ergopti_plus/windows/platform/remap/enter.ahk',
	'static/ergopti_plus/windows/platform/remap/escape.ahk',
	'static/ergopti_plus/windows/platform/remap/space.ahk',
	'tools/compact_data_sql.py',
]);

// Tokens that are never legitimate in source, matched everywhere.
const FORBIDDEN = [
	{ re: /\bP\d+(?:-[A-Z])?\.\d+\b/, label: 'plan item (P#.#)' },
	{ re: /\bDL-\d+\b/, label: 'delivery item (DL-#)' },
	{ re: /REFACTOR_GUIDE/, label: 'REFACTOR_GUIDE pointer' },
	{ re: /\bPhase 2B\b/, label: 'plan phase (Phase 2B)' },
	{ re: /\bPhase P\d/, label: 'plan phase (Phase P#)' },
	// A BARE plan token — "P4 entrypoint decomposition", "(P5 refactor)",
	// "(P0 SSoT)", "the P6 split", "(P0-G)". The P#.# rule above missed every one
	// of them because none carries a dot, so 38 of these survived the purge that
	// was supposed to remove them. The plan they point at was consolidated and
	// deleted, so the token is not a reference a reader can follow — it is noise
	// that looks like one. Say what the change WAS instead.
	{ re: /\bP\d+(?:-[A-Z])?\s+(?:refactor|entrypoint|split|SSoT|SSOT|decomposition)\b/i, label: 'bare plan token (P# <word>)' },
	{ re: /\(\s*P\d+(?:-[A-Z])?\s*\)/, label: 'bare plan token ((P#))' },
	{ re: /\(\s*P\d+\/P\d+\s*\)/, label: 'bare plan token ((P#/P#))' },
	{ re: /\bthe P\d+ split\b/i, label: 'bare plan token (the P# split)' },
];
// A bare "Phase <n>" — allowed only in the CAT-B files above.
const BARE_PHASE = /\bPhase \d/;

const SELF = 'tools/test/test-no-plan-refs-in-source.cjs';

const files = execSync('git ls-files', { cwd: ROOT, encoding: 'utf8' })
	.split('\n')
	.filter(Boolean)
	.filter((f) => /\.(lua|ahk|py|cjs|js)$/.test(f))
	.filter((f) => f.startsWith('static/ergopti_plus/') || f.startsWith('tools/'))
	.filter((f) => !f.includes('/_generated/'))
	.filter((f) => f !== SELF); // this file necessarily names the tokens it forbids

const hits = [];
for (const f of files) {
	const abs = path.join(ROOT, f);
	let text;
	try {
		text = fs.readFileSync(abs, 'utf8');
	} catch {
		continue; // deleted/untracked race — skip
	}
	const lines = text.split(/\r?\n/);
	lines.forEach((line, i) => {
		for (const { re, label } of FORBIDDEN) {
			if (re.test(line)) hits.push({ f, ln: i + 1, label, text: line.trim() });
		}
		if (BARE_PHASE.test(line) && !PHASE_ALLOWLIST.has(f)) {
			hits.push({ f, ln: i + 1, label: 'bare "Phase N" (file not on CAT-B allowlist)', text: line.trim() });
		}
	});
}

if (hits.length > 0) {
	console.error(`\x1b[31m[ERROR] ${hits.length} plan-item reference(s) found in tracked source (forbidden by convention):\x1b[0m`);
	for (const h of hits) {
		console.error(`    ${h.f}:${h.ln}  [${h.label}]`);
		console.error(`        ${h.text}`);
	}
	console.error('    Fix: reword the comment to keep the rationale but drop the token. If a bare');
	console.error('    "Phase N" is a genuine algorithm step, add the file to PHASE_ALLOWLIST here.');
	process.exit(1);
}

console.log('\x1b[32m[OK] No plan-item references in tracked source (' + files.length + ' files scanned).\x1b[0m');
