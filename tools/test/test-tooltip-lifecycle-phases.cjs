// tools/test/test-tooltip-lifecycle-phases.cjs

/**
 * ==============================================================================
 * MODULE: Tooltip Lifecycle Phase Contract
 * DESCRIPTION:
 * `_shared/modules/tooltip/lifecycle.js` declares the four-phase surface
 * lifecycle — teardown, suspend, prepare, reveal — and five contract rules about
 * their ordering. `windows/ui/tooltip/helpers.ahk` names it in its header as the
 * canonical list it implements.
 *
 * That was the whole enforcement: a sentence. The mirror was a claim, not a gate,
 * which is the same shape as the `would_fire` docstrings that were the only thing
 * holding a rule the code had already broken once.
 *
 * WHAT IS CHECKED:
 * 1. Every phase the shared module declares is named by the AutoHotkey renderer.
 *    A phase added to the contract that no driver implements is a contract
 *    describing nothing; a phase deleted from the renderer is a lifecycle step
 *    silently skipped.
 * 2. The renderer names no phase the contract does not declare — the list is the
 *    answer to "what are the phases", so a fifth one invented in the driver has
 *    to be declared before it is used.
 * 3. The contract's rules all carry an id and a description, so the file cannot
 *    decay into a list of empty entries that still passes.
 *
 * WHAT IT DELIBERATELY DOES NOT CHECK: macOS. Its renderer is `hs.canvas`-based
 * with a single render/hide pair and no suspend/prepare split — 117 canvas
 * references and zero mentions of three of the four phases. The four-phase
 * lifecycle is a Windows-surface contract that the shared module hosts because
 * that is where cross-driver declarations live, NOT a claim that both drivers
 * implement it. Asserting it against macOS would fail on a difference that is
 * correct.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const LIFECYCLE = path.join(ROOT, 'static/ergopti_plus/_shared/modules/tooltip/lifecycle.js');
const AHK_RENDERER = path.join(ROOT, 'static/ergopti_plus/windows/ui/tooltip/helpers.ahk');

const errors = [];

// Parsed as text, not required: the package is ESM, so a .js file using
// module.exports cannot be loaded by require() — which is exactly why
// test-shared-js-is-loadable.cjs lists this module as spec-only. Reading the
// literal is what makes the gate run at all.
const lifecycleSrc = fs.readFileSync(LIFECYCLE, 'utf8');

const phasesMatch = lifecycleSrc.match(/const PHASES\s*=\s*\[([^\]]*)\]/);
const phases = phasesMatch ? [...phasesMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]) : [];
if (phases.length < 3) {
	errors.push(
		`parsed ${phases.length} phase(s) from PHASES — expected at least 3; the contract is empty or ` +
			'the parser drifted, and a gate over an empty phase list passes forever'
	);
}

// Each rule is `id: '…'` followed by a `description:` whose string may wrap onto
// the next line, so the description is read from the rest of the entry rather
// than from a single line.
const ruleIds = [...lifecycleSrc.matchAll(/\bid:\s*'([^']+)'/g)].map((m) => ({
	id: m[1],
	at: m.index
}));
if (ruleIds.length === 0) {
	errors.push('parsed no ordering rule from lifecycleContract() — the contract is empty or the parser drifted');
}
for (const { id, at } of ruleIds) {
	const rest = lifecycleSrc.slice(at, at + 400);
	const desc = rest.match(/description:\s*'((?:[^'\\]|\\.)*)'/s);
	if (!desc || desc[1].length < 20) {
		errors.push(
			`lifecycle rule "${id}" has no usable description — a rule nobody can read is a rule nobody applies`
		);
	}
}

const src = fs.readFileSync(AHK_RENDERER, 'utf8');
if (src.length < 1000) {
	errors.push(`${path.basename(AHK_RENDERER)} read as ${src.length} bytes — the renderer moved, and this gate measures nothing`);
}

// A phase is "named" when the renderer mentions it as a word, in any case: the
// AHK marks its phases with section comments (`; PREPARE — …`) and function
// names (`_TooltipRevealSurfaces`), and pinning either spelling alone would make
// the gate fail on a rename that changed nothing.
for (const phase of phases) {
	const named = new RegExp(`\\b${phase}\\b`, 'i').test(src);
	if (!named) {
		errors.push(
			`the AutoHotkey renderer names no "${phase}" phase, but the shared contract declares it. ` +
				'Either the step was dropped — a lifecycle phase silently skipped — or it was renamed and ' +
				'the contract was not told.'
		);
	}
}

// The reverse: a phase word the renderer uses that the contract does not know.
// Restricted to the four the contract could plausibly gain, so ordinary English
// in comments does not trip it.
const CANDIDATE_PHASES = ['teardown', 'suspend', 'prepare', 'reveal', 'restore', 'compose', 'commit'];
for (const candidate of CANDIDATE_PHASES) {
	if (phases.includes(candidate)) continue;
	// Only a SECTION-COMMENT or function-name use counts as claiming a phase.
	const asPhase = new RegExp(`(;\\s*${candidate}\\s*[—-]|_Tooltip${candidate}[A-Z])`, 'i').test(src);
	if (asPhase) {
		errors.push(
			`the AutoHotkey renderer marks a "${candidate}" phase that the shared contract does not ` +
				'declare. The contract is the answer to "what are the phases" — declare it there first.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the tooltip lifecycle contract and the renderer disagree:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${phases.length} lifecycle phase(s) (${phases.join(', ')}) are named by the AutoHotkey ` +
		`renderer, and all ${ruleIds.length} ordering rule(s) carry an id and a readable description.\x1b[0m`
);
