// tools/dev/gen-demo-metrics.cjs

/**
 * ==============================================================================
 * MODULE: Demo Metrics Generator
 * DESCRIPTION:
 * Generates deterministic, plausible synthetic data for the two driver
 * dashboards so they can be embedded on the website without a native host:
 *   - static/demo/metrics_typing_prefetch.json  (metrics_typing dashboard)
 *   - static/demo/metrics_apps_prefetch.json    (metrics_apps dashboard)
 *
 * The blobs follow the exact bridge-less bootstrap contract implemented in
 * _shared/ui/metrics_typing/index.html and _shared/ui/metrics_apps/index.html:
 *
 *   metrics_typing: { metrics_manifest, app_icons, driver_meta, keycode_layout,
 *                     _prefetch_data: { historical, today } }
 *     - historical is the flat n-gram cache produced by the drivers'
 *       readers (KLR_ReadNgrams / sqlite_reader): one dict per tab
 *       (c, bg, tg, qg, pg, hx, hp, w, sc, sc_bg, w_bg, kc), each mapping
 *       token -> { c, t, e, hs, llm, o }.
 *     - today maps app name -> the same per-tab dicts (per-app buckets).
 *     - driver_meta uses os "mac" so the renderer reads kc keycodes directly
 *       (no scancode translation layer involved).
 *
 *   metrics_apps: { metrics_manifest, user_categories, app_icons }
 *     - metrics_manifest maps date -> app -> per-day counters (app_time_ms,
 *       time, chars, hourly, switches_to, sessions, bursts, ...) plus the
 *       _system / _sys pseudo-apps for passive time and system counters.
 *
 * FEATURES & RATIONALE:
 * 1. Deterministic: a seeded LCG replaces Math.random so two runs on the same
 *    day produce byte-identical output (the date anchor is "today" because the
 *    dashboards window their calendars on the current date).
 * 2. Plausible story: ~90 days of French-language typing, 6 500-12 000
 *    keystrokes per weekday, quieter weekends, WPM climbing 45 -> 75, error
 *    rate slowly dropping, hotstring adoption growing over time.
 * 3. Realistic French n-grams: letter/bigram/trigram/word tables follow real
 *    French frequency orderings (e s a i t n r u l o d c ...), so heatmaps,
 *    SFB analysis and the n-gram tables look like genuine French prose.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

// ==============================================
// ==============================================
// ======= 1/ Constants & Seeded PRNG =======
// ==============================================
// ==============================================

// Repo root is two directories up from tools/dev/
const PROJECT_DIR = path.resolve(__dirname, '..', '..');
const OUTPUT_DIR = path.join(PROJECT_DIR, 'static', 'demo');
const TYPING_OUTPUT = path.join(OUTPUT_DIR, 'metrics_typing_prefetch.json');
const APPS_OUTPUT = path.join(OUTPUT_DIR, 'metrics_apps_prefetch.json');

const DAYS_TOTAL = 90; // Length of the demo history window (ends today)
const WPM_START = 45; // Words-per-minute at the start of the story
const WPM_END = 75; // Words-per-minute reached at the end of the story
const WEEKDAY_CHARS_MIN = 6500; // Lower bound of weekday keystroke volume
const WEEKDAY_CHARS_MAX = 12000; // Upper bound of weekday keystroke volume
const WEEKEND_CHARS_FACTOR = 0.3; // Weekend volume relative to weekdays
const WEEKEND_SKIP_PROBABILITY = 0.35; // Chance a weekend day has no typing at all
const TODAY_PARTIAL_FACTOR = 0.45; // Today is a partial day (dashboard opened mid-day)
const ERR_RATE_START = 0.055; // Manual backspace rate at the start of the story
const ERR_RATE_END = 0.028; // Manual backspace rate at the end (precision improves)
const HS_RATE_START = 0.04; // Hotstring output share at the start (adoption grows)
const HS_RATE_END = 0.11; // Hotstring output share at the end
const LLM_RATE_START = 0.002; // LLM output share at the start
const LLM_RATE_END = 0.02; // LLM output share at the end
const HS_AVG_EXPANSION_LEN = 9; // Average characters produced per hotstring trigger
const HS_TRIGGER_LEN = 3; // Average trigger characters consumed per expansion
const HS_ACCEPT_RATE = 0.72; // triggers / suggested ratio for the HS accuracy KPI
const LLM_AVG_EXPANSION_LEN = 60; // Average characters produced per accepted IA completion
const LLM_ACCEPT_RATE = 0.55; // triggers / suggested ratio for the IA accuracy KPI
const WORD_AVG_LEN = 5.8; // Average French word length incl. separator share

// Pause-threshold buckets emitted per app/day. Mirrors the subset of
// UI_PAUSE_BUCKETS_MS that matters visually (the UI default is 5000 ms);
// missing buckets read as 0 through the dashboards' `|| 0` fallbacks.
const SPEED_BUCKET_KEYS = ['1000', '2000', '5000', '10000', '60000'];
// Fraction of keystroke transitions whose inter-key delay is under each bucket
const SPEED_BUCKET_COVERAGE = { 1000: 0.86, 2000: 0.92, 5000: 0.96, 10000: 0.98, 60000: 1.0 };
// Error-delay buckets attached to the hourly rows (precision charts)
const ERROR_BUCKET_KEYS = ['1000', '5000', '10000'];
const ERROR_BUCKET_COVERAGE = { 1000: 0.55, 5000: 0.9, 10000: 0.97 };

// Burst length histogram shape (bucket label -> share of all bursts)
const BURST_LENGTH_SHAPE = {
	1: 0.3,
	5: 0.25,
	10: 0.18,
	20: 0.12,
	50: 0.08,
	100: 0.04,
	200: 0.02,
	500: 0.007,
	'500+': 0.003
};

// LCG parameters (numerical recipes flavour) — good enough for demo jitter
const LCG_MULTIPLIER = 1103515245;
const LCG_INCREMENT = 12345;
const LCG_MODULUS = 0x80000000;
const LCG_SEED = 0x2f6e2b1;

let _lcg_state = LCG_SEED;

/**
 * Returns the next pseudo-random float in [0, 1) from the seeded LCG.
 * @returns {number} Pseudo-random value.
 */
function rnd() {
	_lcg_state = (Math.imul(LCG_MULTIPLIER, _lcg_state) + LCG_INCREMENT) & (LCG_MODULUS - 1);
	return _lcg_state / LCG_MODULUS;
}

/**
 * Returns a pseudo-random float in [lo, hi).
 * @param {number} lo - Inclusive lower bound.
 * @param {number} hi - Exclusive upper bound.
 * @returns {number} Pseudo-random value in the range.
 */
function rand_between(lo, hi) {
	return lo + rnd() * (hi - lo);
}

/**
 * Multiplies a value by a random factor in [1 - spread, 1 + spread].
 * @param {number} value - Base value.
 * @param {number} spread - Relative half-width of the jitter interval.
 * @returns {number} Jittered value.
 */
function jitter(value, spread) {
	return value * (1 + (rnd() * 2 - 1) * spread);
}

/**
 * Returns true with the given probability.
 * @param {number} p - Probability in [0, 1].
 * @returns {boolean} Whether the event fires.
 */
function chance(p) {
	return rnd() < p;
}

/**
 * Rounds probabilistically so small fractional counts survive scaling
 * (e.g. 0.3 becomes 1 thirty percent of the time instead of always 0).
 * @param {number} value - Non-negative fractional count.
 * @returns {number} Integer count.
 */
function stochastic_round(value) {
	const floor = Math.floor(value);
	return floor + (chance(value - floor) ? 1 : 0);
}

/**
 * Formats a Date as a local YYYY-MM-DD string (same convention as the
 * dashboards' get_local_date_string / parseDateKey helpers).
 * @param {Date} d - Date to format.
 * @returns {string} ISO-like local date string.
 */
function format_date_iso(d) {
	const mm = String(d.getMonth() + 1).padStart(2, '0');
	const dd = String(d.getDate()).padStart(2, '0');
	return `${d.getFullYear()}-${mm}-${dd}`;
}

// =============================================
// =============================================
// ======= 2/ French Language Tables =======
// =============================================
// =============================================

// Letter frequencies (relative weights, French prose incl. accents).
// Ordering matters for realism: e s a i t n r u l o d c ...
const LETTER_WEIGHTS = {
	e: 147,
	s: 79,
	a: 76,
	i: 75,
	t: 72,
	n: 71,
	r: 66,
	u: 63,
	l: 55,
	o: 54,
	d: 37,
	c: 32,
	m: 30,
	p: 30,
	é: 19,
	v: 16,
	q: 14,
	f: 11,
	b: 9,
	g: 9,
	h: 7,
	j: 5,
	à: 5,
	x: 4,
	è: 3,
	y: 3,
	ê: 2,
	z: 1.3,
	ç: 1,
	w: 0.7,
	k: 0.7,
	û: 0.5,
	â: 0.5,
	î: 0.4,
	ô: 0.4,
	ù: 0.3
};

// Punctuation / digit frequencies relative to the same letter scale
const PUNCT_WEIGHTS = {
	"'": 12,
	',': 9,
	'.': 8,
	'-': 3,
	'"': 1.5,
	'(': 1.2,
	')': 1.2,
	':': 1.4,
	';': 0.6,
	'!': 0.8,
	'?': 0.9,
	'/': 0.8,
	'=': 0.5,
	_: 0.6,
	'»': 0.2,
	'«': 0.2
};
const DIGIT_WEIGHTS = {
	0: 2.2,
	1: 2.8,
	2: 2.4,
	3: 1.6,
	4: 1.2,
	5: 1.3,
	6: 1,
	7: 0.9,
	8: 1,
	9: 1.1
};

// Top French bigrams (letters only) — weights follow real corpus ordering
const BIGRAM_WEIGHTS = {
	es: 31,
	de: 25,
	le: 22,
	en: 21,
	re: 20,
	nt: 19,
	on: 18,
	er: 17,
	te: 16,
	el: 15,
	an: 14,
	se: 13,
	et: 12,
	la: 12,
	ai: 12,
	it: 11,
	me: 10,
	ou: 10,
	qu: 10,
	em: 9,
	ie: 9,
	ne: 9,
	ra: 8,
	in: 8,
	ur: 8,
	is: 8,
	at: 7,
	eu: 7,
	ti: 7,
	us: 7,
	ns: 7,
	il: 7,
	co: 6,
	tr: 6,
	un: 6,
	ct: 5,
	au: 5,
	si: 5,
	ir: 5,
	om: 5,
	ar: 5,
	ta: 5,
	pa: 5,
	ce: 5,
	du: 5,
	po: 4,
	pr: 4,
	su: 4,
	sa: 4,
	ch: 4,
	ma: 4,
	nd: 4,
	os: 3,
	to: 3,
	na: 3,
	ré: 4,
	és: 4,
	ée: 3,
	ér: 2.5,
	'te ': 0, // Trailing-space variant removed below (weight 0)
	ss: 6,
	ll: 6,
	tt: 3,
	nn: 3,
	mm: 2,
	rr: 2,
	pp: 1.6,
	ff: 1.2,
	ee: 0.5,
	cc: 0.7
};

// Doubled-letter bigrams that the Ergopti ★ repeat key can generate — a share
// of their volume is tagged as hotstring output for the repetitions KPI story
const DOUBLING_KEYS = new Set(['ss', 'll', 'tt', 'nn', 'mm', 'rr', 'pp', 'ff', 'ee', 'cc']);

// Top French trigrams
const TRIGRAM_WEIGHTS = {
	ent: 18,
	les: 12,
	ion: 10,
	que: 10,
	des: 9,
	ait: 8,
	lle: 8,
	men: 7,
	tio: 7,
	ant: 7,
	ons: 7,
	est: 7,
	eur: 6,
	our: 6,
	air: 5,
	ans: 5,
	tre: 5,
	par: 5,
	eme: 5,
	nte: 5,
	ous: 5,
	con: 4,
	com: 4,
	pou: 4,
	dan: 4,
	ine: 4,
	ure: 4,
	ell: 4,
	sur: 3,
	ave: 3,
	iss: 3,
	ndr: 3,
	ém: 0, // Removed below
	att: 2,
	ess: 3,
	res: 4,
	ter: 4,
	era: 3,
	ien: 4,
	son: 3,
	ers: 3,
	ont: 4,
	ais: 3,
	ver: 3,
	cha: 2,
	age: 3,
	ela: 2,
	ort: 2
};

// Top French quadgrams
const QUADGRAM_WEIGHTS = {
	tion: 9,
	ment: 8,
	emen: 7,
	atio: 6,
	elle: 5,
	pour: 5,
	dans: 4,
	aire: 4,
	ille: 4,
	vous: 4,
	nous: 4,
	ette: 3,
	esse: 3,
	onne: 3,
	omme: 3,
	sont: 3,
	tout: 3,
	ndre: 3,
	avec: 3,
	être: 3,
	ions: 3,
	ente: 3,
	ires: 2,
	euse: 2,
	ance: 2,
	ence: 2,
	uste: 1,
	arde: 1
};

// Common French words (relative weights). Includes apostrophes and accents —
// the dashboards handle both. A few "hotstring favourites" get a high hs share.
const WORD_WEIGHTS = {
	de: 350,
	le: 250,
	la: 200,
	et: 180,
	les: 170,
	des: 150,
	un: 140,
	une: 120,
	est: 110,
	que: 100,
	en: 95,
	dans: 80,
	pour: 75,
	qui: 70,
	pas: 65,
	sur: 60,
	avec: 55,
	plus: 50,
	par: 48,
	mais: 45,
	nous: 40,
	vous: 40,
	tout: 38,
	son: 35,
	être: 33,
	faire: 32,
	"c'est": 30,
	comme: 30,
	aussi: 28,
	cette: 26,
	sont: 25,
	était: 24,
	très: 23,
	bien: 22,
	sans: 20,
	deux: 19,
	même: 18,
	alors: 16,
	donc: 15,
	"j'ai": 15,
	après: 14,
	avant: 13,
	temps: 12,
	"n'est": 12,
	jour: 11,
	fois: 10,
	peut: 10,
	"d'un": 10,
	monde: 9,
	toujours: 9,
	code: 8,
	faut: 8,
	"qu'il": 8,
	vraiment: 8,
	quelque: 7,
	beaucoup: 7,
	travail: 6,
	projet: 6,
	merci: 6,
	bonjour: 5,
	fichier: 5,
	fonction: 5,
	données: 5,
	message: 5,
	encore: 5,
	pense: 5,
	chose: 4,
	clavier: 4,
	touche: 4,
	version: 4,
	test: 4,
	demain: 3,
	réunion: 3,
	ligne: 3,
	page: 3,
	texte: 3,
	frappe: 3,
	'aujourd’hui': 3,
	cordialement: 3,
	bientôt: 2,
	ergonomie: 2
};

// Words whose volume is mostly produced by hotstrings (adoption story)
const HS_WORD_SHARE = {
	bonjour: 0.6,
	merci: 0.5,
	cordialement: 0.85,
	toujours: 0.35,
	beaucoup: 0.4,
	'aujourd’hui': 0.7,
	données: 0.3,
	vraiment: 0.3
};

// Consecutive word pairs for the word-bigrams tab (space separator)
const WORD_BIGRAM_WEIGHTS = {
	'de la': 40,
	'à la': 22,
	"de l'": 20,
	'il y': 20,
	'y a': 20,
	'il est': 16,
	'je suis': 14,
	'je ne': 12,
	'ne pas': 12,
	'est un': 11,
	'est une': 9,
	'dans le': 10,
	'dans la': 8,
	'pour le': 9,
	'sur le': 8,
	'que je': 8,
	'que la': 6,
	'et le': 6,
	'il faut': 8,
	'on peut': 7,
	'tout le': 7,
	'le code': 6,
	'le fichier': 5,
	'la fonction': 4,
	'les données': 4,
	'je pense': 5,
	'est très': 4,
	"c'est le": 5,
	"c'est un": 6,
	'merci beaucoup': 3,
	'à bientôt': 2,
	'le projet': 4,
	'du code': 3,
	'la réunion': 2,
	'ce qui': 5,
	'ce que': 6,
	'un peu': 5,
	'en fait': 5
};

// macOS-style shortcut tokens (metrics_typing sc tab). Standalone navigation
// keys are also logged here — the characters tab pulls them in as chips.
const SHORTCUT_WEIGHTS = {
	'cmd+c': 420,
	'cmd+v': 380,
	'cmd+tab': 300,
	'cmd+z': 260,
	'cmd+s': 240,
	'cmd+a': 150,
	'cmd+f': 130,
	'cmd+t': 120,
	'cmd+w': 110,
	'cmd+x': 90,
	'cmd+shift+p': 90,
	'cmd+p': 80,
	'alt+backspace': 85,
	'alt+left': 70,
	'alt+right': 65,
	'cmd+left': 60,
	'cmd+right': 55,
	'ctrl+c': 45,
	'cmd+backspace': 40,
	'cmd+shift+z': 40,
	'cmd+shift+t': 30,
	'ctrl+r': 25,
	left: 900,
	right: 850,
	down: 520,
	up: 500,
	tab: 350,
	escape: 220,
	delete: 60,
	pagedown: 45,
	pageup: 40,
	home: 25,
	end: 25
};

// Consecutive shortcut pairs (U+2192 separator, see table.js rep logic)
const SHORTCUT_BIGRAM_WEIGHTS = {
	'left→left': 300,
	'down→down': 280,
	'up→up': 190,
	'right→right': 240,
	'cmd+c→cmd+v': 120,
	'cmd+tab→cmd+tab': 90,
	'cmd+z→cmd+z': 60,
	'cmd+s→cmd+tab': 45,
	'cmd+v→cmd+s': 30,
	'cmd+c→cmd+t': 20,
	'cmd+shift+p→cmd+p': 15
};

// Reverse map of _shared KEYCODE_NAMES: printable label -> macOS keycode.
// Only keys the heatmap can colour are listed; accented letters have no
// physical key of their own on the reference layout and are omitted.
const CHAR_TO_KEYCODE = {
	a: 0,
	s: 1,
	d: 2,
	f: 3,
	h: 4,
	g: 5,
	z: 6,
	x: 7,
	c: 8,
	v: 9,
	b: 11,
	q: 12,
	w: 13,
	e: 14,
	r: 15,
	y: 16,
	t: 17,
	o: 31,
	u: 32,
	i: 34,
	p: 35,
	l: 37,
	j: 38,
	k: 40,
	n: 45,
	m: 46,
	1: 18,
	2: 19,
	3: 20,
	4: 21,
	6: 22,
	5: 23,
	9: 25,
	7: 26,
	8: 28,
	0: 29,
	';': 41,
	"'": 39,
	',': 43,
	'/': 44,
	'.': 47,
	'-': 27,
	'=': 24
};

// Non-letter keycodes referenced directly when building the kc heatmap dict
const KEYCODE_SPACE = 49;
const KEYCODE_RETURN = 36;
const KEYCODE_BACKSPACE = 51;
const KEYCODE_TAB = 48;
const KEYCODE_SHIFT = 56;
const KEYCODE_CMD = 55;
const KEYCODE_ALT = 58;
const KEYCODE_CTRL = 59;
const KEYCODE_ESCAPE = 53;
const KEYCODE_LEFT = 123;
const KEYCODE_RIGHT = 124;
const KEYCODE_DOWN = 125;
const KEYCODE_UP = 126;

// Modifier keycodes for the kc_hold per-app aggregates (hold-duration KPI)
const KC_HOLD_SPECS = [
	{ kc: String(KEYCODE_SHIFT), mean_ms: 165, max_ms: 700 },
	{ kc: String(KEYCODE_CMD), mean_ms: 260, max_ms: 1100 },
	{ kc: String(KEYCODE_ALT), mean_ms: 210, max_ms: 900 }
];

// Character mix shares (letters / spaces / punctuation / digits / other)
const CHAR_MIX_SHARES = { letter: 0.78, space: 0.15, punct: 0.04, digit: 0.02, other: 0.01 };

// ==========================================
// ==========================================
// ======= 3/ Synthetic Day Model =======
// ==========================================
// ==========================================

// Application roster. Weights drive the keystroke split; foreground_factor
// converts active typing time into foreground time (browsers and music
// players are mostly read/listen, editors are mostly typed-in).
const APP_SPECS = [
	{
		name: 'Visual Studio Code',
		category: 'Developer tools',
		user_category: { type: 'development', score: 2 },
		weight: 0.32,
		presence: 1.0,
		weekend_presence: 0.35,
		foreground_factor: 4,
		delay_factor: 1.12,
		hs_factor: 1.1,
		llm_factor: 1.4,
		hours: [9, 10, 11, 12, 14, 15, 16, 17, 18],
		titles: ['ergopti — data.js', 'ergopti — keylogger.ahk', 'gen-demo-metrics.cjs']
	},
	{
		name: 'Firefox',
		category: 'Productivity',
		user_category: { type: 'general', score: 0 },
		weight: 0.17,
		presence: 1.0,
		weekend_presence: 1.0,
		foreground_factor: 10,
		delay_factor: 0.95,
		hs_factor: 0.6,
		llm_factor: 0.2,
		hours: [9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
		titles: ['Recherche — Mozilla Firefox', 'GitHub — Mozilla Firefox', 'MDN Web Docs']
	},
	{
		name: 'Slack',
		category: 'Social networking',
		user_category: { type: 'social', score: -1 },
		weight: 0.13,
		presence: 0.95,
		weekend_presence: 0.15,
		foreground_factor: 6,
		delay_factor: 0.88,
		hs_factor: 1.3,
		llm_factor: 1.2,
		hours: [9, 10, 11, 12, 14, 15, 16, 17],
		titles: ['#dev-ergopti — Slack', '#général — Slack']
	},
	{
		name: 'Terminal',
		category: 'Developer tools',
		user_category: { type: 'development', score: 2 },
		weight: 0.09,
		presence: 0.9,
		weekend_presence: 0.25,
		foreground_factor: 5,
		delay_factor: 1.05,
		hs_factor: 0.2,
		llm_factor: 0,
		hours: [10, 11, 14, 15, 16, 17, 18],
		titles: []
	},
	{
		name: 'Mail',
		category: 'Productivity',
		user_category: { type: 'productivity', score: 1 },
		weight: 0.1,
		presence: 0.9,
		weekend_presence: 0.4,
		foreground_factor: 5,
		delay_factor: 0.92,
		hs_factor: 1.6,
		llm_factor: 2.0,
		hours: [8, 9, 11, 13, 16, 17],
		titles: []
	},
	{
		name: 'Obsidian',
		category: 'Productivity',
		user_category: { type: 'productivity', score: 1 },
		weight: 0.16,
		presence: 0.8,
		weekend_presence: 0.85,
		foreground_factor: 3.5,
		delay_factor: 0.9,
		hs_factor: 1.2,
		llm_factor: 0.6,
		hours: [8, 9, 12, 13, 19, 20, 21],
		titles: []
	},
	{
		name: 'Spotify',
		category: 'Music',
		user_category: { type: 'music', score: -1 },
		weight: 0.03,
		presence: 0.6,
		weekend_presence: 0.7,
		foreground_factor: 40,
		delay_factor: 1.0,
		hs_factor: 0,
		llm_factor: 0,
		hours: [10, 14, 16],
		titles: []
	}
];

// App-switch affinities (from -> to). Counts scale with day volume so the
// pair-affinity KPI shows a believable editor <-> browser workflow.
const SWITCH_AFFINITIES = [
	{ from: 'Visual Studio Code', to: 'Firefox', per_kchars: 3.2 },
	{ from: 'Firefox', to: 'Visual Studio Code', per_kchars: 3.0 },
	{ from: 'Visual Studio Code', to: 'Terminal', per_kchars: 1.8 },
	{ from: 'Terminal', to: 'Visual Studio Code', per_kchars: 1.7 },
	{ from: 'Slack', to: 'Firefox', per_kchars: 0.9 },
	{ from: 'Firefox', to: 'Slack', per_kchars: 0.9 },
	{ from: 'Mail', to: 'Firefox', per_kchars: 0.5 },
	{ from: 'Obsidian', to: 'Firefox', per_kchars: 0.4 }
];

// Wi-Fi networks for the metrics_apps _sys rollup (top network KPI)
const WIFI_NETWORKS = { 'Livebox-A7F2': 0.8, eduroam: 0.2 };

/**
 * Builds the full internal day model for the whole demo window.
 * Each entry: { date, is_today, wpm, delay_ms, err_rate, apps: [per-app rows] }.
 * @returns {Array<Object>} Ordered list of active days (skipped days omitted).
 */
function build_days() {
	const days = [];
	const today = new Date();
	today.setHours(12, 0, 0, 0);

	for (let i = 0; i < DAYS_TOTAL; i++) {
		const d = new Date(today.getTime() - (DAYS_TOTAL - 1 - i) * 86400000);
		const dow = d.getDay(); // 0 = Sunday, 6 = Saturday
		const is_weekend = dow === 0 || dow === 6;
		const is_today = i === DAYS_TOTAL - 1;

		// Some weekend days have no typing at all — the calendar shows gaps
		if (is_weekend && !is_today && chance(WEEKEND_SKIP_PROBABILITY)) continue;

		const progress = i / (DAYS_TOTAL - 1);
		const wpm = WPM_START + (WPM_END - WPM_START) * progress + rand_between(-2, 2);
		const delay_ms = 60000 / (wpm * 5);
		const err_rate = jitter(ERR_RATE_START + (ERR_RATE_END - ERR_RATE_START) * progress, 0.12);
		const hs_rate = jitter(HS_RATE_START + (HS_RATE_END - HS_RATE_START) * progress, 0.15);
		const llm_rate = jitter(LLM_RATE_START + (LLM_RATE_END - LLM_RATE_START) * progress, 0.3);

		let day_chars = rand_between(WEEKDAY_CHARS_MIN, WEEKDAY_CHARS_MAX);
		if (is_weekend) day_chars *= jitter(WEEKEND_CHARS_FACTOR, 0.3);
		if (is_today) day_chars *= TODAY_PARTIAL_FACTOR;

		// Pick the apps present on this day and normalise their weights
		const present = [];
		let weight_sum = 0;
		APP_SPECS.forEach((spec) => {
			const presence = is_weekend ? spec.weekend_presence : spec.presence;
			if (!chance(presence)) return;
			const w = jitter(spec.weight, 0.35);
			present.push({ spec, w });
			weight_sum += w;
		});
		if (present.length === 0) continue;

		const apps = present.map(({ spec, w }) =>
			build_app_day(
				spec,
				Math.round((day_chars * w) / weight_sum),
				delay_ms,
				err_rate,
				hs_rate,
				llm_rate,
				progress
			)
		);

		days.push({ date: format_date_iso(d), is_today, wpm, delay_ms, err_rate, apps });
	}
	return days;
}

/**
 * Builds one per-app per-day record with every counter both manifest views
 * need. All durations are in milliseconds, all counts are integers.
 * @param {Object} spec - Entry of APP_SPECS.
 * @param {number} chars - Manual characters typed in this app today.
 * @param {number} delay_ms - Mean inter-key delay for the day.
 * @param {number} err_rate - Manual backspace rate for the day.
 * @param {number} hs_rate - Hotstring output share for the day.
 * @param {number} llm_rate - IA output share for the day.
 * @param {number} progress - 0..1 position inside the demo window.
 * @returns {Object} Internal app-day model.
 */
function build_app_day(spec, chars, delay_ms, err_rate, hs_rate, llm_rate, progress) {
	const app_delay = delay_ms * spec.delay_factor;
	const time_ms = Math.round(chars * app_delay);
	const errors = Math.round(chars * err_rate * jitter(1, 0.2));

	// Hotstrings / IA volumes for this app
	const hs_chars = Math.round(chars * hs_rate * spec.hs_factor * jitter(1, 0.25));
	const hs_triggers = Math.round(hs_chars / HS_AVG_EXPANSION_LEN);
	const hs_input_chars = hs_triggers * HS_TRIGGER_LEN;
	const hs_suggested = Math.round(hs_triggers / HS_ACCEPT_RATE);
	const llm_chars = Math.round(chars * llm_rate * spec.llm_factor * jitter(1, 0.4));
	const llm_triggers = Math.round(llm_chars / LLM_AVG_EXPANSION_LEN);
	const llm_input_chars = llm_triggers * 2;
	const llm_suggested = Math.round(llm_triggers / LLM_ACCEPT_RATE);

	// Hourly split across the app's active hours (weights jittered per day)
	const hourly = {};
	let hour_weight_sum = 0;
	const hour_weights = spec.hours.map(() => jitter(1, 0.6)).map((w) => Math.max(0.05, w));
	hour_weights.forEach((w) => (hour_weight_sum += w));
	const app_time_ms = Math.round(time_ms * spec.foreground_factor * jitter(1, 0.2));
	spec.hours.forEach((hour, idx) => {
		const share = hour_weights[idx] / hour_weight_sum;
		const hc = stochastic_round(chars * share);
		if (hc === 0) return;
		const hes = stochastic_round(errors * share);
		const e_buckets = {};
		ERROR_BUCKET_KEYS.forEach((k) => {
			e_buckets[k] = Math.round(hes * ERROR_BUCKET_COVERAGE[k]);
		});
		hourly[String(hour).padStart(2, '0')] = {
			c: hc,
			es: hes,
			e_buckets,
			time_ms: Math.min(3600000, Math.round(app_time_ms * share))
		};
	});

	// Speed buckets: credited transitions and their cumulative active time
	const time_buckets = {};
	const credited_buckets = {};
	SPEED_BUCKET_KEYS.forEach((k) => {
		const credited = Math.round(chars * SPEED_BUCKET_COVERAGE[k]);
		credited_buckets[k] = credited;
		time_buckets[k] = Math.round(credited * app_delay);
	});
	const hs_input_credited_buckets = {};
	const hs_input_time_buckets = {};
	const llm_input_credited_buckets = {};
	const llm_input_time_buckets = {};
	SPEED_BUCKET_KEYS.forEach((k) => {
		if (hs_input_chars > 0) {
			const cr = Math.round(hs_input_chars * SPEED_BUCKET_COVERAGE[k]);
			hs_input_credited_buckets[k] = cr;
			hs_input_time_buckets[k] = Math.round(cr * app_delay);
		}
		if (llm_input_chars > 0) {
			const cr = Math.round(llm_input_chars * SPEED_BUCKET_COVERAGE[k]);
			llm_input_credited_buckets[k] = cr;
			llm_input_time_buckets[k] = Math.round(cr * app_delay);
		}
	});

	// Sessions (block of typing with no 5 min gap)
	const session_count = Math.max(1, Math.round(chars / rand_between(1500, 3000)));
	const session_total_active_ms = Math.round(time_ms * jitter(1.05, 0.05));
	const longest_share = rand_between(0.3, 0.6);
	const session_longest_ms = Math.round(session_total_active_ms * longest_share);
	const session_longest_chars = Math.round(chars * longest_share);
	const session_durations = [];
	let remaining_ms = session_total_active_ms - session_longest_ms;
	session_durations.push(session_longest_ms);
	for (let s = 1; s < session_count; s++) {
		const part =
			s === session_count - 1 ? remaining_ms : Math.round(remaining_ms * rand_between(0.2, 0.6));
		session_durations.push(Math.max(30000, part));
		remaining_ms = Math.max(0, remaining_ms - part);
	}

	// Bursts (no gap > 1 s) — the peak CPM record climbs with progress
	const burst_count = Math.max(1, Math.round(chars / 45));
	const burst_max_chars = Math.round(rand_between(80, 160) + progress * rand_between(120, 260));
	const burst_max_cpm = Math.round((60000 / delay_ms) * rand_between(1.45, 1.9));
	const inter_count = Math.round(chars * 0.85);
	const inter_std = app_delay * 0.55;
	const burst_length_buckets = {};
	Object.entries(BURST_LENGTH_SHAPE).forEach(([bucket, share]) => {
		const n = stochastic_round(burst_count * share);
		if (n > 0) burst_length_buckets[bucket] = n;
	});

	// Error recovery / cascades
	const cascade_count = Math.round(errors / 7);
	const recovery_count = cascade_count;

	// Focus changes into this app (used for focus latency and switches)
	const focus_count = Math.max(1, Math.round(rand_between(4, 18)));

	// kc_hold per modifier — counts scale with volume
	const kc_hold = {};
	KC_HOLD_SPECS.forEach(({ kc, mean_ms, max_ms }) => {
		const n = Math.max(3, Math.round(chars * rand_between(0.015, 0.045)));
		const mean = jitter(mean_ms, 0.15);
		kc_hold[kc] = {
			s: Math.round(n * mean),
			n,
			m: Math.round(jitter(max_ms, 0.25)),
			tap: Math.round(n * 0.7),
			hold: Math.round(n * 0.3)
		};
	});

	// Character mix
	const char_mix = {};
	Object.entries(CHAR_MIX_SHARES).forEach(([kind, share]) => {
		char_mix[kind] = Math.round(chars * jitter(share, 0.1));
	});

	// First / last typed minute derived from the app's active hours
	const first_hour = spec.hours[0];
	const last_hour = spec.hours[spec.hours.length - 1];
	const fmt_min = (h, m) => `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;

	return {
		spec,
		chars,
		time_ms,
		think_time_ms: Math.round(time_ms * rand_between(0.4, 0.8)),
		app_time_ms,
		errors,
		hs_chars,
		hs_triggers,
		hs_input_chars,
		hs_suggested,
		llm_chars,
		llm_triggers,
		llm_input_chars,
		llm_suggested,
		hourly,
		time_buckets,
		credited_buckets,
		hs_input_credited_buckets,
		hs_input_time_buckets,
		llm_input_credited_buckets,
		llm_input_time_buckets,
		session_count,
		session_total_active_ms,
		session_longest_ms,
		session_longest_chars,
		session_durations,
		burst_count,
		burst_max_chars,
		burst_max_cpm,
		inter_count,
		inter_sum: Math.round(inter_count * app_delay),
		inter_sumsq: Math.round(inter_count * (app_delay * app_delay + inter_std * inter_std)),
		burst_length_buckets,
		cascade_count,
		cascade_max_len: cascade_count > 0 ? Math.round(rand_between(3, 7)) : 0,
		recovery_count,
		recovery_sum_ms: Math.round(recovery_count * rand_between(500, 900)),
		focus_count,
		focus_sum_ms: Math.round(focus_count * rand_between(600, 1200)),
		same_finger_streak_max: Math.round(rand_between(3, 6)),
		same_hand_streak_max: Math.round(rand_between(7, 13)),
		auto_repeat_count: Math.round(chars * 0.004),
		kc_hold,
		char_mix,
		first_typed_min: fmt_min(first_hour, Math.round(rand_between(0, 55))),
		last_typed_min: fmt_min(last_hour, Math.round(rand_between(0, 55)))
	};
}

// =================================================
// =================================================
// ======= 4/ N-Gram Dictionary Builders =======
// =================================================
// =================================================

/**
 * Creates one n-gram item in the driver reader shape.
 * @param {number} c - Total occurrence count.
 * @param {number} t - Summed inter-key time in ms (0 when not tracked).
 * @param {number} e - Error (backspace-after) count.
 * @param {number} hs - Hotstring-generated share of c.
 * @param {number} llm - IA-generated share of c.
 * @returns {Object} Item { c, t, e, hs, llm, o }.
 */
function ngram_item(c, t, e, hs, llm) {
	return { c, t, e, hs: hs || 0, llm: llm || 0, o: 0 };
}

/**
 * Scales a weight table into an n-gram dict of the reader shape.
 * @param {Object} weights - token -> relative weight (0 weights are skipped).
 * @param {number} total - Target total occurrence count across the dict.
 * @param {Object} opts - { delay_ms, err_rate, hs_share(token), llm_share }.
 * @returns {Object} token -> item dict.
 */
function build_dict(weights, total, opts) {
	const out = {};
	let weight_sum = 0;
	Object.values(weights).forEach((w) => (weight_sum += w));
	Object.entries(weights).forEach(([token, w]) => {
		if (w <= 0) return;
		const c = Math.max(
			1,
			Math.round((total * w) / weight_sum) +
				Math.round(jitter(0, 1) * Math.sqrt((total * w) / weight_sum) * 0.1)
		);
		const hs_share = opts.hs_share ? opts.hs_share(token) : 0;
		const llm_share = opts.llm_share || 0;
		const hs = Math.round(c * hs_share);
		const llm = Math.round(c * llm_share);
		const t = opts.delay_ms ? Math.round(c * jitter(opts.delay_ms, 0.25)) : 0;
		const e = opts.err_rate ? stochastic_round(c * opts.err_rate * jitter(1, 0.5)) : 0;
		out[token] = ngram_item(c, t, e, hs, llm);
	});
	return out;
}

/**
 * Builds the flat historical n-gram cache covering the whole demo window.
 * @param {Object} totals - Aggregates from the day model (chars, errors, hs...).
 * @param {number} avg_delay_ms - Mean inter-key delay over the window.
 * @returns {Object} Flat per-tab dict cache.
 */
function build_historical(totals, avg_delay_ms) {
	const letters_total = Math.round(totals.chars * CHAR_MIX_SHARES.letter);
	const hs_letter_share = totals.hs_chars / Math.max(1, totals.chars);
	const llm_letter_share = totals.llm_chars / Math.max(1, totals.chars);

	// Characters tab — letters, then punctuation / digits / control markers
	const c_dict = build_dict(LETTER_WEIGHTS, letters_total, {
		delay_ms: avg_delay_ms,
		err_rate: totals.errors / Math.max(1, totals.chars),
		hs_share: () => jitter(hs_letter_share, 0.3),
		llm_share: llm_letter_share
	});
	Object.assign(
		c_dict,
		build_dict(PUNCT_WEIGHTS, Math.round(totals.chars * CHAR_MIX_SHARES.punct), {
			delay_ms: avg_delay_ms * 1.35,
			err_rate: 0.02
		}),
		build_dict(DIGIT_WEIGHTS, Math.round(totals.chars * CHAR_MIX_SHARES.digit), {
			delay_ms: avg_delay_ms * 1.5,
			err_rate: 0.025
		})
	);
	const space_count = Math.round(totals.chars * CHAR_MIX_SHARES.space);
	c_dict[' '] = ngram_item(
		space_count,
		Math.round(space_count * avg_delay_ms * 0.9),
		0,
		Math.round(space_count * hs_letter_share * 0.6),
		0
	);
	c_dict['[BS]'] = ngram_item(
		totals.errors,
		Math.round(totals.errors * avg_delay_ms * 1.4),
		0,
		0,
		0
	);
	c_dict['[ENTER]'] = ngram_item(
		Math.round(totals.chars * 0.012),
		Math.round(totals.chars * 0.012 * avg_delay_ms * 1.8),
		0,
		0,
		0
	);
	c_dict['[TAB]'] = ngram_item(
		Math.round(totals.chars * 0.003),
		Math.round(totals.chars * 0.003 * avg_delay_ms * 2),
		0,
		0,
		0
	);
	// French typographic spaces — always hotstring output (fine typography story)
	const nnbsp_count = Math.round(totals.chars * 0.0022);
	c_dict[' '] = ngram_item(nnbsp_count, 0, 0, nnbsp_count, 0);
	const nbsp_count = Math.round(totals.chars * 0.0011);
	c_dict[' '] = ngram_item(nbsp_count, 0, 0, nbsp_count, 0);

	// Bigrams — doublings carry a hotstring share (the ★ repeat key story)
	const bg_dict = build_dict(BIGRAM_WEIGHTS, Math.round(totals.chars * 0.8), {
		delay_ms: avg_delay_ms * 1.05,
		err_rate: totals.errors / Math.max(1, totals.chars) / 2.2,
		hs_share: (token) =>
			DOUBLING_KEYS.has(token) ? rand_between(0.25, 0.4) : jitter(hs_letter_share * 0.7, 0.3),
		llm_share: llm_letter_share * 0.7
	});

	const tg_dict = build_dict(TRIGRAM_WEIGHTS, Math.round(totals.chars * 0.55), {
		delay_ms: avg_delay_ms * 2.1,
		err_rate: 0.01,
		hs_share: () => jitter(hs_letter_share * 0.6, 0.3),
		llm_share: llm_letter_share * 0.6
	});

	const qg_dict = build_dict(QUADGRAM_WEIGHTS, Math.round(totals.chars * 0.3), {
		delay_ms: avg_delay_ms * 3.2,
		err_rate: 0.008,
		hs_share: () => jitter(hs_letter_share * 0.5, 0.3),
		llm_share: llm_letter_share * 0.5
	});

	const words_total = Math.round(totals.chars / WORD_AVG_LEN);
	const w_dict = build_dict(WORD_WEIGHTS, words_total, {
		delay_ms: avg_delay_ms * 5.5,
		err_rate: 0.006,
		hs_share: (token) => HS_WORD_SHARE[token] || jitter(hs_letter_share * 0.4, 0.4),
		llm_share: llm_letter_share * 0.5
	});

	const w_bg_dict = build_dict(WORD_BIGRAM_WEIGHTS, Math.round(words_total * 0.35), {
		delay_ms: avg_delay_ms * 11,
		err_rate: 0
	});

	// Shortcuts scale with overall volume (baseline weights are per ~550k chars)
	const shortcut_scale = totals.chars / 550000;
	const sc_dict = {};
	Object.entries(SHORTCUT_WEIGHTS).forEach(([token, w]) => {
		const c = Math.max(1, Math.round(w * shortcut_scale * jitter(1, 0.2)));
		sc_dict[token] = ngram_item(c, 0, 0, 0, 0);
	});
	const sc_bg_dict = {};
	Object.entries(SHORTCUT_BIGRAM_WEIGHTS).forEach(([token, w]) => {
		const c = Math.max(1, Math.round(w * shortcut_scale * jitter(1, 0.25)));
		sc_bg_dict[token] = ngram_item(c, 0, 0, 0, 0);
	});

	// Keycode heatmap — mirror the character counts onto physical keys
	const kc_dict = {};
	const add_kc = (kc, count) => {
		if (count <= 0) return;
		const key = String(kc);
		if (!kc_dict[key]) kc_dict[key] = ngram_item(0, 0, 0, 0, 0);
		kc_dict[key].c += count;
	};
	Object.entries(c_dict).forEach(([token, item]) => {
		const kc = CHAR_TO_KEYCODE[token];
		if (kc !== undefined) add_kc(kc, item.c);
	});
	add_kc(KEYCODE_SPACE, space_count);
	add_kc(KEYCODE_BACKSPACE, totals.errors);
	add_kc(KEYCODE_RETURN, c_dict['[ENTER]'].c);
	add_kc(KEYCODE_TAB, c_dict['[TAB]'].c + Math.round((sc_dict.tab || { c: 0 }).c));
	add_kc(KEYCODE_SHIFT, Math.round(totals.chars * 0.045));
	add_kc(KEYCODE_CMD, Math.round(totals.chars * 0.012));
	add_kc(KEYCODE_ALT, Math.round(totals.chars * 0.004));
	add_kc(KEYCODE_CTRL, Math.round(totals.chars * 0.001));
	add_kc(KEYCODE_ESCAPE, (sc_dict.escape || { c: 0 }).c);
	add_kc(KEYCODE_LEFT, (sc_dict.left || { c: 0 }).c);
	add_kc(KEYCODE_RIGHT, (sc_dict.right || { c: 0 }).c);
	add_kc(KEYCODE_UP, (sc_dict.up || { c: 0 }).c);
	add_kc(KEYCODE_DOWN, (sc_dict.down || { c: 0 }).c);

	return {
		c: c_dict,
		bg: bg_dict,
		tg: tg_dict,
		qg: qg_dict,
		// Penta/hexa/hepta-gram tabs are left empty on purpose: the drivers only
		// populate them on the slow full-projection path and the demo story does
		// not need them (their tabs show the standard empty state).
		pg: {},
		hx: {},
		hp: {},
		w: w_dict,
		sc: sc_dict,
		sc_bg: sc_bg_dict,
		w_bg: w_bg_dict,
		kc: kc_dict
	};
}

/**
 * Builds the per-app "today" n-gram buckets by scaling the historical cache
 * down to one partial day for the given app share.
 * @param {Object} historical - Flat cache from build_historical().
 * @param {number} scale - Fraction of the historical volume typed today.
 * @returns {Object} Per-tab bucket in the today shape.
 */
function build_today_bucket(historical, scale) {
	const bucket = {
		c: {},
		bg: {},
		tg: {},
		qg: {},
		pg: {},
		hx: {},
		hp: {},
		w: {},
		sc: {},
		sc_bg: {},
		w_bg: {},
		kc: {}
	};
	['c', 'bg', 'tg', 'w', 'sc', 'kc'].forEach((tab) => {
		Object.entries(historical[tab]).forEach(([token, item]) => {
			const c = stochastic_round(item.c * scale);
			if (c === 0) return;
			bucket[tab][token] = ngram_item(
				c,
				Math.round(item.t * scale),
				stochastic_round(item.e * scale),
				Math.min(c, stochastic_round(item.hs * scale)),
				Math.min(c, stochastic_round(item.llm * scale))
			);
		});
	});
	return bucket;
}

// ========================================
// ========================================
// ======= 5/ Manifest Emitters =======
// ========================================
// ========================================

/**
 * Builds the switches_to map for one app on one day.
 * @param {Object} app - Internal app-day model.
 * @param {Set<string>} present_names - Apps present on that day.
 * @returns {Object} destination app -> switch count.
 */
function build_switches(app, present_names) {
	const out = {};
	SWITCH_AFFINITIES.forEach(({ from, to, per_kchars }) => {
		if (from !== app.spec.name || !present_names.has(to)) return;
		const n = Math.round((app.chars / 1000) * per_kchars * jitter(1, 0.3));
		if (n > 0) out[to] = n;
	});
	return out;
}

/**
 * Emits the metrics_typing manifest entry for one app-day.
 * @param {Object} app - Internal app-day model.
 * @param {Set<string>} present_names - Apps present on that day.
 * @returns {Object} Manifest entry in the typing dashboard shape.
 */
function emit_typing_app(app, present_names) {
	const hourly = {};
	Object.entries(app.hourly).forEach(([hh, h]) => {
		hourly[hh] = { c: h.c, es: h.es, e_buckets: h.e_buckets };
	});
	const entry = {
		chars: app.chars,
		time: app.time_ms,
		hs_chars: app.hs_chars,
		llm_chars: app.llm_chars,
		hs_input_chars: app.hs_input_chars,
		llm_input_chars: app.llm_input_chars,
		hs_triggers: app.hs_triggers,
		hs_suggested: app.hs_suggested,
		llm_triggers: app.llm_triggers,
		llm_suggested: app.llm_suggested,
		app_time_ms: app.app_time_ms,
		hourly,
		time_buckets: app.time_buckets,
		credited_buckets: app.credited_buckets,
		session_count_total: app.session_count,
		session_total_active_ms: app.session_total_active_ms,
		session_longest_ms: app.session_longest_ms,
		session_longest_chars: app.session_longest_chars,
		burst_count_total: app.burst_count,
		burst_max_cpm: app.burst_max_cpm,
		burst_max_chars: app.burst_max_chars,
		burst_inter_delay_count: app.inter_count,
		burst_inter_delay_sum: app.inter_sum,
		burst_inter_delay_sumsq: app.inter_sumsq,
		burst_length_buckets: app.burst_length_buckets,
		same_finger_streak_max: app.same_finger_streak_max,
		same_hand_streak_max: app.same_hand_streak_max,
		cascade_count_total: app.cascade_count,
		cascade_max_len: app.cascade_max_len,
		recovery_time_sum_ms: app.recovery_sum_ms,
		recovery_time_count: app.recovery_count,
		focus_to_first_key_sum_ms: app.focus_sum_ms,
		focus_to_first_key_count: app.focus_count,
		auto_repeat_count: app.auto_repeat_count,
		char_letter: app.char_mix.letter,
		char_digit: app.char_mix.digit,
		char_punct: app.char_mix.punct,
		char_space: app.char_mix.space,
		char_other: app.char_mix.other,
		kc_hold: app.kc_hold,
		layouts_seen: { Ergopti: app.chars },
		switches_to: build_switches(app, present_names)
	};
	if (app.hs_input_chars > 0) {
		entry.hs_input_time_buckets = app.hs_input_time_buckets;
		entry.hs_input_credited_buckets = app.hs_input_credited_buckets;
	}
	if (app.llm_input_chars > 0) {
		entry.llm_input_time_buckets = app.llm_input_time_buckets;
		entry.llm_input_credited_buckets = app.llm_input_credited_buckets;
	}
	return entry;
}

/**
 * Emits the metrics_apps manifest entry for one app-day.
 * @param {Object} app - Internal app-day model.
 * @param {Set<string>} present_names - Apps present on that day.
 * @returns {Object} Manifest entry in the apps dashboard shape.
 */
function emit_apps_app(app, present_names) {
	const hourly = {};
	Object.entries(app.hourly).forEach(([hh, h]) => {
		hourly[hh] = { c: h.c, time_ms: h.time_ms };
	});
	const entry = {
		app_time_ms: app.app_time_ms,
		time: app.time_ms,
		think_time: app.think_time_ms,
		category: app.spec.category,
		chars: app.chars,
		hs_chars: app.hs_chars,
		llm_chars: app.llm_chars,
		hs_triggers: app.hs_triggers,
		llm_triggers: app.llm_triggers,
		bs_total: app.errors,
		session_count_total: app.session_count,
		session_total_active_ms: app.session_total_active_ms,
		session_longest_ms: app.session_longest_ms,
		session_longest_chars: app.session_longest_chars,
		session_durations: app.session_durations,
		burst_count_total: app.burst_count,
		burst_max_cpm: app.burst_max_cpm,
		burst_max_chars: app.burst_max_chars,
		burst_length_buckets: app.burst_length_buckets,
		focus_to_first_key_sum_ms: app.focus_sum_ms,
		focus_to_first_key_count: app.focus_count,
		recovery_time_sum_ms: app.recovery_sum_ms,
		recovery_time_count: app.recovery_count,
		cascade_count_total: app.cascade_count,
		cascade_max_len: app.cascade_max_len,
		auto_repeat_count: app.auto_repeat_count,
		same_finger_streak_max: app.same_finger_streak_max,
		same_hand_streak_max: app.same_hand_streak_max,
		char_letter: app.char_mix.letter,
		char_digit: app.char_mix.digit,
		char_punct: app.char_mix.punct,
		char_space: app.char_mix.space,
		char_other: app.char_mix.other,
		kc_hold: app.kc_hold,
		hourly,
		first_typed_min: app.first_typed_min,
		last_typed_min: app.last_typed_min,
		layouts_seen: { Ergopti: app.chars },
		switches_to: build_switches(app, present_names)
	};
	if (app.spec.titles.length > 0) {
		const win_titles = {};
		app.spec.titles.forEach((title) => {
			win_titles[title] = {
				c: Math.max(1, Math.round(app.focus_count * rand_between(0.2, 0.6))),
				ms: Math.round(app.app_time_ms * rand_between(0.2, 0.5))
			};
		});
		entry.win_titles = win_titles;
	}
	return entry;
}

/**
 * Builds the _system pseudo-app entry (passive time + system counters).
 * @param {boolean} rich - Include the apps-dashboard-only counters.
 * @returns {Object} _system entry.
 */
function emit_system_entry(rich) {
	const locked_ms = Math.round(rand_between(30, 90) * 60000);
	const sleep_ms = Math.round(rand_between(30, 120) * 60000);
	const entry = { locked_ms, sleep_ms };
	if (rich) {
		entry.passive_count = Math.round(rand_between(4, 10));
		entry.awake_ms = 0;
		entry.wifi_changes = Math.round(rand_between(0, 4));
		entry.space_switches = Math.round(rand_between(15, 60));
		entry.audio_muted_ms = Math.round(rand_between(0, 110) * 60000);
		entry.night_wake_count = chance(0.15) ? 1 : 0;
		const battery_count = Math.round(rand_between(10, 20));
		const battery_avg = rand_between(45, 90);
		entry.battery_sum = Math.round(battery_count * battery_avg);
		entry.battery_count = battery_count;
		entry.battery_min = Math.round(battery_avg - rand_between(10, 25));
		entry.battery_max = Math.min(100, Math.round(battery_avg + rand_between(5, 12)));
	}
	return entry;
}

// ========================================
// ========================================
// ======= 6/ Blob Assembly & Output =======
// ========================================
// ========================================

/**
 * Assembles both prefetch blobs from the day model and writes them to disk.
 */
function main() {
	const days = build_days();

	// Aggregate totals used to scale the n-gram tables
	const totals = { chars: 0, errors: 0, hs_chars: 0, llm_chars: 0, time_ms: 0 };
	days.forEach((day) => {
		day.apps.forEach((app) => {
			totals.chars += app.chars;
			totals.errors += app.errors;
			totals.hs_chars += app.hs_chars;
			totals.llm_chars += app.llm_chars;
			totals.time_ms += app.time_ms;
		});
	});
	const avg_delay_ms = totals.time_ms / Math.max(1, totals.chars);

	// Manifests (two views over the same internal model)
	const typing_manifest = {};
	const apps_manifest = {};
	days.forEach((day) => {
		const present_names = new Set(day.apps.map((a) => a.spec.name));
		const typing_day = {};
		const apps_day = {};
		day.apps.forEach((app) => {
			typing_day[app.spec.name] = emit_typing_app(app, present_names);
			apps_day[app.spec.name] = emit_apps_app(app, present_names);
		});
		typing_day._system = emit_system_entry(false);
		apps_day._system = emit_system_entry(true);
		apps_day._sys = {
			unlock: Math.round(rand_between(6, 20)),
			spaces: Math.round(rand_between(10, 40)),
			sleep: Math.round(rand_between(1, 5)),
			wifi: Object.fromEntries(
				Object.entries(WIFI_NETWORKS)
					.map(([ssid, share]) => [ssid, stochastic_round(share * rand_between(4, 12))])
					.filter(([, n]) => n > 0)
			)
		};
		typing_manifest[day.date] = typing_day;
		apps_manifest[day.date] = apps_day;
	});

	// N-gram cache + today buckets for the typing dashboard
	const historical = build_historical(totals, avg_delay_ms);
	const today_day = days[days.length - 1];
	const today_buckets = {};
	if (today_day && today_day.is_today) {
		const day_chars = today_day.apps.reduce((s, a) => s + a.chars, 0);
		today_day.apps.slice(0, 3).forEach((app) => {
			const scale = (app.chars / Math.max(1, day_chars)) * (day_chars / Math.max(1, totals.chars));
			today_buckets[app.spec.name] = build_today_bucket(historical, scale);
		});
	}

	const typing_blob = {
		metrics_manifest: typing_manifest,
		app_icons: {},
		// macOS flavour: n-grams are keyed by HS keycodes directly, so the
		// renderer needs no scancode translation and keycode_layout may be
		// empty (it falls back to the built-in KEYCODE_NAMES labels).
		driver_meta: { os: 'mac', heatmap_id: 'kc' },
		keycode_layout: {},
		_prefetch_data: { historical, today: today_buckets }
	};

	const user_categories = {};
	APP_SPECS.forEach((spec) => {
		user_categories[spec.name] = spec.user_category;
	});
	const apps_blob = {
		metrics_manifest: apps_manifest,
		user_categories,
		app_icons: {}
	};

	fs.mkdirSync(OUTPUT_DIR, { recursive: true });
	fs.writeFileSync(TYPING_OUTPUT, JSON.stringify(typing_blob));
	fs.writeFileSync(APPS_OUTPUT, JSON.stringify(apps_blob));

	const kb = (p) => `${(fs.statSync(p).size / 1024).toFixed(0)} Ko`;
	console.log(`Fichier généré : ${TYPING_OUTPUT} (${kb(TYPING_OUTPUT)})`);
	console.log(`Fichier généré : ${APPS_OUTPUT} (${kb(APPS_OUTPUT)})`);
	console.log(
		`Période : ${days[0].date} → ${days[days.length - 1].date} (${days.length} jours actifs, ${totals.chars} frappes)`
	);
}

main();
