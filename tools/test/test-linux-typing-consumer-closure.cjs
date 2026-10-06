// tools/test/test-linux-typing-consumer-closure.cjs

/** Keep the native dashboard fixture's dependency closure exercised portably. */
'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const {
	createTypingConsumer
} = require('../../static/ergopti_plus/linux/tests/hardware/lib/typing_kpi_consumer.cjs');

const root = path.resolve(__dirname, '../..');
// Independent modeled values cover the consumer; Linux CI supplies real SQLite.
const manifest = {
	'2026-10-03': {
		editor: { chars: 20, time: 10000, kc_hold: { 29: { s: 1500, n: 5, m: 600 } } },
		ignored: { chars: 500, time: 10000, kc_hold: { 29: { s: 20000, n: 5, m: 9000 } } }
	}
};
const consumer = createTypingConsumer(root, manifest);
consumer.renderEditor();
assert.equal(
	consumer.element('apps_top_mod_hold').innerHTML,
	'Left Ctrl <span style="color:var(--text-muted);font-weight:400;">300 ms (max 600)</span>'
);
assert.equal(
	consumer.element('apps_val').innerHTML,
	'1<span class="stat-unit">apps actives</span>'
);
consumer.renderNone();
assert.equal(
	consumer.element('apps_val').innerHTML,
	'0<span class="stat-unit">apps actives</span>'
);
assert.equal(consumer.element('apps_details').style.display, 'none');
assert.equal(consumer.element('apps_table_container').innerHTML, '');
// Execute the complete CLI with one explicitly modeled native return boundary.
// This catches missing imports outside the Typing consumer as well.
const fixture = path.join(
	root,
	'static/ergopti_plus/linux/tests/hardware/run_sqlite_kc_hold_consumers.cjs'
);
const proof = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-consumer-closure-'));
const nativeManifest = {
	'2026-10-03': {
		editor: {
			chars: 20,
			time: 10000,
			kc_hold: {
				29: { s: 1500, n: 5, m: 600, tap: 3, hold: 2 },
				42: { s: 70, n: 2, m: 50, tap: 2, hold: 0 }
			}
		}
	}
};
const output = [];
let nativeCalls = 0;
let exitCode;
const terminal = new Error('owned modeled CLI exit');
const actualRequire = createRequire(fixture);
try {
	fs.writeFileSync(path.join(proof, 'manifest.json'), JSON.stringify(nativeManifest));
	vm.runInNewContext(
		fs.readFileSync(fixture, 'utf8'),
		{
			__dirname: path.dirname(fixture),
			require(name) {
				if (name !== 'child_process') return actualRequire(name);
				return {
					spawnSync(runtime, args, options) {
						nativeCalls++;
						assert.equal(runtime, 'luajit');
						assert.deepEqual(Array.from(args), [
							path.join(path.dirname(fixture), 'run_sqlite_kc_hold_projection.lua')
						]);
						assert.equal(options.env.OWNED_READER_PROOF, proof);
						return {
							status: 0,
							stdout: 'Native Reader modifier-hold projection: 12 checks, 0 failures',
							stderr: ''
						};
					}
				};
			},
			process: {
				argv: [process.execPath, fixture, proof],
				env: {},
				exit(code) {
					exitCode = code;
					throw terminal;
				}
			},
			console: {
				log(line) {
					output.push(line);
				},
				error(line) {
					output.push(line);
				}
			}
		},
		{ filename: fixture }
	);
	assert.fail('CLI must terminate explicitly');
} catch (error) {
	if (error !== terminal) throw error;
} finally {
	assert.equal(path.dirname(proof), path.resolve(os.tmpdir()));
	assert.ok(path.basename(proof).startsWith('ergopti-consumer-closure-'));
	fs.rmSync(proof, { recursive: true });
}
assert.equal(nativeCalls, 1);
assert.equal(exitCode, 0, output.join('\n'));
assert.ok(output.includes('Actual shared Apps and Typing consumers: 5 checks, 0 failures'));
console.log('[OK] Actual typing state, selection helpers and KPI consumer remain linked.');
