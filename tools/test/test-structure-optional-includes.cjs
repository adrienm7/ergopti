// tools/test/test-structure-optional-includes.cjs

/**
 * ==============================================================================
 * MODULE: Structure Step Optional Build Includes
 * DESCRIPTION:
 * windows/infra/bundle.ahk includes the asset inventory the bundle build writes
 * beside its archive: `#Include *i ../build/bundle_inventory.ahk`. The file
 * exists only after a build, so S06, which moved bundle.ahk into
 * core/lifecycle/engine/, recounted its other includes and left this one on
 * core/lifecycle/build/. The optional include then loaded nothing, the compiled
 * exe had no inventory and refused its own bundle at first launch. A moved file's
 * optional include of a path Git ignores inside its driver keeps naming that
 * path; a missing include that is no build output stays as written.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Apply = require('../audit/structure/apply-step.cjs');

const OLD = 'static/ergopti_plus/windows/infra/bundle.ahk';
const NEW = 'static/ergopti_plus/windows/core/lifecycle/engine/bundle.ahk';

function run() {
	const text = [
		'#Include *i ../build/bundle_inventory.ahk',
		'#Include *i ../zz_probe_absent/never_built.ahk',
		''
	].join('\n');
	const out = Apply.rewriteOwnIncludes(text, OLD, NEW, new Map());
	assert.equal(
		out.split('\n')[0],
		'#Include *i ../../../build/bundle_inventory.ahk',
		'the optional build include keeps naming windows/build/'
	);
	assert.equal(
		out.split('\n')[1],
		'#Include *i ../zz_probe_absent/never_built.ahk',
		'a missing include that Git does not ignore is no build output'
	);
	console.log('[OK] a moved file keeps its optional include of a build output.');
}

run();
