// tools/test/fixtures/tis_observation_projection_control.cjs
// Independent held-record projection controls; these do not execute Carbon.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const owner = path.resolve(__dirname, '../../diagnostics/tis_evidence_transport.cjs');
const cliOwner =
	process.platform === 'win32' ? path.join(__dirname, 'tis_fixture_metadata_port.cjs') : owner;
const nonce = 'a'.repeat(64);
const prefix = 'TIS_TEST_OBSERVATION ';
const secret = 'PRIVATE_USER_SECRET_/Users/foreign/secret\n::error::injected';
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const id = (value) => ({ state: 'present', value });
const source = (value, selected = false) => ({
	id: id(value),
	enabled: { state: 'present', value: true },
	selected: { state: 'present', value: selected },
	selectCapable: { state: 'present', value: true }
});
const names = [
	'-[ErgoptiPlusTests.KeyboardCharacterMappingTests testFreshKeyboardEventsFollowLayoutAndShiftFlags]',
	'-[ErgoptiPlusTests.KeyboardSourceProbeTests testActualSelectedSourcesProveDirectPunctuationAndRejectDeadAccent]:com.apple.keylayout.US',
	'-[ErgoptiPlusTests.KeyboardSourceProbeTests testActualSelectedSourcesProveDirectPunctuationAndRejectDeadAccent]:com.apple.keylayout.French',
	'-[ErgoptiPlusTests.KeyboardSourceProbeTests testActualSelectedSourcesProveDirectPunctuationAndRejectDeadAccent]:com.apple.keylayout.French',
	'-[ErgoptiPlusTests.KeyboardSourceProbeTests testShiftAndOptionOnlyGlyphsAreAbsentFromDirectReceipt]:com.apple.keylayout.US',
	'-[ErgoptiPlusTests.KeyboardSourceProbeTests testSourceChangesAreRejectedBeforeAndAfterTranslation]:com.apple.keylayout.US'
];
const phases = [
	'original.capture',
	'target.inventory',
	'enable.before',
	'enable.after',
	'select.before',
	'select.after',
	'body.before',
	'body.after',
	'event.before',
	'event.after',
	'translation.snapshot',
	'probe.before',
	'probe.snapshot',
	'probe.terminalID',
	'probe.after',
	'probe.refused.invalidArguments',
	'probe.refused.sourceChanged',
	'probe.refused.unavailableLayout',
	'probe.refused.translationFailed',
	'probe.refused.invalidUnicode',
	'probe.refused.unclassified',
	'restore.inner.before',
	'restore.inner.after',
	'disable.before',
	'disable.after',
	'restore.outer.before',
	'restore.outer.after'
];
const row = (phase = 'restore.inner.after') => ({
	phase,
	uptime: 123.5,
	status: -50,
	original: source('com.apple.keylayout.ABC'),
	target: source('com.apple.keylayout.US'),
	current: source('com.apple.keylayout.French', true),
	snapshotID: id('com.apple.keylayout.French'),
	keyboardType: 40,
	unicodeDataBytes: 1234
});
const receipt = (test = names[0], events = [row()]) => ({
	version: 1,
	pid: 9123,
	test: id(test),
	events,
	omittedEvents: 0
});
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-tis-observation-control-'));
let serial = 0,
	passed = 0,
	failed = 0;
const results = [];
function publish(receipts) {
	const dir = path.join(root, String(++serial));
	fs.mkdirSync(dir, { mode: 0o700 });
	const start = Buffer.from(
		JSON.stringify({
			version: 1,
			session: nonce,
			producerPID: 9123,
			bundleSHA256: sha(Buffer.from('independent frozen bundle'))
		})
	);
	fs.writeFileSync(path.join(dir, 'start.json'), start, { mode: 0o600 });
	const records = receipts.map((value, index) => {
		const bytes = Buffer.from('TIS_TEST_EVIDENCE ' + JSON.stringify(value) + '\n');
		fs.writeFileSync(
			path.join(dir, 'record-' + String(index + 1).padStart(6, '0') + '.dat'),
			bytes,
			{ mode: 0o600 }
		);
		return { index: index + 1, bytes: bytes.length, sha256: sha(bytes), closed: true };
	});
	fs.writeFileSync(
		path.join(dir, 'manifest.json'),
		JSON.stringify({
			version: 1,
			session: nonce,
			producerPID: 9123,
			bundleSHA256: JSON.parse(start).bundleSHA256,
			startSHA256: sha(start),
			phase: 'closed',
			enrolledCount: records.length,
			records
		}),
		{ mode: 0o600 }
	);
	return dir;
}
function run(dir, extra = {}) {
	const result = spawnSync(process.execPath, [cliOwner, dir, extra.nonce || nonce], {
		encoding: 'utf8',
		maxBuffer: 4 * 1024 * 1024,
		env: {
			...process.env,
			ERGOPTI_TIS_EVIDENCE_DIR: dir,
			ERGOPTI_TIS_EVIDENCE_SESSION: extra.nonce || nonce,
			...(extra.env || {})
		}
	});
	assert.equal(result.error, undefined);
	results.push({ status: result.status, stdout: result.stdout, stderr: result.stderr });
	return result;
}
function observations(result) {
	return result.stdout
		.split('\n')
		.filter((s) => s.startsWith(prefix))
		.map((s) => {
			assert.ok(Buffer.byteLength(s) <= 4096, 'each closed projected line is bounded');
			return JSON.parse(s.slice(prefix.length));
		});
}
function projected(receipts) {
	const result = run(publish(receipts));
	assert.equal(result.status, 0);
	assert.equal(
		result.stdout.split('\n')[0],
		'[OK] Closed TIS diagnostic session: ' + receipts.length + ' records.'
	);
	const data = observations(result);
	assert.ok(data.length > 0, 'the actual CLI exposes held native observations');
	return data;
}
function check(label, body) {
	try {
		body();
		passed++;
		console.log('[PASS] ' + label);
	} catch (error) {
		failed++;
		console.log('[FAIL] ' + label + ': ' + error.message);
	}
}
try {
	check('six real controlled fixture identities and restoration fields survive actual CLI', () => {
		const data = projected(names.map((name) => receipt(name)));
		assert.deepEqual(
			data.filter((r) => r.kind === 'receipt').map((r) => r.test),
			names.map(id)
		);
		const events = data.filter((r) => r.kind === 'event');
		assert.equal(events.length, 6);
		for (const [index, r] of events.entries())
			assert.deepEqual(r, {
				version: 1,
				kind: 'event',
				record: index + 1,
				event: 1,
				phase: 'restore.inner.after',
				status: -50,
				original: source('com.apple.keylayout.ABC'),
				target: source('com.apple.keylayout.US'),
				current: source('com.apple.keylayout.French', true),
				snapshotID: id('com.apple.keylayout.French'),
				keyboardType: 40,
				unicodeDataBytes: 1234
			});
	});
	check('all fixed native observation phases retain indices and ordered source switches', () => {
		const data = projected([receipt(names[0], phases.map(row))]);
		const rows = data.filter((r) => r.kind === 'event');
		assert.deepEqual(
			rows.map((r) => r.phase),
			phases
		);
		assert.deepEqual(
			rows.map((r) => r.event),
			phases.map((_, i) => i + 1)
		);
		assert.equal(rows[0].original.id.value, 'com.apple.keylayout.ABC');
		assert.equal(rows[5].current.id.value, 'com.apple.keylayout.French');
	});
	check('only closed known event and source keys are printed', () => {
		const e = row();
		e.secret = secret;
		e.uptime = 456;
		e.rawLayout = secret;
		e.error = secret;
		for (const key of ['original', 'target', 'current']) {
			e[key].secret = secret;
			e[key].id.secret = secret;
			e[key].enabled.secret = secret;
		}
		e.snapshotID.secret = secret;
		const data = projected([receipt(names[0], [e])]);
		const text = JSON.stringify(data);
		assert.doesNotMatch(text, /PRIVATE|secret|rawLayout|uptime|error|Users/);
		assert.equal(data.find((r) => r.kind === 'event').original.enabled.value, true);
	});
	check('unknown phases are omitted without raw text and explicitly counted', () => {
		const data = projected([receipt(names[0], [row(secret), row()])]);
		assert.equal(data.filter((r) => r.kind === 'event').length, 1);
		assert.equal(data.find((r) => r.kind === 'event').event, 2);
		assert.equal(data.find((r) => r.kind === 'receipt').omittedEvents, 1);
		assert.doesNotMatch(JSON.stringify(data), /PRIVATE|Users|secret|injected/);
	});
	check('unrecognized test identities are redacted with length and digest', () => {
		const data = projected([receipt(secret)]);
		assert.deepEqual(data.find((r) => r.kind === 'receipt').test, {
			state: 'redacted',
			bytes: Buffer.byteLength(secret),
			sha256: sha(Buffer.from(secret))
		});
		assert.doesNotMatch(JSON.stringify(data), /PRIVATE|Users|secret|injected/);
	});
	check('unrecognized source identities cannot smuggle user text or lines', () => {
		const e = row();
		e.original.id = id(secret);
		e.snapshotID = id(secret);
		const data = projected([receipt(names[0], [e])]);
		const r = data.find((x) => x.kind === 'event');
		const expected = {
			state: 'redacted',
			bytes: Buffer.byteLength(secret),
			sha256: sha(Buffer.from(secret))
		};
		assert.deepEqual(r.original.id, expected);
		assert.deepEqual(r.snapshotID, expected);
		assert.doesNotMatch(JSON.stringify(data), /PRIVATE|Users|secret|injected/);
	});
	check('long well-shaped Apple IDs and Unicode identities are redacted', () => {
		for (const value of ['com.apple.keylayout.' + 'a'.repeat(200), 'é'.repeat(512)]) {
			const e = row();
			e.current.id = id(value);
			const r = projected([receipt(names[0], [e])]).find((x) => x.kind === 'event');
			assert.deepEqual(r.current.id, {
				state: 'redacted',
				bytes: Buffer.byteLength(value),
				sha256: sha(Buffer.from(value))
			});
		}
	});
	check('unknown native states remain explicit without invented values', () => {
		const e = row();
		e.current.id = { state: 'oversize' };
		e.current.enabled = { state: 'missing' };
		e.current.selected = { state: 'invalidType' };
		e.current.selectCapable = { state: 'sourceUnavailable' };
		const r = projected([receipt(names[0], [e])]).find((x) => x.kind === 'event');
		assert.deepEqual(r.current, e.current);
	});
	check('optional fields remain absent and extreme valid native numbers stay exact', () => {
		const e = {
			phase: 'restore.outer.after',
			uptime: 1,
			status: -2147483648,
			keyboardType: 4294967295,
			unicodeDataBytes: Number.MAX_SAFE_INTEGER
		};
		const r = projected([receipt(names[0], [e])]).find((x) => x.kind === 'event');
		assert.deepEqual(r, {
			version: 1,
			kind: 'event',
			record: 1,
			event: 1,
			phase: e.phase,
			status: e.status,
			keyboardType: e.keyboardType,
			unicodeDataBytes: e.unicodeDataBytes
		});
	});
	check('native omission count is explicit and never replaced by projected success', () => {
		const r = receipt();
		r.omittedEvents = Number.MAX_SAFE_INTEGER;
		const data = projected([r]);
		const header = data.find((x) => x.kind === 'receipt');
		assert.equal(header.nativeOmittedEvents, Number.MAX_SAFE_INTEGER);
		assert.equal(header.omittedEvents, 0);
		assert.equal(data.at(-1).truncated, true);
		assert.equal(data.at(-1).scope, 'validated-held-record-projection');
		assert.equal(data.at(-1).complete, undefined);
	});
	check(
		'finite eight-record projection preserves all sixty-four events and counts later records',
		() => {
			const data = projected(
				Array.from({ length: 64 }, () =>
					receipt(
						names[0],
						Array.from({ length: 64 }, () => row())
					)
				)
			);
			assert.equal(data.filter((r) => r.kind === 'receipt').length, 8);
			assert.equal(data.filter((r) => r.kind === 'event').length, 512);
			assert.deepEqual(data.at(-1), {
				version: 1,
				kind: 'projection',
				scope: 'validated-held-record-projection',
				validatedRecords: 64,
				projectedRecords: 8,
				omittedRecords: 56,
				truncated: true
			});
			assert.ok(data.length <= 521);
		}
	);
	check('transport nonce and hash never appear in projection', () => {
		const data = projected([receipt()]);
		assert.ok(data.length > 1);
		assert.ok(!JSON.stringify(data).includes(nonce));
		assert.doesNotMatch(JSON.stringify(data), /producerPID|bundleSHA256|session|URL/);
	});
	for (const [label, mutate] of [
		['missing terminal', (d) => fs.unlinkSync(path.join(d, 'manifest.json'))],
		['changed held bytes', (d) => fs.appendFileSync(path.join(d, 'record-000001.dat'), 'x')],
		['foreign directory entry', (d) => fs.writeFileSync(path.join(d, 'secret.txt'), secret)],
		[
			'nonterminal manifest',
			(d) => {
				const p = path.join(d, 'manifest.json');
				const v = JSON.parse(fs.readFileSync(p));
				v.phase = 'publishing';
				fs.writeFileSync(p, JSON.stringify(v));
			}
		]
	])
		check(label + ' retains original CLI refusal with no projected facts', () => {
			const dir = publish([receipt()]);
			mutate(dir);
			const result = run(dir);
			assert.equal(result.status, 1);
			assert.equal(observations(result).length, 0);
			assert.equal(
				result.stderr.trim(),
				'::error::TIS diagnostic session is incomplete or refused'
			);
		});
	check('wrong caller nonce cannot expose facts', () => {
		const r = run(publish([receipt()]), { nonce: 'b'.repeat(64) });
		assert.equal(r.status, 1);
		assert.equal(observations(r).length, 0);
	});
	check('exports retain original exact validator API', () => {
		assert.deepEqual(Object.keys(require(owner)).sort(), ['record', 'validate']);
	});
	check('post-validation file disappearance cannot change held projection', () => {
		const dir = publish([receipt()]);
		const preload = path.join(root, 'unlink-after-census.cjs');
		fs.writeFileSync(
			preload,
			"const fs=require('node:fs');const old=console.log;console.log=function(line){if(String(line).startsWith('[OK] Closed TIS'))fs.unlinkSync(require('node:path').join(process.argv[2],'record-000001.dat'));return old.apply(this,arguments);};\n"
		);
		const result = run(dir, { env: { NODE_OPTIONS: '--require=' + preload } });
		assert.equal(result.status, 0);
		assert.equal(observations(result).find((r) => r.kind === 'event').status, -50);
		assert.equal(fs.existsSync(path.join(dir, 'record-000001.dat')), false);
	});
	check('foreign census callback cannot rewrite prepared projection through JSON hooks', () => {
		const preload = path.join(root, 'serialize-after-census.cjs');
		fs.writeFileSync(
			preload,
			"const old=console.log;console.log=function(line){if(String(line).startsWith('[OK] Closed TIS'))Object.prototype.toJSON=function(){return {secret:'PRIVATE_CALLBACK_SECRET'};};return old.apply(this,arguments);};\n"
		);
		const result = run(publish([receipt()]), { env: { NODE_OPTIONS: '--require=' + preload } });
		assert.equal(result.status, 0);
		assert.equal(observations(result).find((r) => r.kind === 'event').status, -50);
		assert.doesNotMatch(result.stdout, /PRIVATE_CALLBACK_SECRET/);
	});
	check('malformed admitted field candidates retain original refusal before projection', () => {
		for (const change of [
			(e) => {
				e.status = '-50';
			},
			(e) => {
				e.current.enabled.state = 'foreign';
			},
			(e) => {
				e.snapshotID.value = 'a'.repeat(1025);
			}
		]) {
			const e = row();
			change(e);
			const result = run(publish([receipt(names[0], [e])]));
			assert.equal(result.status, 1);
			assert.equal(observations(result).length, 0);
		}
	});
	check('original census output failure retains its original nonzero verdict', () => {
		const preload = path.join(root, 'throw-census.cjs');
		fs.writeFileSync(
			preload,
			"console.log=function(){throw new Error('inert census output failure');};\n"
		);
		const result = run(publish([receipt()]), { env: { NODE_OPTIONS: '--require=' + preload } });
		assert.equal(result.status, 1);
		assert.equal(observations(result).length, 0);
		assert.equal(result.stderr.trim(), '::error::TIS diagnostic session is incomplete or refused');
	});
	check('projection output failure preserves original successful CLI verdict', () => {
		const preload = path.join(root, 'throw-projection.cjs');
		fs.writeFileSync(
			preload,
			"const old=console.log;console.log=function(line){if(String(line).startsWith('TIS_TEST_OBSERVATION '))throw new Error('inert output failure');return old.apply(this,arguments);};\n"
		);
		const result = run(publish([receipt()]), { env: { NODE_OPTIONS: '--require=' + preload } });
		assert.equal(result.status, 0);
		assert.match(result.stdout, /^\[OK\] Closed TIS diagnostic session: 1 records\./);
		assert.doesNotMatch(result.stderr, /inert|error/);
	});
	// Additive delivery controls: all preceding23 controls remain whole.
	const unavailable = 'TIS_TEST_OBSERVATION_UNAVAILABLE primary=admitted observation=UNQUALIFIED';
	function deliveryProbe(body, values = [receipt()]) {
		const preload = path.join(root, 'delivery-' + serial + '.cjs');
		fs.writeFileSync(preload, body + '\n');
		return run(publish(values), { env: { NODE_OPTIONS: '--require=' + preload } });
	}
	const throwSinks =
		"const fs=require('node:fs');const log=console.log;console.log=function(line){if(String(line).startsWith('TIS_TEST_OBSERVATION '))throw new Error('PRIVATE_WRITE_FAILURE');return log.apply(this,arguments);};const write=fs.writeSync;fs.writeSync=function(fd,...args){if(fd===1)throw new Error('PRIVATE_WRITE_FAILURE');return write.call(this,fd,...args);};";
	check('projection delivery exception has explicit bounded unavailable witness', () => {
		const result = deliveryProbe(throwSinks);
		assert.equal(result.status, 0);
		assert.equal(observations(result).length, 0);
		assert.equal(result.stderr.trim(), unavailable);
		assert.doesNotMatch(result.stderr, /PRIVATE_WRITE_FAILURE/);
	});
	check('projection construction failure has explicit unavailable witness', () => {
		const result = deliveryProbe(
			"const stringify=JSON.stringify;JSON.stringify=function(v,...args){if(v&&v.kind==='event')throw new Error('PRIVATE_BUILD_FAILURE');return stringify.call(this,v,...args);};"
		);
		assert.equal(result.status, 0);
		assert.equal(observations(result).length, 0);
		assert.equal(result.stderr.trim(), unavailable);
		assert.doesNotMatch(result.stderr, /PRIVATE_BUILD_FAILURE/);
	});
	check('partial positive writes finish exact held output with actual writer progress', () => {
		const probe = path.join(root, 'partial-progress.json');
		const result = deliveryProbe(
			"const fs=require('node:fs');const native=fs.writeSync;let calls=0;fs.writeSync=function(fd,buffer,offset,length,position){if(fd===1){calls++;if(typeof buffer!=='object')throw new Error('EXPECTED_BYTE_WRITER');return native.call(this,fd,buffer,offset,Math.min(31,length),position);}return native.apply(this,arguments);};process.once('exit',()=>fs.writeFileSync(" +
				JSON.stringify(probe) +
				',JSON.stringify({calls})));'
		);
		assert.equal(result.status, 0);
		assert.equal(result.stderr, '');
		assert.equal(observations(result).find((r) => r.kind === 'event').status, -50);
		assert.ok(
			JSON.parse(fs.readFileSync(probe)).calls > 1,
			'the actual CLI writer completed multiple acknowledged writes'
		);
	});
	for (const progress of [0, -1, 'NaN', 10000000])
		check('invalid write progress ' + progress + ' is unqualified rather than success', () => {
			const result = deliveryProbe(
				"const fs=require('node:fs');const native=fs.writeSync;fs.writeSync=function(fd,...args){if(fd===1)return " +
					progress +
					';return native.call(this,fd,...args);};'
			);
			assert.equal(result.status, 0);
			assert.equal(observations(result).length, 0);
			assert.equal(result.stderr.trim(), unavailable);
		});
	check('lost stderr unavailable witness fails CLI while primary census remains admitted', () => {
		const result = deliveryProbe(
			throwSinks +
				"fs.writeSync=function(){throw new Error('PRIVATE_BOTH_SINKS_FAILURE');};console.error=function(){throw new Error('PRIVATE_BOTH_SINKS_FAILURE');};"
		);
		assert.equal(result.status, 1);
		assert.equal(observations(result).length, 0);
		assert.match(result.stdout, /^\[OK\] Closed TIS diagnostic session: 1 records\./);
		assert.equal(result.stderr, '');
	});
	check('zero-progress stderr cannot silently suppress unavailable qualification', () => {
		const result = deliveryProbe(
			throwSinks +
				"fs.writeSync=function(fd){if(fd===1)throw new Error('PRIVATE_WRITE_FAILURE');return 0;};console.error=function(){};"
		);
		assert.equal(result.status, 1);
		assert.equal(observations(result).length, 0);
		assert.match(result.stdout, /^\[OK\] Closed TIS diagnostic session: 1 records\./);
	});
	check('partial body followed by output refusal never publishes a completion marker', () => {
		const result = deliveryProbe(
			"const fs=require('node:fs');const native=fs.writeSync;let calls=0;fs.writeSync=function(fd,buffer,offset,length,position){if(fd===1){calls++;if(calls===1)return native.call(this,fd,buffer,offset,Math.min(31,length),position);return 0;}return native.apply(this,arguments);};"
		);
		assert.equal(result.status, 0);
		assert.match(result.stdout, /^\[OK\] Closed TIS diagnostic session: 1 records\./);
		assert.doesNotMatch(result.stdout, /"kind":"projection"/);
		assert.equal(result.stderr.trim(), unavailable);
	});
	// Additive backpressure controls: all preceding33 controls remain whole.
	const onceAgain =
		"const fs=require('node:fs');const native=fs.writeSync;let attempted=false;fs.writeSync=function(fd,...args){if(fd===1&&!attempted){attempted=true;const e=new Error('PRIVATE_AGAIN');e.code='EAGAIN';throw e;}return native.call(this,fd,...args);};";
	check('actual remaining bytes complete after temporary stdout backpressure', () => {
		const probe = path.join(root, 'backpressure-callback.json');
		const result = deliveryProbe(
			onceAgain +
				"const nativeWrite=process.stdout.write;let callbacks=0;process.stdout.write=function(buffer,callback){if(Buffer.isBuffer(buffer))return nativeWrite.call(this,buffer,function(error){callbacks++;callback(error);});return nativeWrite.apply(this,arguments);};process.once('exit',()=>fs.writeFileSync(" +
				JSON.stringify(probe) +
				',JSON.stringify({callbacks})));'
		);
		assert.equal(result.status, 0);
		assert.equal(result.stderr, '');
		assert.equal(observations(result).find((r) => r.kind === 'event').status, -50);
		assert.equal(observations(result).at(-1).kind, 'projection');
		assert.equal(JSON.parse(fs.readFileSync(probe)).callbacks, 1);
	});
	check('backpressure callback refusal is explicit without leaking stream errors', () => {
		const result = deliveryProbe(
			onceAgain +
				"const nativeWrite=process.stdout.write;process.stdout.write=function(buffer,callback){if(Buffer.isBuffer(buffer)){const e=new Error('PRIVATE_STREAM_FAILURE');process.nextTick(()=>{callback(e);process.stdout.emit('error',e);});return false;}return nativeWrite.apply(this,arguments);};"
		);
		assert.equal(result.status, 0);
		assert.equal(observations(result).length, 0);
		assert.equal(result.stderr.trim(), unavailable);
		assert.doesNotMatch(result.stderr, /PRIVATE_STREAM_FAILURE|stack|Error:/);
	});
	check('non-backpressure output refusal does not acquire another output authority', () => {
		const probe = path.join(root, 'no-output-retry.json');
		const result = deliveryProbe(
			"const fs=require('node:fs');const native=fs.writeSync;const output=process.stdout.write;let calls=0;fs.writeSync=function(fd,...args){if(fd===1){const e=new Error('PRIVATE_DENIED');e.code='EPERM';throw e;}return native.call(this,fd,...args);};process.stdout.write=function(buffer,...args){if(Buffer.isBuffer(buffer))calls++;return output.call(this,buffer,...args);};process.once('exit',()=>fs.writeFileSync(" +
				JSON.stringify(probe) +
				',JSON.stringify({calls})));'
		);
		assert.equal(result.status, 0);
		assert.equal(observations(result).length, 0);
		assert.equal(result.stderr.trim(), unavailable);
		assert.equal(JSON.parse(fs.readFileSync(probe)).calls, 0);
	});
	// Exact-tail supplement: the preceding36 controls and production remain unchanged.
	check('backpressure after acknowledged prefix sends only exact remaining held bytes', () => {
		const result = deliveryProbe(
			"const fs=require('node:fs');const native=fs.writeSync;let calls=0;fs.writeSync=function(fd,buffer,offset,length,position){if(fd===1){calls++;if(calls===1)return native.call(this,fd,buffer,offset,Math.min(31,length),position);if(calls===2){const e=new Error('PRIVATE_AGAIN');e.code='EAGAIN';throw e;}}return native.apply(this,arguments);};"
		);
		assert.equal(result.status, 0);
		assert.equal(result.stderr, '');
		const data = observations(result);
		assert.equal(data.filter((r) => r.kind === 'event').length, 1);
		assert.equal(data.filter((r) => r.kind === 'receipt').length, 1);
		assert.equal(data.at(-1).kind, 'projection');
		assert.equal(data.find((r) => r.kind === 'event').status, -50);
	});
	// Actual public Writable lifetime supplement; preceding37 controls remain whole.
	const actualWritable =
		onceAgain +
		"const {Writable}=require('node:stream');const stdout=process.stdout.write;const sink=new Writable({write(buffer,encoding,callback){native.call(fs,1,buffer,0,buffer.length,null);callback();this.destroy(new Error('PRIVATE_REAL_WRITABLE_FOLLOWING_ERROR'));}});sink.on('error',error=>process.stdout.emit('error',error));process.stdout.write=function(buffer,callback){if(Buffer.isBuffer(buffer))return sink.write(buffer,callback);return stdout.apply(this,arguments);};";
	check(
		'actual Writable success callback followed by destroy error revokes observation without raw stack',
		() => {
			const result = deliveryProbe(actualWritable);
			assert.equal(result.status, 0);
			assert.equal(result.stderr.trim(), unavailable);
			assert.doesNotMatch(result.stderr, /PRIVATE_REAL_WRITABLE_FOLLOWING_ERROR|Error:|stack/);
			assert.match(result.stdout, /^\[OK\] Closed TIS diagnostic session: 1 records\./);
		}
	);
	check(
		'stdout listener handles multiple later errors after beforeExit with one unavailable witness',
		() => {
			const result = deliveryProbe(
				onceAgain +
					"const stdout=process.stdout.write;let scheduled=false;process.on('beforeExit',()=>{if(scheduled)return;scheduled=true;process.nextTick(()=>{process.stdout.emit('error',new Error('PRIVATE_FIRST_LATE_ERROR'));process.stdout.emit('error',new Error('PRIVATE_SECOND_LATE_ERROR'));});});"
			);
			assert.equal(result.status, 0);
			assert.equal(result.stderr.trim(), unavailable);
			assert.equal(result.stderr.split(unavailable).length - 1, 1);
			assert.doesNotMatch(result.stderr, /PRIVATE_|Error:|stack/);
		}
	);
	// Closed-ID privacy supplement: the preceding39 controls remain whole.
	check('Apple namespace lookalikes remain redacted at every identity field', () => {
		for (const value of [
			'com.apple.keylayout.PrivateUserSecret',
			'com.apple.inputmethod.PrivateUserSecret',
			'com.apple.keylayout.US.PrivateUserSecret',
			'com.apple.keylayout.US\n'
		]) {
			const e = row();
			for (const property of ['original', 'target', 'current']) e[property].id = id(value);
			e.snapshotID = id(value);
			const r = projected([receipt(names[0], [e])]).find((v) => v.kind === 'event');
			const expected = {
				state: 'redacted',
				bytes: Buffer.byteLength(value),
				sha256: sha(Buffer.from(value))
			};
			for (const property of ['original', 'target', 'current'])
				assert.deepEqual(r[property].id, expected);
			assert.deepEqual(r.snapshotID, expected);
			assert.doesNotMatch(JSON.stringify(r), /PrivateUserSecret/);
		}
	});
	// Direct-sync lifetime supplement: the preceding40 controls remain whole.
	const directLateErrors =
		"let scheduled=false;process.on('beforeExit',()=>{if(scheduled)return;scheduled=true;process.nextTick(()=>{process.stdout.emit('error',new Error('PRIVATE_LATE_SYNC_ERROR'));process.stdout.emit('error',new Error('PRIVATE_SECOND_LATE_SYNC_ERROR'));});});";
	check(
		'direct synchronous publication retains listener for multiple beforeExit stdout errors',
		() => {
			const probe = path.join(root, 'direct-late-sync.json');
			const result = deliveryProbe(
				"const fs=require('node:fs');const native=fs.writeSync;let stdoutCalls=0;fs.writeSync=function(fd,...args){if(fd===1)stdoutCalls++;return native.call(this,fd,...args);};process.once('exit',()=>fs.writeFileSync(" +
					JSON.stringify(probe) +
					',JSON.stringify({stdoutCalls})));' +
					directLateErrors
			);
			assert.equal(
				JSON.parse(fs.readFileSync(probe)).stdoutCalls,
				2,
				'both projection writes use the real synchronous writer without EAGAIN'
			);
			assert.equal(result.status, 0);
			assert.equal(observations(result).at(-1).kind, 'projection');
			assert.equal(result.stderr.trim(), unavailable);
			assert.equal(result.stderr.split(unavailable).length - 1, 1);
			assert.doesNotMatch(
				result.stderr,
				/PRIVATE_LATE_SYNC_ERROR|PRIVATE_SECOND_LATE_SYNC_ERROR|Error:|stack/
			);
		}
	);
	check(
		'direct synchronous late error with undeliverable witness fails CLI without raw error',
		() => {
			const result = deliveryProbe(
				"const fs=require('node:fs');const native=fs.writeSync;fs.writeSync=function(fd,...args){if(fd===2)throw new Error('PRIVATE_LATE_WITNESS_FAILURE');return native.call(this,fd,...args);};" +
					directLateErrors
			);
			assert.equal(result.status, 1);
			assert.match(result.stdout, /^\[OK\] Closed TIS diagnostic session: 1 records\./);
			assert.equal(observations(result).at(-1).kind, 'projection');
			assert.equal(result.stderr, '');
		}
	);
	// Natural-retirement ACK supplement: the preceding42 controls remain whole.
	for (const pending of ['body', 'closing']) {
		check(
			'modeled public Writable missing ' + pending + ' ACK retires explicitly unqualified',
			() => {
				const result = deliveryProbe(
					"const fs=require('node:fs');const {Writable}=require('node:stream');const native=fs.writeSync;const stdout=process.stdout.write;let writes=0;fs.writeSync=function(fd,...args){if(fd===1){writes++;if(writes===" +
						(pending === 'body' ? 1 : 2) +
						"){const error=new Error('PRIVATE_MISSING_ACK');error.code='EAGAIN';throw error;}}return native.call(this,fd,...args);};const sink=new Writable({write(buffer,encoding,callback){if(" +
						JSON.stringify(pending) +
						"==='body')native.call(fs,1,buffer,0,buffer.length,null);}});process.stdout.write=function(buffer,callback){if(Buffer.isBuffer(buffer))return sink.write(buffer,callback);return stdout.apply(this,arguments);};"
				);
				assert.equal(result.status, 0);
				assert.match(result.stdout, /^\[OK\] Closed TIS diagnostic session: 1 records\./);
				assert.equal(result.stderr.trim(), unavailable);
				assert.equal(result.stderr.split(unavailable).length - 1, 1);
				assert.doesNotMatch(result.stdout, /"kind":"projection"/);
				assert.doesNotMatch(result.stderr, /PRIVATE_MISSING_ACK|Error:|stack/);
			}
		);
	}
	check('pending ACK retirement with undeliverable witness fails CLI without raw failure', () => {
		const result = deliveryProbe(
			onceAgain +
				"const {Writable}=require('node:stream');const stdout=process.stdout.write;const sink=new Writable({write(buffer,encoding,callback){native.call(fs,1,buffer,0,buffer.length,null);}});process.stdout.write=function(buffer,callback){if(Buffer.isBuffer(buffer))return sink.write(buffer,callback);return stdout.apply(this,arguments);};const prior=fs.writeSync;fs.writeSync=function(fd,...args){if(fd===2)throw new Error('PRIVATE_PENDING_WITNESS_FAILURE');return prior.call(this,fd,...args);};"
		);
		assert.equal(result.status, 1);
		assert.match(result.stdout, /^\[OK\] Closed TIS diagnostic session: 1 records\./);
		assert.doesNotMatch(result.stdout, /"kind":"projection"/);
		assert.equal(result.stderr, '');
	});
} finally {
	if (process.env.ERGOPTI_TIS_CONTROL_RECEIPT)
		fs.writeFileSync(
			process.env.ERGOPTI_TIS_CONTROL_RECEIPT,
			JSON.stringify({ schema: 1, passed, failed, cli: results }, null, 2) + '\n'
		);
	fs.rmSync(root, { recursive: true, force: true });
}
console.log(
	'[OK] Held TIS projection controls: ' +
		passed +
		' passed, ' +
		failed +
		' failed; no Carbon execution.'
);
if (failed) process.exitCode = 1;
