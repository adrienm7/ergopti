// tools/test/test-structure-guard-needles.cjs

/**
 * ==============================================================================
 * MODULE: Structure Step Guard Needles
 * DESCRIPTION:
 * tools/test/test-macos-bundle-payload.cjs pairs each reader with the exact
 * source text it must still contain. S08 to S12 recounted three readers'
 * climbs (a Path(__file__) parents index, a Lua `_base .. "../"` ladder, a
 * Python parent join) and left the quoted needles on the old text, so the
 * guard reported the readers as no longer containing them. A step now
 * carries each quoted needle to its reader's rewritten line, and refuses a
 * needle it cannot place.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Apply = require('../audit/structure/apply-step.cjs');

const READER = 'ergopti_plus/macos/core/zz_probe/reader.py';

function guard(...needles) {
	const list = needles.map((n) => `\t\t'${n.replace(/'/g, "\\'")}'`).join(',\n');
	return `const X = [\n\t{\n\t\treader: '${READER}',\n\t\tneedles: [\n${list}\n\t\t],\n\t\twhy: 'w'\n\t}\n];\n`;
}

function run() {
	const before = [
		'import x',
		'    alias = Path(__file__).resolve().parents[3] / "_shared/ai/alias.py"',
		'    path = Path(__file__).parent / "network/native_http.py"',
		'_logo_path  = _base .. "../../../img/logo/logo_simple.png"',
		'keep()',
		''
	].join('\n');
	const after = [
		'import x',
		'    alias = Path(__file__).resolve().parents[4] / "_shared/ai/alias.py"',
		'    path = Path(__file__).parent.parent / "core/network/adapters/native_http.py"',
		'_logo_path  = _base .. "../../../../../img/logo/logo_simple.png"',
		'keep()',
		''
	].join('\n');
	const texts = (reader) => (reader === READER ? { before, after } : null);
	const text = guard(
		'Path(__file__).resolve().parents[3] / "_shared/ai/alias.py"',
		'Path(__file__).parent / "network/native_http.py"',
		'_base .. "../../../img/logo/logo_simple.png"',
		'keep()'
	);
	const out = Apply.followGuardNeedles(text, texts);
	assert.equal(
		out,
		guard(
			'Path(__file__).resolve().parents[4] / "_shared/ai/alias.py"',
			'Path(__file__).parent.parent / "core/network/adapters/native_http.py"',
			'_base .. "../../../../../img/logo/logo_simple.png"',
			'keep()'
		)
	);
	// A reader the step did not rewrite keeps its needles as written.
	assert.equal(
		Apply.followGuardNeedles(text, () => null),
		text
	);
	// A needle no single rewritten line holds is refused, not guessed.
	const lost = after.replace('    path = ', '    other = ');
	assert.throws(
		() => Apply.followGuardNeedles(text, () => ({ before, after: lost })),
		/has no single rewritten line/
	);
	console.log('[OK] a payload guard quoting its reader follows the reader a step rewrites.');
}

run();
