// tools/test/test-metrics-heatmap-translation.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Heatmap Scancode-Translation Guard
 * DESCRIPTION:
 * Executes the real _shared/ui/metrics_typing/heatmap_win.js and asserts that
 * both payload shapes the dashboard feeds it end up keyed by Hammerspoon
 * keycodes — the numbering the heatmap geometry is built on.
 *
 * ROOT CAUSE ENCODED:
 * Two independent defects made the historical keyboard heatmap wrong on Windows
 * and Linux, and neither of them threw.
 *
 * 1. Shape. The live "today" blob is a per-app map, but the historical block
 *    produced by the AHK range reader is a single FLAT aggregate
 *    ({ c, w, kc, sc_kb }). index.html pushes BOTH through translate_win_today,
 *    which walked the flat one as if `c`, `w`, `kc` and `sc_kb` were application
 *    names. Every one of them came back unchanged (a token→item map has no
 *    sc_kb field), so the historical scancode data was never translated — and
 *    since app_state.data declares no sc_kb slot, the merge then silently
 *    skipped a source key that had no destination.
 *
 * 2. Numbering. translate_win_bucket seeded its output from `app_bucket.kc`,
 *    "defensive in case both fields happen to be populated". On Windows that
 *    slot is ALWAYS populated, from ngram_keycodes, whose values are Windows
 *    VIRTUAL KEY codes. VK and Hammerspoon keycodes collide numerically without
 *    overlapping in meaning (VK 65 = 'A' lands on HS keycode 65 = keypad
 *    decimal), so the heatmap coloured unrelated cells for every key typed.
 *
 * The combined symptom is a heatmap that always renders SOMETHING — which is
 * exactly why it read as a cosmetic quirk rather than as data going nowhere.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const p = require('path');

const ROOT = p.resolve(__dirname, '..', '..');
const REL = 'static/ergopti_plus/_shared/ui/metrics_typing/heatmap_win.js';
const ABS = p.join(ROOT, REL);

const errors = [];

function check(condition, message) {
	if (!condition) errors.push(message);
}

if (!fs.existsSync(ABS)) {
	errors.push(`${REL}: missing — every PC-scancode dashboard loads this script`);
} else {
	const src = fs.readFileSync(ABS, 'utf8');
	const load = new Function(
		'window',
		`${src}\nreturn { SC_TO_KC, translate_win_bucket, translate_win_today };`
	);
	const api = load({});

	// ── 0. Prerequisites, so no assertion below can pass vacuously ──────────
	const KC_A = api.SC_TO_KC[30];
	const KC_LEFT = api.SC_TO_KC[75];
	check(KC_A === 0, `${REL}: scancode 30 ('a') must map to HS keycode 0, got ${KC_A}`);
	check(
		KC_LEFT !== undefined && api.SC_TO_KC[203] === KC_LEFT,
		`${REL}: scancodes 75 and 203 must both map to the left-arrow keycode`
	);

	// ── 1. The FLAT historical aggregate must be translated ─────────────────
	const hist = api.translate_win_today({
		c: { a: { c: 3 } },
		w: {},
		kc: { 65: { c: 99 } },
		sc_kb: { 30: { c: 7 } }
	});
	check(
		hist && hist.kc && hist.kc[String(KC_A)] && hist.kc[String(KC_A)].c === 7,
		`${REL}: the flat historical block must be translated into kc (expected kc[${KC_A}].c === 7, got ${JSON.stringify(hist && hist.kc)})`
	);
	check(
		hist && hist.c && hist.c.a && hist.c.a.c === 3,
		`${REL}: translating the flat historical block must preserve its other n-gram slots`
	);

	// ── 2. A Windows VK code must never survive into the keycode map ────────
	check(
		hist && hist.kc && hist.kc['65'] === undefined,
		`${REL}: a Windows VIRTUAL KEY code must never survive into kc — the renderer's geometry is keyed by Hammerspoon keycodes, where 65 is the keypad decimal point, not 'A'`
	);

	// ── 3. The per-app today shape still works, and drops VK too ────────────
	const today = api.translate_win_today({
		'chrome.exe': { kc: { 65: { c: 99 } }, sc_kb: { 30: { c: 7 } } }
	});
	const bucket = today && today['chrome.exe'];
	check(
		bucket && bucket.kc && bucket.kc[String(KC_A)] && bucket.kc[String(KC_A)].c === 7,
		`${REL}: the per-app today payload must still be translated per app`
	);
	check(
		bucket && bucket.kc && bucket.kc['65'] === undefined,
		`${REL}: the per-app today payload must drop the Windows VK keycode slot as well`
	);

	// ── 4. Several scancodes may share one physical position ────────────────
	const arrows = api.translate_win_bucket({ sc_kb: { 75: { c: 2 }, 203: { c: 5 } } });
	check(
		arrows && arrows.kc && arrows.kc[String(KC_LEFT)] && arrows.kc[String(KC_LEFT)].c === 7,
		`${REL}: the bare and high-byte forms of one arrow key must sum into a single cell`
	);

	// ── 5. macOS payloads must fall through untouched ───────────────────────
	const mac = { Safari: { kc: { 0: { c: 4 } } } };
	const macOut = api.translate_win_today(mac);
	check(
		macOut['Safari'].kc['0'].c === 4,
		`${REL}: a payload with no sc_kb (macOS) must pass through unchanged`
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Metrics heatmap scancode translation is broken:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] heatmap_win.js translates both the flat historical block and the per-app today block into HS keycodes, and never leaks Windows VK codes.\x1b[0m'
);

// Fixed expectations are declared independently of generator/renderer output.
// Existing translation assertions above remain unchanged and execute first.
const assertMedia = require('node:assert/strict');
const vmMedia = require('node:vm');
const mediaUi = p.join(ROOT, 'static/ergopti_plus/_shared/ui');
const mediaLocaleRoot = p.join(ROOT, 'static/ergopti_plus/_shared/data/locales');
const MEDIA_EXPECTED = [
	['media.play_pause', 'sg_actions.track_play'],
	['media.next_track', 'sg_actions.track_next'],
	['media.previous_track', 'sg_actions.track_prev'],
	['media.brightness_up', 'sg_actions.brightness_up'],
	['media.brightness_down', 'sg_actions.brightness_down']
];
let mediaPassed = 0,
	mediaFailed = 0;
function mediaTest(name, callback) {
	try {
		callback();
		mediaPassed++;
		console.log(`media PASS ${name}`);
	} catch (error) {
		mediaFailed++;
		console.error(`media FAIL ${name}: ${error.stack}`);
	}
}
function mediaFixture() {
	const elements = {
		date_start: { value: '2026-10-13' },
		date_end: { value: '2026-10-13' },
		media_keys_container: { innerHTML: '', hidden: true },
		kc_heatmap_container: { innerHTML: '' }
	};
	const listeners = new Map();
	const document = {
		getElementById: (id) => elements[id] || null,
		addEventListener(type, callback) {
			if (!listeners.has(type)) listeners.set(type, []);
			listeners.get(type).push(callback);
		},
		querySelectorAll: () => [],
		body: { addEventListener() {} }
	};
	const context = vmMedia.createContext({
		console,
		document,
		setTimeout() {},
		clearTimeout() {},
		Date,
		Map,
		Set,
		Number,
		Object,
		Intl,
		requestAnimationFrame(callback) {
			callback();
			return 1;
		},
		cancelAnimationFrame() {}
	});
	context.window = context;
	context.driver_meta = { os: 'mac' };
	for (const file of [
		'dom_utils.js',
		'host_bridge.js',
		'metrics_typing/_generated/keycode_data.js',
		'metrics_typing/state.js',
		'metrics_typing/format.js',
		'metrics_typing/filters.js',
		'metrics_typing/modal.js',
		'metrics_typing/data.js',
		'metrics_typing/charts.js',
		'metrics_typing/table.js',
		'metrics_typing/heatmap_win.js',
		'metrics_typing/main.js'
	]) {
		vmMedia.runInContext(fs.readFileSync(p.join(mediaUi, file), 'utf8'), context, {
			filename: file
		});
	}
	vmMedia.runInContext(
		`app_state.selected_apps = new Set(['Editor']);
		app_state.app_selection_mode = APP_SELECTION_MODE.SUBSET;
		app_state.current_tab = 'kc'; app_state.data.kc = { '74': { count: 9 } };`,
		context
	);
	context._i18n_strings = JSON.parse(fs.readFileSync(p.join(mediaLocaleRoot, 'en.json'), 'utf8'));
	const setManifest = (value) => {
		context.metrics_manifest = value;
		vmMedia.runInContext(
			'app_state.manifest_dates_sorted = Object.keys(window.metrics_manifest).sort();',
			context
		);
	};
	const render = () => vmMedia.runInContext('render_current_tab()', context);
	return {
		context,
		elements,
		setManifest,
		render,
		getData: () => vmMedia.runInContext('JSON.stringify(app_state.data)', context),
		changeLocale(strings) {
			context._i18n_strings = strings;
			for (const callback of listeners.get('i18n:applied') || [])
				callback({ type: 'i18n:applied' });
		},
		select: (apps) => {
			context.__selected = apps;
			vmMedia.runInContext('app_state.selected_apps = new Set(__selected)', context);
		},
		html: () => elements.media_keys_container.innerHTML
	};
}
const mediaHold = { s: 535, n: 3, m: 300, tap: 2, hold: 1 };
function fixedMediaManifest() {
	return {
		'2026-10-13': {
			Editor: {
				chars: 0,
				media_keys: Object.fromEntries(MEDIA_EXPECTED.map(([id], index) => [id, index + 1])),
				media_hold: { 'media.play_pause': { ...mediaHold } }
			}
		}
	};
}
mediaTest('the actual UI loads the generated label data and owns a separate list', () => {
	const html = fs.readFileSync(p.join(mediaUi, 'metrics_typing/index.html'), 'utf8');
	assertMedia.ok(html.includes('id="media_keys_container"'));
	assertMedia.ok(html.indexOf('src="_generated/keycode_data.js"') < html.indexOf('src="table.js"'));
});
mediaTest('renders all five fixed identities through the existing tab entry point', () => {
	const f = mediaFixture();
	f.setManifest(fixedMediaManifest());
	f.render();
	for (const [id, key] of MEDIA_EXPECTED) {
		assertMedia.ok(f.html().includes(`data-media-id="${id}"`));
		assertMedia.ok(f.html().includes(f.context.escapeHtml(f.context._i18n_strings[key])));
	}
	assertMedia.equal((f.html().match(/<li /g) || []).length, 5);
	assertMedia.equal(f.elements.media_keys_container.hidden, false);
});
mediaTest('retains independent hold sums, samples, max and inclusive tap split', () => {
	const f = mediaFixture();
	f.setManifest(fixedMediaManifest());
	f.render();
	assertMedia.ok(f.html().includes('tap: 2 · hold: 1'));
	assertMedia.ok(f.html().includes('535 ms'));
	assertMedia.ok(f.html().includes('178,3 ms'));
	assertMedia.ok(f.html().includes('300 ms'));
});
mediaTest('filters dates and applications without duplicating today live ngrams', () => {
	const f = mediaFixture();
	f.setManifest({
		'2026-10-12': { Editor: { media_keys: { 'media.play_pause': 99 } } },
		'2026-10-13': {
			Editor: { media_keys: { 'media.play_pause': 2 } },
			Other: { media_keys: { 'media.play_pause': 98 } }
		}
	});
	vmMedia.runInContext(
		"app_state.today_live_data = { Editor: { media_keys: { 'media.play_pause': 97 } } }",
		f.context
	);
	f.render();
	assertMedia.ok(f.html().includes('2 keys pressed'));
	assertMedia.ok(
		!f.html().includes('99 keys pressed') &&
			!f.html().includes('98 keys pressed') &&
			!f.html().includes('97 keys pressed')
	);
	f.select([]);
	f.render();
	assertMedia.equal(f.html(), '');
});
mediaTest('unknown and inherited identities never acquire rendered credit', () => {
	const f = mediaFixture();
	const values = Object.create({ 'media.next_track': 99 });
	values['media.play_pause'] = 2;
	values['media.unknown<img src=x>'] = 98;
	values['74'] = 9;
	f.setManifest({ '2026-10-13': { Editor: { media_keys: values } } });
	f.render();
	assertMedia.equal((f.html().match(/<li /g) || []).length, 1);
	assertMedia.ok(f.html().includes('media.play_pause'));
	assertMedia.ok(!f.html().includes('media.next_track'));
	assertMedia.ok(
		!f.html().includes('<img') &&
			!f.html().includes('media.unknown') &&
			!f.html().includes('data-media-id="74"')
	);
});
mediaTest('malformed typed and inconsistent projections do not render partial credit', () => {
	for (const value of ['2', -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
		const f = mediaFixture();
		f.setManifest({ '2026-10-13': { Editor: { media_keys: { 'media.play_pause': value } } } });
		f.render();
		assertMedia.equal(f.html(), '');
	}
	for (const value of [
		[],
		null,
		{ ...mediaHold, n: 2 },
		{ ...mediaHold, s: 299 },
		{ ...mediaHold, keycode: 74 },
		{ ...mediaHold, m: 9223372036855 }
	]) {
		const f = mediaFixture();
		f.setManifest({
			'2026-10-13': {
				Editor: { media_keys: { 'media.play_pause': 2 }, media_hold: { 'media.play_pause': value } }
			}
		});
		f.render();
		assertMedia.equal(f.html(), '');
	}
});
mediaTest('overflow across individually valid app/day cells refuses the identity', () => {
	const f = mediaFixture();
	f.elements.date_start.value = '';
	f.elements.date_end.value = '';
	f.setManifest({
		'2026-10-12': { Editor: { media_keys: { 'media.play_pause': Number.MAX_SAFE_INTEGER } } },
		'2026-10-13': { Editor: { media_keys: { 'media.play_pause': 1 } } }
	});
	f.render();
	assertMedia.equal(f.html(), '');
});
mediaTest('empty projections clear the old list and tolerate missing native payload fields', () => {
	const f = mediaFixture();
	f.setManifest(fixedMediaManifest());
	f.render();
	assertMedia.ok(f.html().includes('<li'));
	for (const app of [{}, { media_keys: {}, media_hold: {} }, { media_keys: [], media_hold: [] }]) {
		f.setManifest({ '2026-10-13': { Editor: app } });
		f.render();
		assertMedia.equal(f.html(), '');
		assertMedia.equal(f.elements.media_keys_container.hidden, true);
	}
});
mediaTest(
	'escapes translated text and refreshes on the actual locale event without data mutation',
	() => {
		const f = mediaFixture();
		const manifest = fixedMediaManifest();
		f.setManifest(manifest);
		f.render();
		const before = JSON.stringify(manifest);
		const strings = {
			...f.context._i18n_strings,
			'sg_actions.track_play': '<img src=x onerror="bad()"> & play',
			'sg_actions.sg_order.header.grp_media': '<script>bad()</script>',
			'onboarding.checklist.tap_hold': '<b>{1}</b> & {2}'
		};
		f.changeLocale(strings);
		assertMedia.ok(
			f.html().includes('&lt;img') &&
				f.html().includes('&lt;script&gt;') &&
				f.html().includes('&lt;b&gt;2&lt;/b&gt;')
		);
		assertMedia.ok(
			!f.html().includes('<img') && !f.html().includes('<script>') && !f.html().includes('<b>')
		);
		assertMedia.equal(JSON.stringify(manifest), before);
	}
);
mediaTest('all 21 existing locale catalogues translate the list without adding locale keys', () => {
	const files = fs.readdirSync(mediaLocaleRoot).filter((file) => file.endsWith('.json'));
	assertMedia.equal(files.length, 21);
	const f = mediaFixture();
	f.setManifest(fixedMediaManifest());
	f.render();
	for (const file of files) {
		const strings = JSON.parse(fs.readFileSync(p.join(mediaLocaleRoot, file), 'utf8'));
		for (const key of [
			...MEDIA_EXPECTED.map(([, key]) => key),
			'sg_actions.sg_order.header.grp_media',
			'onboarding.checklist.tap_hold',
			'ui_typing.unit_keyspressed',
			'ui_apps.col_duration',
			'ui_typing.lbl_total',
			'ui_typing.key_tip_avg_dur',
			'ui_typing.lbl_longest_time'
		]) {
			assertMedia.equal(typeof strings[key], 'string', `${file} must already translate ${key}`);
		}
		f.changeLocale(strings);
		assertMedia.ok(f.html().includes(f.context.escapeHtml(strings['sg_actions.track_play'])), file);
	}
});
mediaTest(
	'preserves numeric buckets, text counts and exact keyboard geometry with media present',
	() => {
		const f = mediaFixture();
		f.setManifest({});
		f.render();
		const before = f.getData();
		const keyboard = f.elements.kc_heatmap_container.innerHTML.replace(
			/hm_[a-z0-9]+_/g,
			'hm_STABLE_'
		);
		f.setManifest(fixedMediaManifest());
		f.render();
		assertMedia.equal(f.getData(), before);
		assertMedia.equal(
			f.elements.kc_heatmap_container.innerHTML.replace(/hm_[a-z0-9]+_/g, 'hm_STABLE_'),
			keyboard
		);
		assertMedia.ok(!f.elements.kc_heatmap_container.innerHTML.includes('media.play_pause'));
	}
);
mediaTest('inherited or missing hold counters cannot acquire native projection credit', () => {
	const inherited = Object.create({ ...mediaHold });
	const partial = { s: 535, n: 3, m: 300, tap: 2 };
	Object.setPrototypeOf(partial, { hold: 1 });
	for (const hold of [inherited, partial, { s: 535, n: 3, m: 300, tap: 2 }]) {
		const f = mediaFixture();
		f.setManifest({
			'2026-10-13': {
				Editor: { media_keys: { 'media.play_pause': 2 }, media_hold: { 'media.play_pause': hold } }
			}
		});
		f.render();
		assertMedia.equal(
			f.html(),
			'',
			'all five typed counter fields must actually belong to the declared row'
		);
	}
});
console.log(`Media rendering: ${mediaPassed} passed, ${mediaFailed} failed.`);
if (mediaFailed) process.exitCode = 1;
