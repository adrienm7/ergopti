// tools/test/test-logger-scalars-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Logger Scalars Single-Source Guard
 * DESCRIPTION:
 * Ten logger scalars are declared once per driver rather than once. This gate
 * pins every copy to _shared/modules/timings/constants.toml [logger]:
 *
 *   retention_days         14      AHK reads it (LoggerLoadTimings) · Linux reads it ·
 *                                  HS max_age_days (×2)
 *   ring_buffer_size       200     AHK LOGGER_RING_BUFFER_SIZE · HS RING_BUFFER_SIZE ·
 *                                  shared core RING_CAPACITY
 *   dedup_window_ms        5000    AHK LOGGER_DEDUP_WINDOW_MS · HS DEDUP_WINDOW_SEC
 *   flush_interval_ms      500     AHK LOGGER_FLUSH_INTERVAL_MS
 *   repeat_window_ms       600000  AHK LOGGER_REPEAT_WINDOW_MS · shared core
 *                                  REPEAT_WINDOW_SEC (seconds)
 *   repeat_streak_capacity 64      AHK LOGGER_REPEAT_CAPACITY · shared core
 *                                  REPEAT_CAPACITY
 *   ack_retry_ms           500     HS log_transport ACK_RETRY_SEC (seconds)
 *   ack_retry_cap_ms       4000    HS log_transport ACK_RETRY_CAP_SEC (seconds)
 *   stall_fatal_ms         30000   HS log_transport STALL_FATAL_SEC (seconds)
 *   native_slow_batch_ms   500     Swift LoggerDatagramWorker
 *                                  kLoggerSlowBatchThresholdMilliseconds
 *
 * ROOT CAUSE ENCODED — THE DEDUP WINDOW WAS THE BAD ONE:
 * It was not merely duplicated. It existed only as a BARE LITERAL on both
 * sides, in different units: `(_now - _dedup.time) < 5` in macOS seconds, and
 * `… < 5000` in AHK milliseconds. Each site carried a comment asserting it
 * matched the other driver — "The window matches the AHK driver so both drivers
 * dedup identically" and "Mirrors the macOS driver" — and nothing anywhere
 * checked that claim. Two unnamed numbers in two units, each documented as
 * equal to the other, are indistinguishable from two numbers that have drifted.
 * Both are now named constants, and the conversion is asserted here rather than
 * asserted in prose.
 *
 * The retention and ring values matter for a different reason: they are the
 * contract between the logger and the crash reporter (how much history a crash
 * dump contains) and between the logger and the user's disk (how long logs
 * live). A driver quietly keeping 200 lines while another keeps 500 produces
 * crash reports that cannot be compared.
 *
 * CLOSED LOG VOCABULARY:
 * The same gate holds the logger's other shared contract, its words. Every
 * `reason`, `phase`, `[TAG]` and evidence-record field a driver writes must be
 * a member of the closed enums in _shared/core/ports/contracts.json (projected
 * from _shared/modules/logger/vocabulary.json). An unknown value fails: a reason
 * spelt `save_failure` on one driver and `save_failed` on another is two
 * diagnoses of one event, and a log reader filtering for one never sees the
 * other. Prose and runtime-built values cannot be enum members; their count per
 * file is held to tools/lint/log-vocabulary-free-form-baseline.json, which may
 * only go down (`--shrink` writes a lower count back).
 *
 * NOTE — duplication is still duplication:
 * Most of these constants are not yet READ from the registry at runtime; the
 * drivers declare their own. That is tolerable only because this gate locks them
 * to the registry, exactly as test-keystats-timings-single-source.cjs does for
 * the keystats intervals. Wiring the reads is the follow-up, not the guarantee.
 * The retention window is the first one read: Windows and Linux take it from the
 * registry, so the gate asserts the read and forbids a literal coming back.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');
const LogVocabulary = require('../lib/log-vocabulary-scan.cjs');
const { allOutputs } = require('../build/generators.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

const registry = toml.parse(
	fs.readFileSync(path.join(SP, '_shared/modules/timings/constants.toml'), 'utf8')
);

const errors = [];
let vocabularyCount = 0;

if (!registry.logger) {
	console.error(
		'\x1b[31m[ERROR] _shared/modules/timings/constants.toml has no [logger] section.\x1b[0m'
	);
	process.exit(1);
}

function read(rel) {
	return fs.readFileSync(path.join(SP, rel), 'utf8');
}

/**
 * Finds every numeric declaration of `name` in `src` and checks them all.
 * Checking EVERY occurrence rather than the first is the point: the macOS
 * retention default is written twice in one file, and a gate that stopped at
 * the first would have let the second drift freely.
 */
function check(file, name, pattern, expected, note) {
	const src = read(file);
	const found = [...src.matchAll(pattern)];
	if (found.length === 0) {
		errors.push(
			`${file}: no declaration of ${name} found — it was renamed or removed, and this gate ` +
				'silently stopped guarding it'
		);
		return;
	}
	for (const m of found) {
		const value = Number(m[1]);
		if (value !== expected) {
			const line = src.slice(0, m.index).split('\n').length;
			errors.push(
				`${file}:${line}: ${name} is ${value}, registry says ${expected}` +
					(note ? ` (${note})` : '')
			);
		}
	}
}

/**
 * The inverse of check(): asserts a file does NOT hold a scalar, because it
 * delegates to whoever does.
 *
 * A constant that moved out of a driver leaves check() reporting "renamed or
 * removed, and this gate silently stopped guarding it" — which is correct and
 * exactly what it should say. Deleting the check to make that go away is what
 * loses the guarantee: nothing would then object to the constant being pasted
 * back in a month later, next to a delegating call that quietly stops being the
 * source. So the assertion is inverted instead of dropped, and it is the stronger
 * of the two: not "these numbers agree" but "there is only one number".
 *
 * @param {string} file Path relative to static/ergopti_plus.
 * @param {string} name The constant that must not reappear.
 * @param {RegExp} pattern Global regex matching its declaration.
 * @param {string} why What holds the value instead.
 */
function mustNotDeclare(file, name, pattern, why) {
	const src = read(file);
	const found = [...src.matchAll(pattern)];
	for (const m of found) {
		const line = src.slice(0, m.index).split('\n').length;
		errors.push(
			`${file}:${line}: ${name} is declared here again — ${why}. Two copies of one number ` +
				'agree until the day one of them is edited, which is the whole reason this gate exists.'
		);
	}
}

// ── retention_days ──────────────────────────────────────────────────────────

// Windows reads the registry: LOGGER_RETENTION_DAYS starts at the sentinel 0 and
// LoggerLoadTimings assigns it at boot. It used to be the literal 14, a third copy
// of a number Linux already read. Every link of the read is checked, because each
// one failing on its own leaves a driver that purges on the wrong window or not at
// all: the literal coming back, the loader not reading the key, boot not calling
// the loader before LoggerInit, the logger included after boot (its sentinel would
// then zero the loaded value, exactly as test_taphold_timings_load_order.ahk guards
// for the tap-hold constants), and a purge running on the unloaded sentinel, which
// _LoggerPurgeOldLogs reads as "every dated file is expired".
mustNotDeclare(
	'windows/infra/logger.ahk',
	'LOGGER_RETENTION_DAYS',
	/LOGGER_RETENTION_DAYS\s*:=\s*[1-9]\d*/g,
	'LoggerLoadTimings assigns it from [logger] retention_days'
);
{
	const ahk = read('windows/infra/logger.ahk');
	if (!/^global LOGGER_RETENTION_DAYS := 0$/m.test(ahk)) {
		errors.push(
			'windows/infra/logger.ahk: LOGGER_RETENTION_DAYS is no longer declared with the sentinel 0 ' +
				'that LoggerLoadTimings replaces.'
		);
	}
	const loader = /\nLoggerLoadTimings\(\) \{([\s\S]*?)\n\}/.exec(ahk);
	if (
		!loader ||
		!/LOGGER_RETENTION_DAYS := Days/.test(loader[1]) ||
		!/Days := TimingsGet\("logger", "retention_days"\)/.test(loader[1])
	) {
		errors.push(
			'windows/infra/logger.ahk: LoggerLoadTimings no longer assigns LOGGER_RETENTION_DAYS from ' +
				'TimingsGet("logger", "retention_days").'
		);
	}
	const purges = [...ahk.matchAll(/_LoggerPurgeOldLogs\(\w+, LOGGER_RETENTION_DAYS\)/g)];
	const guarded = [
		...ahk.matchAll(
			/if \(LOGGER_RETENTION_DAYS > 0\)\n\t+_LoggerPurgeOldLogs\(\w+, LOGGER_RETENTION_DAYS\)/g
		)
	];
	if (purges.length !== 2 || guarded.length !== purges.length) {
		errors.push(
			`windows/infra/logger.ahk: ${guarded.length} of ${purges.length} retention purge(s) are guarded ` +
				'by LOGGER_RETENTION_DAYS > 0 (expected the boot and the rollover purge, both guarded). An ' +
				'unguarded purge before LoggerLoadTimings deletes every dated log file.'
		);
	}
	const boot = read('windows/infra/boot.ahk');
	const loadAt = boot.indexOf('\nTimingsLoadShared()\n');
	const loaderAt = boot.indexOf('\nLoggerLoadTimings()\n');
	if (loadAt < 0 || loaderAt < 0 || loaderAt < loadAt) {
		errors.push(
			'windows/infra/boot.ahk: LoggerLoadTimings() must be called after TimingsLoadShared(), ' +
				'before LoggerInit purges.'
		);
	}
	const entry = read('windows/ErgoptiPlus.ahk');
	const loggerInclude = entry.indexOf('#Include infra/logger.ahk');
	const bootInclude = entry.indexOf('#Include infra/boot.ahk');
	const init = entry.indexOf('\nLoggerInit()\n');
	if (loggerInclude < 0 || bootInclude < 0 || loggerInclude > bootInclude) {
		errors.push(
			'windows/ErgoptiPlus.ahk: infra/logger.ahk must be included before infra/boot.ahk, or its ' +
				'sentinel re-zeroes the retention LoggerLoadTimings just loaded.'
		);
	}
	if (init < 0 || init < bootInclude) {
		errors.push(
			'windows/ErgoptiPlus.ahk: the boot LoggerInit() must run after infra/boot.ahk has loaded the ' +
				'retention window.'
		);
	}
}
check(
	'macos/infra/logger.lua',
	'max_age_days default',
	/max_age_days\s*=\s*max_age_days\s+or\s+(\d+)/g,
	registry.logger.retention_days,
	'declared twice in this file — both must match'
);
// Linux reads the registry directly rather than declaring a default, so there
// is no literal to pin. What must be checked is that it purges at all: it
// rolled a new pair of files every day and deleted none, so the directory grew
// for the life of the install. A gate over the other two drivers' copies of a
// number cannot see a driver that ignores the number entirely.
{
	const sink = read('linux/infra/logger_sink.lua');
	// Matches the lookup by its arguments, not by one spelling of the call: it
	// travels through pcall, so `Timings.count("logger", "retention_days")` and
	// `pcall(Timings.count, "logger", "retention_days")` are both correct and only
	// one of them has the parentheses.
	if (
		!/Timings\.count/.test(sink) ||
		!/["']logger["'][\s\S]{0,24}["']retention_days["']/.test(sink)
	) {
		errors.push(
			'linux/infra/logger_sink.lua: the retention window is not read ' +
				'from the shared registry — either it purges on a number of its own, which is ' +
				'what this gate exists to prevent, or it does not purge at all.'
		);
	}
	if (!/-mtime/.test(sink)) {
		errors.push(
			'linux/infra/logger_sink.lua: no age-based purge found. ' +
				'Rolling a file per day and deleting none grows the log directory without ' +
				'bound, and nothing else in this driver would ever notice.'
		);
	}
}

// ── ring_buffer_size ────────────────────────────────────────────────────────

check(
	'windows/infra/logger.ahk',
	'LOGGER_RING_BUFFER_SIZE',
	/LOGGER_RING_BUFFER_SIZE\s*:=\s*(\d+)/g,
	registry.logger.ring_buffer_size
);
check(
	'_shared/lua/logger/init.lua',
	'RING_CAPACITY',
	/\bRING_CAPACITY\s*=\s*(\d+)/g,
	registry.logger.ring_buffer_size
);
mustNotDeclare(
	'macos/infra/logger.lua',
	'RING_BUFFER_SIZE',
	/\bRING_BUFFER_SIZE\s*=\s*\d+/g,
	'the macOS driver delegates its ring to the shared core'
);

// ── dedup_window: the same duration, in two units ───────────────────────────

check(
	'windows/infra/logger.ahk',
	'LOGGER_DEDUP_WINDOW_MS',
	/LOGGER_DEDUP_WINDOW_MS\s*:=\s*(\d+)/g,
	registry.logger.dedup_window_ms
);
mustNotDeclare(
	'macos/infra/logger.lua',
	'DEDUP_WINDOW_SEC',
	/\bDEDUP_WINDOW_SEC\s*=\s*\d+/g,
	'the macOS driver delegates its suppression window to the shared core'
);

check(
	'_shared/lua/logger/init.lua',
	'DEDUP_WINDOW_SEC',
	/\bDEDUP_WINDOW_SEC\s*=\s*(\d+)/g,
	registry.logger.dedup_window_ms / 1000,
	'the shared core holds this in SECONDS — the registry value is milliseconds'
);

// The three must not merely each match the registry; they must denote the same
// duration. Stated separately because that is the invariant the comments claim,
// and the one nothing was checking. The shared core joined them on 2026-08-03:
// it had no dedup at all, so adopting it would have removed flood suppression
// from a driver that had it.
{
	const ms = Number(
		(read('windows/infra/logger.ahk').match(/LOGGER_DEDUP_WINDOW_MS\s*:=\s*(\d+)/) || [])[1]
	);
	const sec = Number(
		(read('macos/infra/logger.lua').match(/\bDEDUP_WINDOW_SEC\s*=\s*(\d+)/) || [])[1]
	);
	const coreSec = Number(
		(read('_shared/lua/logger/init.lua').match(/\bDEDUP_WINDOW_SEC\s*=\s*(\d+)/) || [])[1]
	);
	if (Number.isFinite(ms) && Number.isFinite(sec) && ms !== sec * 1000) {
		errors.push(
			`the two dedup windows are different durations: AHK ${ms} ms vs HS ${sec} s (= ${sec * 1000} ms). ` +
				'Both files claim in a comment to mirror the other.'
		);
	}
	if (Number.isFinite(sec) && Number.isFinite(coreSec) && sec !== coreSec) {
		errors.push(
			`the macOS driver and the shared core disagree on the dedup window: ${sec} s vs ${coreSec} s. ` +
				'The core is what macOS is being migrated onto, so a difference here IS the migration failing.'
		);
	}
}

// And the cross-driver corpus must record the same window, or the vectors that
// exercise suppression would be measuring a duration no driver uses.
{
	const corpus = JSON.parse(read('_shared/tests/corpus/logger/behaviour_vectors.json'));
	const windowSec = corpus.dedup && corpus.dedup.window_seconds;
	if (windowSec !== registry.logger.dedup_window_ms / 1000) {
		errors.push(
			`the logger behaviour corpus records a ${windowSec} s dedup window, the registry says ` +
				`${registry.logger.dedup_window_ms / 1000} s. The vectors would exercise a duration nothing uses.`
		);
	}
}

// ── repeat collapsing: window and streak capacity ───────────────────────────
//
// The AutoHotkey logger mirrors the shared core rather than running it, so the
// two declare these values separately, the window in two units. The macOS
// driver runs the core and must not hold a copy of its own.

check(
	'windows/infra/logger.ahk',
	'LOGGER_REPEAT_WINDOW_MS',
	/LOGGER_REPEAT_WINDOW_MS\s*:=\s*(\d+)/g,
	registry.logger.repeat_window_ms
);
check(
	'_shared/lua/logger/init.lua',
	'REPEAT_WINDOW_SEC',
	/\bREPEAT_WINDOW_SEC\s*=\s*(\d+)/g,
	registry.logger.repeat_window_ms / 1000,
	'the shared core holds this in SECONDS — the registry value is milliseconds'
);
check(
	'windows/infra/logger.ahk',
	'LOGGER_REPEAT_CAPACITY',
	/LOGGER_REPEAT_CAPACITY\s*:=\s*(\d+)/g,
	registry.logger.repeat_streak_capacity
);
check(
	'_shared/lua/logger/init.lua',
	'REPEAT_CAPACITY',
	/\bREPEAT_CAPACITY\s*=\s*(\d+)/g,
	registry.logger.repeat_streak_capacity
);
mustNotDeclare(
	'macos/infra/logger.lua',
	'REPEAT_WINDOW_SEC',
	/\bREPEAT_WINDOW_SEC\s*=\s*\d+/g,
	'the macOS driver delegates repeat collapsing to the shared core'
);

// The corpus's expected summaries quote timestamps a window apart, and its
// eviction case fills exactly one table: both are measured against these values.
{
	const corpus = JSON.parse(read('_shared/tests/corpus/logger/behaviour_vectors.json'));
	const section = corpus.repeat || {};
	if (section.window_ms !== registry.logger.repeat_window_ms) {
		errors.push(
			`the logger behaviour corpus records a ${section.window_ms} ms repeat window, the registry says ` +
				`${registry.logger.repeat_window_ms} ms. Its expected summaries would describe a window no driver uses.`
		);
	}
	if (section.capacity !== registry.logger.repeat_streak_capacity) {
		errors.push(
			`the logger behaviour corpus records a repeat capacity of ${section.capacity}, the registry says ` +
				`${registry.logger.repeat_streak_capacity}. Its eviction case would fill a table of the wrong size.`
		);
	}
}

// ── repeat collapsing: which variants are keyed, and the evidence exemption ──
//
// The AutoHotkey logger and the shared core each hold the key-by table of
// spec 4.2. They must collapse exactly the same variants the same way, and the
// evidence record of spec 4.3 must stay outside both: it is an INFO line that
// neither layer may withhold, so it can only be exempt by an explicit flag,
// never by a table entry that someone later "fixes" to match info.
{
	const ahkSrc = read('windows/infra/logger.ahk');
	const ahkMatch = /LOGGER_REPEAT_KEY_BY\s*:=\s*Map\(([\s\S]*?)\)\s*\n/.exec(ahkSrc);
	const coreSrc = read('_shared/lua/logger/init.lua');
	const coreMatch = /local REPEAT_KEY_BY\s*=\s*\{([\s\S]*?)\}/.exec(coreSrc);
	if (!ahkMatch || !coreMatch) {
		errors.push('could not locate LOGGER_REPEAT_KEY_BY (AHK) or REPEAT_KEY_BY (shared core).');
	} else {
		const ahkTable = {};
		for (const m of ahkMatch[1].matchAll(/"(\w+)"\s*,\s*"(\w+)"/g)) {
			ahkTable[m[1] === 'WARNING' ? 'warn' : m[1].toLowerCase()] = m[2];
		}
		const coreTable = {};
		for (const m of coreMatch[1].matchAll(/(\w+)\s*=\s*"(\w+)"/g)) coreTable[m[1]] = m[2];
		if (
			JSON.stringify(Object.entries(ahkTable).sort()) !==
			JSON.stringify(Object.entries(coreTable).sort())
		) {
			errors.push(
				`the AHK repeat key table ${JSON.stringify(ahkTable)} and the shared core's ` +
					`${JSON.stringify(coreTable)} disagree: the two drivers would collapse different lines.`
			);
		}
		if ('evidence' in ahkTable || 'evidence' in coreTable) {
			errors.push(
				'evidence must not appear in a repeat key table: it is exempt by flag (spec 4.3).'
			);
		}
	}
	if (!/_LoggerEmitBody\("INFO", Tag, Msg, _LoggerFormatBody\(Msg, Args\), true\)/.test(ahkSrc)) {
		errors.push(
			'LoggerEvidence must emit through _LoggerEmitBody with the exempt flag set (spec 4.3).'
		);
	}
	if (!/emit_record\(true, "info", module_name, msg, \.\.\.\)/.test(coreSrc)) {
		errors.push(
			'the shared core M.evidence must emit through emit_record with the exempt flag set (spec 4.3).'
		);
	}
	const corpus = JSON.parse(read('_shared/tests/corpus/logger/behaviour_vectors.json'));
	const ids = new Set(((corpus.repeat || {}).cases || []).map((c) => c.id));
	for (const id of [
		'evidence_burst_with_one_template_is_never_collapsed',
		'evidence_identical_to_the_previous_record_is_not_deduplicated',
		'evidence_rerun_later_is_delivered_again',
		'ordinary_lines_sharing_a_template_with_evidence_still_collapse'
	]) {
		if (!ids.has(id)) errors.push(`the logger behaviour corpus lost the evidence case '${id}'.`);
	}
}

// ── flush_interval_ms ───────────────────────────────────────────────────────

check(
	'windows/infra/logger.ahk',
	'LOGGER_FLUSH_INTERVAL_MS',
	/LOGGER_FLUSH_INTERVAL_MS\s*:=\s*(\d+)/g,
	registry.logger.flush_interval_ms
);

// ── native transport ACK policy (macOS only) ────────────────────────────────
//
// The Windows and Linux sinks write synchronously, so only the macOS transport
// waits for an acknowledgement. It cannot read the registry at runtime (the
// registry reader logs through it), so its three copies are pinned here, in
// seconds. The stall budget is the value that decides whether a slow disk is a
// crash, so it must also stay above the backoff cap it is measured against.

const transportSeconds = /\s*=\s*(\d+(?:\.\d+)?)/.source;
check(
	'macos/adapters/log_transport.lua',
	'ACK_RETRY_SEC',
	new RegExp('\\bACK_RETRY_SEC' + transportSeconds, 'g'),
	registry.logger.ack_retry_ms / 1000,
	'the transport holds this in SECONDS — the registry value is milliseconds'
);
check(
	'macos/adapters/log_transport.lua',
	'ACK_RETRY_CAP_SEC',
	new RegExp('\\bACK_RETRY_CAP_SEC' + transportSeconds, 'g'),
	registry.logger.ack_retry_cap_ms / 1000,
	'the transport holds this in SECONDS — the registry value is milliseconds'
);
check(
	'macos/adapters/log_transport.lua',
	'STALL_FATAL_SEC',
	new RegExp('\\bSTALL_FATAL_SEC' + transportSeconds, 'g'),
	registry.logger.stall_fatal_ms / 1000,
	'the transport holds this in SECONDS — the registry value is milliseconds'
);
if (
	!(registry.logger.ack_retry_ms > 0) ||
	!(registry.logger.ack_retry_cap_ms >= registry.logger.ack_retry_ms) ||
	!(registry.logger.stall_fatal_ms > registry.logger.ack_retry_cap_ms)
) {
	errors.push(
		'[logger] ack_retry_ms, ack_retry_cap_ms and stall_fatal_ms must be positive and ordered ' +
			`(got ${registry.logger.ack_retry_ms}, ${registry.logger.ack_retry_cap_ms}, ` +
			`${registry.logger.stall_fatal_ms}): a budget shorter than one resend interval ` +
			'would declare the worker dead before it was ever asked twice.'
	);
}
// The native worker reports its own slow replies to launcher.log; its threshold
// must stay well inside the transport's first resend, or the report would only
// ever describe stalls the transport had already acted on.
check(
	'macos/launcher/Sources/ErgoptiPlus/LoggerDatagramWorker.swift',
	'kLoggerSlowBatchThresholdMilliseconds',
	/\bkLoggerSlowBatchThresholdMilliseconds\s*=\s*(\d+)/g,
	registry.logger.native_slow_batch_ms
);
if (
	!(
		registry.logger.native_slow_batch_ms > 0 &&
		registry.logger.native_slow_batch_ms <= registry.logger.ack_retry_ms
	)
) {
	errors.push(
		`[logger] native_slow_batch_ms (${registry.logger.native_slow_batch_ms}) must be positive and no longer ` +
			`than ack_retry_ms (${registry.logger.ack_retry_ms}): a slower reply has already cost a resend.`
	);
}
mustNotDeclare(
	'macos/adapters/log_transport.lua',
	'MAX_ACK_ATTEMPTS_BEFORE_FAILURE',
	/\bMAX_ACK_ATTEMPTS_BEFORE_FAILURE\s*=\s*\d+/g,
	'a send count made a 1.5 s disk pause fatal; the stall budget is a duration'
);

// ── No bare literal may creep back in ───────────────────────────────────────
//
// The whole failure was an unnamed number. A named constant that some other
// call site bypasses is the same failure wearing a better name.
{
	const hs = read('macos/infra/logger.lua');
	const bare = [...hs.matchAll(/_dedup\.time\)\s*<\s*(\d+)/g)];
	if (bare.length > 0) {
		errors.push(
			'macos/infra/logger.lua compares against the dedup window as a bare literal again — ' +
				'use DEDUP_WINDOW_SEC so the value stays greppable and gate-able'
		);
	}
}

// ── Closed log vocabulary: reasons, phases, tags, evidence fields ───────────

const FREE_FORM_BASELINE = path.join(ROOT, 'tools/lint/log-vocabulary-free-form-baseline.json');
const FREE_FORM_KINDS = ['reason', 'phase'];

/**
 * The vocabulary violations of a scan: unknown members, and free-form counts
 * above or below the baseline.
 * @param {Array<{kind: string, value: string, file: string, line: number, free: boolean}>} hits
 * @param {Object<string, string[]>} enums
 * @param {Object<string, Object<string, number>>} baseline
 * @returns {{unknown: string[], grown: string[], stale: string[], free: Object}}
 */
function vocabularyViolations(hits, enums, baseline) {
	const unknown = [];
	const free = {};
	for (const kind of FREE_FORM_KINDS) free[kind] = {};
	for (const h of hits) {
		if (h.free) {
			if (!FREE_FORM_KINDS.includes(h.kind))
				unknown.push(`${h.file}:${h.line}: free-form ${h.kind} ${JSON.stringify(h.value)}`);
			else free[h.kind][h.file] = (free[h.kind][h.file] || 0) + 1;
			continue;
		}
		if (!Array.isArray(enums[h.kind]) || !enums[h.kind].includes(h.value))
			unknown.push(
				`${h.file}${h.line ? ':' + h.line : ''}: ${h.kind} ${JSON.stringify(h.value)} is not in the closed enum`
			);
	}
	const grown = [];
	const stale = [];
	for (const kind of FREE_FORM_KINDS) {
		const allowed = baseline[kind] || {};
		for (const [file, n] of Object.entries(free[kind]))
			if (n > (allowed[file] || 0))
				grown.push(
					`${file}: ${n} free-form ${kind} literal(s), baseline allows ${allowed[file] || 0}`
				);
		for (const [file, n] of Object.entries(allowed))
			if ((free[kind][file] || 0) < n)
				stale.push(
					`${file}: ${free[kind][file] || 0} free-form ${kind} literal(s), baseline still allows ${n}`
				);
	}
	return { unknown, grown, stale, free };
}

// The comparison must be able to fail before a green result means anything: a
// probe with one unknown reason, one new free-form phase and one retired
// free-form file must produce exactly those three findings.
{
	const probe = vocabularyViolations(
		[
			{ kind: 'reason', value: 'save_failed', file: 'a.lua', line: 1, free: false },
			{ kind: 'reason', value: 'save_failure', file: 'a.lua', line: 2, free: false },
			{ kind: 'phase', value: 'step ', file: 'b.lua', line: 3, free: true },
			{ kind: 'log_tag', value: 'BOOT', file: 'c.lua', line: 4, free: false }
		],
		{ reason: ['save_failed'], phase: [], log_tag: ['BOOT'], evidence_field: [] },
		{ reason: { 'gone.lua': 1 }, phase: {} }
	);
	if (probe.unknown.length !== 1 || probe.grown.length !== 1 || probe.stale.length !== 1)
		errors.push(
			'the closed-vocabulary comparison no longer reports an unknown value, a rise and headroom'
		);
}

{
	const contracts = JSON.parse(read('_shared/core/ports/contracts.json'));
	const vocabulary = JSON.parse(read('_shared/modules/logger/vocabulary.json'));
	const enums = contracts.enums || {};
	for (const kind of LogVocabulary.KINDS) {
		if (JSON.stringify(enums[kind]) !== JSON.stringify(vocabulary[kind]))
			errors.push(
				`contracts.json enums.${kind} differs from _shared/modules/logger/vocabulary.json — run npm run codegen:contracts`
			);
	}
	const { hits, missingFormatters } = LogVocabulary.scanTree(ROOT, {
		generated: new Set(allOutputs()),
		formatters: vocabulary.evidence_record_formatters
	});
	for (const m of missingFormatters)
		errors.push(`declared evidence-record formatter ${m} was not found or writes no field`);
	if (hits.length < 500)
		errors.push(
			`the vocabulary scan found only ${hits.length} literal(s); the scanner stopped matching`
		);
	let baseline = JSON.parse(fs.readFileSync(FREE_FORM_BASELINE, 'utf8'));
	if (process.argv.includes('--shrink')) {
		const { free } = vocabularyViolations(hits, enums, baseline);
		for (const kind of FREE_FORM_KINDS) {
			const lowered = {};
			for (const file of Object.keys(baseline[kind] || {}).sort()) {
				const n = Math.min(free[kind][file] || 0, baseline[kind][file]);
				if (n > 0) lowered[file] = n;
			}
			baseline[kind] = lowered;
		}
		fs.writeFileSync(FREE_FORM_BASELINE, JSON.stringify(baseline, null, '\t') + '\n', 'utf8');
		baseline = JSON.parse(fs.readFileSync(FREE_FORM_BASELINE, 'utf8'));
	}
	const { unknown, grown, stale } = vocabularyViolations(hits, enums, baseline);
	for (const u of unknown)
		errors.push(
			`${u} — use a listed value, or add it deliberately to _shared/modules/logger/vocabulary.json`
		);
	for (const g of grown)
		errors.push(`${g} — use a closed-enum value and put the detail in the message`);
	for (const st of stale)
		errors.push(
			`${st} — lower it with node tools/test/test-logger-scalars-single-source.cjs --shrink`
		);
	vocabularyCount = hits.length;
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] logger scalars have drifted from the shared registry:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	console.error(
		'    Registry: static/ergopti_plus/_shared/modules/timings/constants.toml [logger]'
	);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] all 12 logger scalar declaration(s) across the three drivers match ' +
		'[logger] in the shared timing registry (dedup and repeat windows verified across the s/ms unit split); ' +
		`${vocabularyCount} reason/phase/tag/evidence-field literal(s) inside the closed log vocabulary.\x1b[0m`
);
