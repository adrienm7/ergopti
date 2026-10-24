// tools/test/test-log-vocabulary-scan.cjs

/**
 * ==============================================================================
 * MODULE: Log Vocabulary Scanner Tests
 * DESCRIPTION:
 * The census and the closed-enum gate both trust tools/lib/log-vocabulary-scan.cjs.
 * A scanner that silently stopped matching one shape would let that shape
 * escape the enum while both report green, so every shape is pinned here on a
 * synthetic source, together with what must NOT match.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Scan = require('../lib/log-vocabulary-scan.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

/** Scans a snippet and returns "kind:value" (with a "~" for free-form) in order. */
function found(text) {
	return Scan.scanText(text).map((h) => `${h.kind}:${h.value}${h.free ? '~' : ''}`);
}

// ── reason and phase: every assignment, field and comparison shape ──────────

assert.deepEqual(found('return { ok = false, reason = "read_failed" }'), ['reason:read_failed']);
assert.deepEqual(found("emit({ reason: 'too_large' })"), ['reason:too_large']);
assert.deepEqual(found('Reason := "missing"'), ['reason:missing']);
assert.deepEqual(found('if reason == "stale" then'), ['reason:stale']);
assert.deepEqual(found("if (reason !== 'stale') {"), ['reason:stale']);
assert.deepEqual(found('Result["reason"] := "save_failed"'), ['reason:save_failed']);
assert.deepEqual(found('return Map("ok", false, "reason", "release_failed")'), [
	'reason:release_failed'
]);
assert.deepEqual(found('state.phase = "draining"'), ['phase:draining']);
assert.deepEqual(found('Map("phase", "boot")'), ['phase:boot']);

// Free-form: prose and runtime-built values cannot join a closed enum.
assert.deepEqual(found('reason = "unknown error"'), ['reason:unknown error~']);
assert.deepEqual(found('reason = "http_" .. code'), ['reason:http_~']);
assert.deepEqual(found('Reason := "exit_" . Code'), ['reason:exit_~']);
assert.deepEqual(found("reason: 'runtime_failure_' + name"), ['reason:runtime_failure_~']);
// The empty string is the "no reason" sentinel, not prose.
assert.deepEqual(found('reason = ""'), ['reason:']);

// Not vocabulary: other identifiers, plain comparisons of other names, comments.
assert.deepEqual(found('skip_reason = "x"; reasons = "y"; local s = "reason"'), []);
assert.deepEqual(found('-- reason = "only_documented"\n; Reason := "nor_this"'), []);

// ── log tags ────────────────────────────────────────────────────────────────

assert.deepEqual(found('Logger.debug(LOG, "[WARMUP-LOOP] Backend ready.")'), [
	'log_tag:WARMUP-LOOP'
]);
assert.deepEqual(found('LoggerInfo("Boot", "[BOOT] ready in {1} ms", Ms)'), ['log_tag:BOOT']);
assert.deepEqual(found('Logger.info(LOG,\n\t"[BOOT-NUKE] done: %s",\n\toutput)'), [
	'log_tag:BOOT-NUKE'
]);
assert.deepEqual(found('local cmd = "echo \\"[MLX] Server started\\"; "'), ['log_tag:MLX']);
// A placeholder or a lower-case module bracket is not a tag.
assert.deepEqual(found('LoggerWarn("KeyCombinations", "[{1}] names no pair", S)'), []);
assert.deepEqual(found('Logger.info(LOG, "[logger] flushed")'), []);
// Bracketed key names outside a logger call are display text, not tags.
assert.deepEqual(found('local label = "[ENTER]"'), []);

// ── evidence fields ─────────────────────────────────────────────────────────

assert.deepEqual(
	found('Logger.evidence(LOG, "Boot summary: total=%.0fms heap=%dKB stages: %s.", a, b, c)'),
	['evidence_field:total', 'evidence_field:heap']
);
assert.deepEqual(
	found('LoggerEvidence("Perf",\n\t"ctx ahk={1} os={2}"\n\t. " reps={3}", A, B, C)'),
	['evidence_field:ahk', 'evidence_field:os', 'evidence_field:reps']
);
// The same template through an ordinary level is not an evidence record.
assert.deepEqual(found('Logger.info(LOG, "total=%d", n)'), []);

// ── declared formatters ─────────────────────────────────────────────────────

assert.deepEqual(
	Scan.formatterFields(
		'function M.fmt(r)\n\treturn string.format("check=%s verdict=%s", r.c, r.v)\nend\n',
		'M.fmt'
	),
	['check', 'verdict']
);
assert.deepEqual(
	Scan.formatterFields(
		'Fmt(Row) {\n\treturn "scenario=" . Row["s"] . " mode=" . Row["m"]\n}\n',
		'Fmt'
	),
	['scenario', 'mode']
);
assert.equal(Scan.formatterFields('function M.other() end', 'M.fmt'), null);

// Every formatter the vocabulary declares must still resolve to fields.
const vocabulary = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/modules/logger/vocabulary.json'),
		'utf8'
	)
);
assert.ok(vocabulary.evidence_record_formatters.length > 0);
for (const f of vocabulary.evidence_record_formatters) {
	const fields = Scan.formatterFields(fs.readFileSync(path.join(ROOT, f.file), 'utf8'), f.function);
	assert.ok(fields && fields.length > 0, `${f.file}: ${f.function} declares no evidence field`);
}

console.log(
	'[OK] log vocabulary scanner: every reason, phase, tag and evidence-field shape pinned.'
);
