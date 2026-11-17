// tools/test/test-structure-plan-prettier.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Appendix Formatter
 * DESCRIPTION:
 * `npm run audit:structure-plan` writes the plan's Markdown appendices and
 * formats each with Prettier. plan.cjs and shared-literal-inventory.cjs ran
 * node_modules/.bin/prettier.cmd with execFileSync and no shell, which Node
 * refuses on Windows (spawn EINVAL), so the audit failed at its first
 * appendix there. Both now format through format.cjs's prettierWrite, which
 * runs Prettier's own script with Node. This formats a real file through it
 * and pins that neither tool spawns the .bin shim again.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Format = require('../lint/format.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const TOOLS = ['tools/audit/structure/plan.cjs', 'tools/audit/shared-literal-inventory.cjs'];

function run() {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-plan-prettier-'));
	try {
		const file = path.join(dir, 'appendix.md');
		fs.writeFileSync(file, '#   Title\n\n\n\n*   item\n', 'utf8');
		Format.prettierWrite([file]);
		assert.equal(fs.readFileSync(file, 'utf8'), '# Title\n\n- item\n');
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
	for (const rel of TOOLS) {
		const source = fs.readFileSync(path.join(ROOT, rel), 'utf8');
		assert.ok(!/prettier\.cmd|'\.bin'/.test(source), `${rel} spawns the node_modules/.bin shim`);
		assert.ok(source.includes('prettierWrite('), `${rel} formats outside format.cjs`);
	}
	console.log('structure plan appendices format through Prettier on every OS');
}

run();
