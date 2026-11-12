// tools/test/test-structure-runtime-edit-steps.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Runtime Edits Per Step
 * DESCRIPTION:
 * A runtime edit (rules.cjs RUNTIME_EDITS) rewrites a module name a source
 * builds at run time, such as the macOS startup test's `"modules." .. name`
 * over gestures, keymap, shortcuts and dynamic hotstrings. Those modules move
 * in different steps (S25, S26, S33), so a step that leaves one of them for
 * later has nothing to rewrite yet. Phase 2 once refused S01 on that edit,
 * after writing 2,603 files, because a step judged the edit against modules
 * it does not move: the whole-sequence dry run passed and the first real
 * step stopped half applied.
 *
 * Also pins that apply-step looks for refused references before its first
 * write, so a refused step leaves the tree as it found it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');

/** A moved-module index as references() builds it. */
function moved(entries) {
	return new Map(entries.map(([key, newName]) => [key, ['old.lua', 'new.lua', newName]]));
}

function run() {
	const state = Plan.runtimeEditState;
	const present = new Set(['macos|modules.gestures', 'macos|hotstrings.engine.expander']);

	// The step moves the module to the name the edit writes.
	assert.equal(
		state(
			moved([['macos|modules.gestures', 'gestures.engine']]),
			present,
			'macos',
			'modules.gestures',
			'gestures.engine'
		),
		'moving'
	);
	// A later step moves it: the regression. Before, this read as wrong and refused S01.
	assert.equal(
		state(new Map(), present, 'macos', 'modules.gestures', 'gestures.engine'),
		'pending',
		'a module a later step moves is pending, not a refusal'
	);
	// An earlier step already moved it.
	assert.equal(
		state(new Map(), present, 'macos', 'modules.keymap', 'hotstrings.engine.expander'),
		'moved'
	);
	// The plan sends it elsewhere, or it is gone: a real refusal.
	assert.equal(
		state(
			moved([['macos|modules.gestures', 'gestures.other']]),
			present,
			'macos',
			'modules.gestures',
			'gestures.engine'
		),
		'wrong'
	);
	assert.equal(state(new Map(), present, 'macos', 'modules.absent', 'absent.engine'), 'wrong');

	const source = fs.readFileSync(path.join(__dirname, '../audit/structure/apply-step.cjs'), 'utf8');
	const refusal = source.indexOf('refused reference(s), nothing changed');
	const firstWrite = source.indexOf('fs.writeFileSync');
	assert.ok(refusal > 0, 'apply-step names the refused references before it applies');
	assert.ok(firstWrite > 0, 'apply-step writes the rewritten files');
	assert.ok(refusal < firstWrite, 'the refusal check comes before the first write');
	console.log('[OK] structure runtime edits wait for the step that moves their last module.');
}

run();
