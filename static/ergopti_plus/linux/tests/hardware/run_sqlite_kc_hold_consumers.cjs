// tests/hardware/run_sqlite_kc_hold_consumers.cjs

/**
 * ==============================================================================
 * MODULE: Native Reader Modifier-Hold Consumer Integration (Linux)
 * DESCRIPTION:
 * Invokes genuine Writer/SQLite/Reader admission, then executes the actual Apps
 * aggregation and Typing KPI functions on that serialized native manifest. The
 * Node VM supplies an explicit DOM/state adapter, not a graphical or physical
 * session. An optional existing output directory retains native evidence.
 * ==============================================================================
 */

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const vm = require('vm');
const root = path.resolve(__dirname, '../../../../../');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const os = require('os');
const childProcess = require('child_process');
const ownedProof =
	process.argv[2] || fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-reader-kc-hold-'));
const retainProof = Boolean(process.argv[2]);
const runtime = process.env.ERGOPTI_READER_TEST_LUA || 'luajit';
const native = childProcess.spawnSync(
	runtime,
	[path.join(__dirname, 'run_sqlite_kc_hold_projection.lua')],
	{
		cwd: path.join(root, 'static/ergopti_plus/linux'),
		env: { ...process.env, OWNED_READER_PROOF: ownedProof },
		encoding: 'utf8'
	}
);
fs.writeFileSync(
	path.join(ownedProof, 'native.log'),
	(native.stdout || '') + (native.stderr || '')
);
if (
	native.error ||
	native.status !== 0 ||
	!/Native Reader modifier-hold projection: 12 checks, 0 failures/.test(native.stdout || '')
) {
	console.error(
		native.error || native.stderr || 'Native Reader proof failed its exact check floor'
	);
	if (!retainProof) fs.rmSync(ownedProof, { recursive: true });
	process.exit(1);
}
const manifest = JSON.parse(fs.readFileSync(path.join(ownedProof, 'manifest.json'), 'utf8'));
const context = vm.createContext({ window: { ManifestData: manifest } });
for (const source of ['host_bridge.js', 'metrics_apps/helpers.js', 'metrics_apps/state.js'])
	vm.runInContext(read('static/ergopti_plus/_shared/ui/' + source), context, { filename: source });
vm.runInContext(
	"currentSelectedDate='2026-10-03';currentPeriod='all';currentCountAwake=true;",
	context
);
const result = context.getAggregatedData();
let checks = 0,
	failures = 0;
for (const [name, fn] of [
	[
		'actual Apps consumer retains duration',
		() => assert.strictEqual(result.apps.editor.kc_hold_sum_ms, 1570)
	],
	[
		'actual Apps consumer retains event count',
		() => assert.strictEqual(result.apps.editor.kc_hold_count, 7)
	],
	[
		'actual Apps rollup retains exact canonical record',
		() =>
			assert.deepStrictEqual(JSON.parse(JSON.stringify(result.rich.kc_hold['29'])), {
				s: 1500,
				n: 5,
				m: 600,
				tap: 3,
				hold: 2
			})
	],
	[
		'consumer retains selected app and both keys',
		() => {
			assert.deepStrictEqual(Object.keys(result.apps), ['editor']);
			assert.deepStrictEqual(Object.keys(result.rich.kc_hold).sort(), ['29', '42']);
		}
	]
]) {
	checks++;
	try {
		fn();
		console.log('PASS ' + name);
	} catch (e) {
		failures++;
		console.error('FAIL ' + name + ': ' + e.message);
	}
}
console.log(`Actual shared Apps consumer: ${checks} checks, ${failures} failures`);

const { createTypingConsumer } = require('./lib/typing_kpi_consumer.cjs');
const typingConsumer = createTypingConsumer(root, manifest);
typingConsumer.renderEditor();

checks++;
try {
	assert.strictEqual(
		typingConsumer.element('apps_top_mod_hold').innerHTML,
		'Left Ctrl <span style="color:var(--text-muted);font-weight:400;">300 ms (max 600)</span>'
	);
	console.log('PASS actual Typing consumer retains modifier hold mean and maximum');
} catch (e) {
	failures++;
	console.error('FAIL actual Typing consumer retains modifier hold mean and maximum: ' + e.message);
}
console.log(`Actual shared Apps and Typing consumers: ${checks} checks, ${failures} failures`);
if (!retainProof) fs.rmSync(ownedProof, { recursive: true });
process.exit(failures ? 1 : 0);
