/**
 * ==============================================================================
 * MODULE: Apps Time UI Logic
 * DESCRIPTION:
 * Logic for the apps time tracker UI.
 *
 * FEATURES & RATIONALE:
 * 1. Time Aggregation: Seamlessly merges data by Day, Week, Month, or Year.
 * 2. Visualizer Engine: Computes raw milliseconds into HHh MMm.
 * 3. Dynamic Categories: Plots data grouped by user-defined categories.
 * 4. Chronological Timeline: Stacked bar charts for intraday or interday evolution.
 * ==============================================================================
 */

// Shared i18n helper — reads from window._i18n_strings populated by i18n.js.
function _t(key) {
	return (window._i18n_strings && window._i18n_strings[key]) || key;
}

let manifestData = window.ManifestData || {};
let userCategories = window.UserCategories || {};
let appIcons = window.AppIcons || {};
let currentSelectedDate = null;
let currentPeriod = 'day';
// #53 — null means "all categories enabled"; otherwise a Set of allowed cats.
let currentCategoryFilter = null;
// #54 — null means "all weekdays enabled"; otherwise a Set of allowed dows (0=Mon..6=Sun).
let currentWeekdayFilter = null;
// #55 — when true, the comparator panel computes stats vs the equivalent
// previous period and shows the delta.
let currentCompareEnabled = false;
// Keep-awake counting toggle. Default OFF: awake_ms is subtracted from focus
// time so jiggler intervals don't inflate per-app stats. Toggle ON to count
// keep-awake time normally.
let currentCountAwake = false;

// Dominant colour cache: app_name → '#rrggbb' (computed once per icon via Canvas)
const _dominantColorCache = {};

let appsBarChart = null;
let catPieChart = null;
let timelineChart = null;

const safeLog = (fn, ...args) => {
	try {
		if (console && typeof console[fn] === 'function') console[fn](...args);
	} catch (e) {}
};

function $id(id) {
	try {
		return document.getElementById(id);
	} catch (e) {
		return null;
	}
}

// ===================================
// ===================================
// ======= 1/ Helper Functions =======
// ===================================
// ===================================

const MAC_CATEGORIES_FR = {
	Productivity: 'Productivité',
	'Social networking': 'Réseaux sociaux',
	Games: 'Jeux',
	Entertainment: 'Divertissement',
	Utilities: 'Utilitaires',
	Education: 'Éducation',
	Finance: 'Finance',
	Business: 'Business',
	'Graphics design': 'Design graphique',
	Photography: 'Photographie',
	Video: 'Vidéo',
	Music: 'Musique',
	Medical: 'Médical',
	'Health fitness': 'Santé & Forme',
	Lifestyle: 'Style de vie',
	News: 'Actualités',
	Weather: 'Météo',
	Sports: 'Sport',
	Travel: 'Voyage',
	Navigation: 'Navigation',
	Reference: 'Références',
	'Developer tools': 'Développement',
	Unknown: 'Général'
};

// Perceptually distinct palette — spread across hue wheel to avoid blue clustering
const CHART_PALETTE = [
	'#FF375F', // Red-Pink
	'#FF9F0A', // Orange
	'#FFD60A', // Yellow
	'#32D74B', // Green
	'#64D2FF', // Sky Blue
	'#0A84FF', // Blue
	'#5E5CE6', // Indigo
	'#BF5AF2', // Purple
	'#FF6B35', // Burnt Orange
	'#00C7BE', // Teal
	'#E588F8', // Lavender
	'#F4A460', // Sandy
	'#30B0C7', // Cyan-Teal
	'#FF453A', // Deep Red
	'#34C759', // Leaf Green
	'#5AC8FA', // Light Blue
];

// Fixed aesthetic mappings for standard categories — each hue is deliberately distant
const FIXED_CAT_COLORS = {
	Productivité:       '#0A84FF',  // Blue
	Développement:      '#5E5CE6',  // Indigo
	'Réseaux sociaux':  '#FF375F',  // Pink-Red
	Jeux:               '#FF453A',  // Deep Red
	Divertissement:     '#BF5AF2',  // Purple
	Utilitaires:        '#64D2FF',  // Sky Blue
	Éducation:          '#FF9F0A',  // Orange
	Business:           '#FFD60A',  // Yellow
	Finance:            '#30B0C7',  // Teal
	Design:             '#E588F8',  // Lavender
	Photographie:       '#FF6B35',  // Burnt Orange
	Vidéo:              '#FF375F',  // Coral
	Musique:            '#32D74B',  // Green
	'Santé & Forme':    '#34C759',  // Leaf Green
	Actualités:         '#F4A460',  // Sandy
	Météo:              '#5AC8FA',  // Light Blue
	Voyage:             '#00C7BE',  // Cyan-Teal
	Général:            '#8E8E93',  // Neutral Gray for uncategorized pieces
};

function translateCategory(catName) {
	return MAC_CATEGORIES_FR[catName] || catName;
}

/**
 * Hashes a string to a stable index into CHART_PALETTE, using a better
 * mixing function so similar names land on distant hues.
 * @param {string} str
 * @returns {number}
 */
function paletteIndex(str) {
	let h = 2166136261;
	for (let i = 0; i < str.length; i++) {
		h ^= str.charCodeAt(i);
		h = (Math.imul(h, 16777619) >>> 0);
	}
	return h % CHART_PALETTE.length;
}

function getCategoryColor(catName, score) {
	if (score > 0) return '#30D158';
	if (score < 0) return '#FF453A';
	if (FIXED_CAT_COLORS[catName]) return FIXED_CAT_COLORS[catName];
	return CHART_PALETTE[paletteIndex(catName)];
}

/**
 * Sends an action to the Lua side via the WebKit message bridge.
 * @param {object} payload - {action: string, ...}
 */
function postBridge(payload) {
	try {
		if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.metrics_apps_bridge) {
			window.webkit.messageHandlers.metrics_apps_bridge.postMessage(payload);
		} else {
			console.error('metrics_apps_bridge unavailable');
		}
	} catch (e) {
		console.error('postBridge failed', e);
	}
}

function getAppColor(appName, score) {
	// Always prefer the dominant icon colour — score is reflected in the score column, not the bar
	if (_dominantColorCache[appName]) return _dominantColorCache[appName];
	if (score > 0) return '#30D158';
	if (score < 0) return '#FF453A';
	return CHART_PALETTE[paletteIndex(appName)];
}

/**
 * Extracts the dominant (most saturated, non-white/black) colour from an image
 * data URL by sampling pixels via an off-screen Canvas.
 * @param {string} dataUrl - Base64 image data URL.
 * @returns {string} Hex colour string '#rrggbb'.
 */
function extractDominantColorFromImage(img) {
	try {
		const canvas = document.createElement('canvas');
		canvas.width = 24;
		canvas.height = 24;
		const ctx = canvas.getContext('2d');
		ctx.drawImage(img, 0, 0, 24, 24);
		const data = ctx.getImageData(0, 0, 24, 24).data;
		// Bucket pixels into 4-bit-per-channel bins, weighted by saturation; pick heaviest bin.
		const buckets = {};
		for (let i = 0; i < data.length; i += 4) {
			const r = data[i], g = data[i + 1], b = data[i + 2], a = data[i + 3];
			if (a < 100) continue;
			const lum = (r + g + b) / 3;
			if (lum > 235 || lum < 20) continue;
			const max = Math.max(r, g, b), min = Math.min(r, g, b);
			const sat = max === 0 ? 0 : (max - min) / max;
			if (sat < 0.18) continue;
			const key = (r >> 4) * 256 + (g >> 4) * 16 + (b >> 4);
			if (!buckets[key]) buckets[key] = { r: 0, g: 0, b: 0, w: 0 };
			const wt = sat;
			buckets[key].r += r * wt;
			buckets[key].g += g * wt;
			buckets[key].b += b * wt;
			buckets[key].w += wt;
		}
		let best = null;
		for (const k in buckets) {
			if (!best || buckets[k].w > best.w) best = buckets[k];
		}
		if (!best || best.w === 0) return null;
		const r = Math.round(best.r / best.w);
		const g = Math.round(best.g / best.w);
		const b = Math.round(best.b / best.w);
		return '#' + [r, g, b].map((v) => v.toString(16).padStart(2, '0')).join('');
	} catch (_) {
		return null;
	}
}

/**
 * Asynchronously computes dominant colours for all icons. Resolves once every
 * image has either loaded (and been sampled) or failed.
 * @returns {Promise<void>}
 */
function precomputeIconColors() {
	const entries = Object.entries(appIcons).filter(([n, u]) => u && !_dominantColorCache[n]);
	if (entries.length === 0) return Promise.resolve();
	return Promise.all(
		entries.map(([appName, dataUrl]) => new Promise((resolve) => {
			const img = new Image();
			img.onload = () => {
				const color = extractDominantColorFromImage(img);
				if (color) _dominantColorCache[appName] = color;
				resolve();
			};
			img.onerror = () => resolve();
			img.src = dataUrl;
		}))
	).then(() => undefined);
}

function escapeHtml(unsafe) {
	if (!unsafe) return '';
	return unsafe
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#039;');
}

function formatDuration(ms) {
	if (!ms && ms !== 0) return '0m';
	const n = Number(ms) || 0;
	const totalMinutes = Math.floor(n / 60000);
	const hours = Math.floor(totalMinutes / 60);
	const minutes = totalMinutes % 60;
	if (hours > 0) return `${hours}h ${String(minutes).padStart(2, '0')}m`;
	return `${minutes}m`;
}

function formatDurationDecimal(ms) {
	if (!ms) return 0;
	return Number((ms / 3600000).toFixed(2));
}

function parseDateKey(dateStr) {
	if (!dateStr || (typeof dateStr !== 'string' && typeof dateStr !== 'number')) return NaN;
	if (/^\d+$/.test(String(dateStr))) {
		const n = Number(dateStr);
		if (String(dateStr).length <= 10) return n * 1000;
		return n;
	}
	const s = String(dateStr);
	const isoMatch = s.match(/^(\d{4})[-\/](\d{2})[-\/](\d{2})/);
	if (isoMatch)
		return new Date(
			parseInt(isoMatch[1], 10),
			parseInt(isoMatch[2], 10) - 1,
			parseInt(isoMatch[3], 10)
		).getTime();

	const frMatch = s.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
	if (frMatch)
		return new Date(
			parseInt(frMatch[3], 10),
			parseInt(frMatch[2], 10) - 1,
			parseInt(frMatch[1], 10)
		).getTime();

	const t = Date.parse(s);
	return isNaN(t) ? NaN : t;
}

function formatDisplayDate(dateStr) {
	const ts = parseDateKey(dateStr);
	if (isNaN(ts)) return dateStr;
	const d = new Date(ts);
	return `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}/${d.getFullYear()}`;
}

// ===================================
// ===================================
// ======= 2/ State Management =======
// ===================================
// ===================================

window.updateUserCategories = function (newCategories) {
	userCategories = newCategories || {};
	renderDashboard();
};

function getAppCategory(appName, nativeCategory) {
	if (userCategories[appName]) {
		const uc = userCategories[appName];
		return { type: translateCategory(uc.type), score: uc.score };
	}
	return { type: translateCategory(nativeCategory || 'Général'), score: 0 };
}

function getAggregatedData() {
	const result = {
		apps: {},
		_sys: { wifi: {}, power: {}, sleep: 0, unlock: 0, spaces: 0 },
		// Rich, manifest-wide rollup. Populated alongside the per-app pass below
		// so every future card / chart / drill-down can read the same shape.
		rich: {
			date_range: { start: null, end: null, days: 0 },
			time: {
				focus_ms: 0,        // Σ app_time_ms across non-system apps
				active_ms: 0,       // Σ time (truly typing inter-key gaps)
				think_ms: 0,        // Σ think_time
				passive_locked_ms: 0,
				passive_sleep_ms: 0,
				passive_count: 0,
				// Keep-awake duration aggregated from _system.awake_ms across days.
				// Subtracted from focus_ms when the "compter le keep-awake" toggle is OFF.
				awake_ms: 0,
			},
			system: {
				wifi_changes:    0,
				space_switches:  0,
				battery_sum:     0,
				battery_count:   0,
				battery_min:     null,
				battery_max:     null,
				audio_muted_ms:  0,
				night_wake_count:0,
			},
			typing: {
				chars: 0,
				hs_chars: 0,
				llm_chars: 0,
				hs_triggers: 0,
				llm_triggers: 0,
				bs_total: 0,
				cascade_count_total: 0,
				cascade_max_len: 0,
				recovery_time_sum_ms: 0,
				recovery_time_count: 0,
				auto_repeat_count: 0,
				char_letter: 0, char_digit: 0, char_punct: 0,
				char_space: 0, char_other: 0,
			},
			sessions: {
				count: 0,
				total_active_ms: 0,
				longest_ms: 0,
				longest_chars: 0,
				longest_app: null,
			},
			bursts: {
				count: 0,
				max_cpm: 0,
				max_chars: 0,
				length_buckets: {},  // bucket_label → count, rolled up across apps
			},
			ergonomics: {
				same_finger_streak_max: 0,
				same_hand_streak_max: 0,
			},
			focus_latency: { sum_ms: 0, count: 0 },
			// First / last typed minute observed across all apps in the range,
			// stored as { date, hh, mm } so we can format both the time and
			// the absolute moment for amplitude computation.
			day_first: null,
			day_last:  null,
			// kc_hold rolled up across all apps and days in the range
			kc_hold: {},
			// layouts_seen rolled up
			layouts: {},
			// Per-hour rollup across days: hour_str → { time_ms, chars }
			by_hour: {},
			// Per-weekday rollup: weekday (0=Mon) → { time_ms, chars }
			by_weekday: {},
			// Hour × weekday grid: "hh|wd" → { time_ms, chars }
			hour_weekday: {},
			// Per-day rollup: date_str → { time_ms, active_ms, chars, switches, sessions }
			by_date: {},
			// Per-category rollup: cat → { time_ms, chars, active_ms }
			by_category: {},
			// Sessions count signal: how many app/day rows whose longest_ms is
			// above the long-session threshold (≥ 90 min by default).
			long_sessions: 0,
			// Productivity split across the period (#20 raffiné):
			// time_ms summed by sign of category score.
			prod_split: { positive_ms: 0, neutral_ms: 0, negative_ms: 0 },
			// Per-weekday × category time totals (#22): dow → cat → time_ms.
			weekday_category: {},
			// Ribbon (#25): date_str → hour_str → cat → time_ms. Used to draw
			// a Toggl-style horizontal bar per day, colored by dominant category
			// at each hour.
			ribbon: {},
		},
		timeline: {}
	};
	const LONG_SESSION_THRESHOLD_MS = 90 * 60 * 1000;

	const allDates = Object.keys(manifestData)
		.map((k) => ({ key: k, ts: parseDateKey(k) }))
		.filter((d) => !isNaN(d.ts))
		.sort((a, b) => b.ts - a.ts);

	if (allDates.length === 0) return result;

	let targetTsStart = 0;
	const anchorTs = currentSelectedDate ? parseDateKey(currentSelectedDate) : allDates[0].ts;

	if (currentPeriod === 'day') targetTsStart = anchorTs;
	else if (currentPeriod === 'week') targetTsStart = anchorTs - 7 * 86400000;
	else if (currentPeriod === 'month') targetTsStart = anchorTs - 30 * 86400000;
	else if (currentPeriod === 'year') targetTsStart = anchorTs - 365 * 86400000;

	const validDates = allDates.filter((d) => {
		if (currentPeriod !== 'all' && (d.ts > anchorTs || d.ts < targetTsStart)) return false;
		if (currentWeekdayFilter) {
			const dow = ((new Date(d.ts).getDay() + 6) % 7);
			if (!currentWeekdayFilter.has(dow)) return false;
		}
		return true;
	});

	// Date range bookkeeping for the rich rollup
	if (validDates.length > 0) {
		const sorted = [...validDates].sort((a, b) => a.ts - b.ts);
		result.rich.date_range.start = sorted[0].key;
		result.rich.date_range.end   = sorted[sorted.length - 1].key;
		result.rich.date_range.days  = sorted.length;
	}

	validDates.forEach((d) => {
		const dayData = manifestData[d.key];
		if (!dayData) return;

		// Legacy _sys (never populated by current Lua but kept for backward compat)
		if (dayData._sys) {
			result._sys.sleep += dayData._sys.sleep || 0;
			result._sys.unlock += dayData._sys.unlock || 0;
			result._sys.spaces += dayData._sys.spaces || 0;
			Object.entries(dayData._sys.wifi || {}).forEach(
				([k, v]) => (result._sys.wifi[k] = (result._sys.wifi[k] || 0) + v)
			);
		}

		// New _system pseudo-app written by the keylogger caffeinate callbacks.
		// Tracks precise locked / sleeping durations so the active ratio can be
		// computed without inflation from screen-locked time.
		const sysEntry = dayData._system;
		if (sysEntry) {
			result.rich.time.passive_locked_ms += sysEntry.locked_ms || 0;
			result.rich.time.passive_sleep_ms  += sysEntry.sleep_ms  || 0;
			result.rich.time.passive_count     += sysEntry.passive_count || 0;
			result.rich.time.awake_ms          += sysEntry.awake_ms  || 0;

			// System counters (#13–19)
			const rsys = result.rich.system;
			rsys.wifi_changes     += sysEntry.wifi_changes     || 0;
			rsys.space_switches   += sysEntry.space_switches   || 0;
			rsys.audio_muted_ms   += sysEntry.audio_muted_ms   || 0;
			rsys.night_wake_count += sysEntry.night_wake_count || 0;
			if (sysEntry.battery_count) {
				rsys.battery_sum   += sysEntry.battery_sum   || 0;
				rsys.battery_count += sysEntry.battery_count || 0;
				if (sysEntry.battery_min != null && (rsys.battery_min == null || sysEntry.battery_min < rsys.battery_min))
					rsys.battery_min = sysEntry.battery_min;
				if (sysEntry.battery_max != null && (rsys.battery_max == null || sysEntry.battery_max > rsys.battery_max))
					rsys.battery_max = sysEntry.battery_max;
			}
		}

		// Day-level rollup row
		const byDate = result.rich.by_date[d.key] || (result.rich.by_date[d.key] = {
			time_ms: 0, active_ms: 0, chars: 0, switches: 0, sessions: 0,
			passive_ms: 0, by_category: {},
			first_min: null, last_min: null,
		});
		if (sysEntry) {
			byDate.passive_ms += (sysEntry.locked_ms || 0) + (sysEntry.sleep_ms || 0);
		}

		// Weekday: parseDateKey returns a JS-compatible ts; convert to Mon=0..Sun=6
		const dow = ((new Date(d.ts).getDay() + 6) % 7);
		const byWk = result.rich.by_weekday[dow] || (result.rich.by_weekday[dow] = { time_ms: 0, chars: 0 });

		for (const [appName, appData] of Object.entries(dayData)) {
			if (appName === '_sys' || appName === '_system') continue;

			// #53 category filter — skip apps not in the allowed set
			if (currentCategoryFilter) {
				const _cat = getAppCategory(appName, appData.category).type || 'Général';
				if (!currentCategoryFilter.has(_cat)) continue;
			}

			if (!result.apps[appName]) {
				result.apps[appName] = { time_ms: 0, typing_time: 0, switches: {} };
			}

			// Per-app keep-awake correction: when the toggle is OFF (default),
			// subtract awake_ms from app_time_ms so jiggler intervals don't
			// inflate the focus aggregate. Toggle ON = count it normally.
			const _appMsRaw  = Number(appData.app_time_ms) || 0;
			const _appAwake  = Number(appData.awake_ms)    || 0;
			const _appMsEff  = currentCountAwake ? _appMsRaw : Math.max(0, _appMsRaw - _appAwake);
			result.apps[appName].time_ms += _appMsEff;
			result.apps[appName].typing_time +=
				(Number(appData.time) || 0) + (Number(appData.think_time) || 0);
			result.apps[appName].category = appData.category;
			result.apps[appName].awake_ms = (result.apps[appName].awake_ms || 0) + _appAwake;

			if (appData.switches_to) {
				Object.entries(appData.switches_to).forEach(([dest, count]) => {
					result.apps[appName].switches[dest] = (result.apps[appName].switches[dest] || 0) + count;
				});
			}

			// ── Rich rollup ─────────────────────────────────────────────────
			// Mirror common scalars onto the per-app entry so future drill-down
			// modals / table columns can read them without re-walking manifest.
			const appOut = result.apps[appName];
			appOut.chars         = (appOut.chars         || 0) + (Number(appData.chars)         || 0);
			appOut.hs_chars      = (appOut.hs_chars      || 0) + (Number(appData.hs_chars)      || 0);
			appOut.llm_chars     = (appOut.llm_chars     || 0) + (Number(appData.llm_chars)     || 0);
			appOut.bs_total      = (appOut.bs_total      || 0) + (Number(appData.bs_total)      || 0);
			appOut.session_count = (appOut.session_count || 0) + (Number(appData.session_count_total) || 0);
			appOut.session_total_active_ms =
				(appOut.session_total_active_ms || 0) + (Number(appData.session_total_active_ms) || 0);
			if ((Number(appData.session_longest_ms) || 0) > (appOut.session_longest_ms || 0)) {
				appOut.session_longest_ms    = Number(appData.session_longest_ms) || 0;
				appOut.session_longest_chars = Number(appData.session_longest_chars) || 0;
			}
			if ((Number(appData.burst_max_cpm) || 0) > (appOut.burst_max_cpm || 0)) {
				appOut.burst_max_cpm = Number(appData.burst_max_cpm) || 0;
			}
			appOut.focus_latency_sum_ms = (appOut.focus_latency_sum_ms || 0) + (Number(appData.focus_to_first_key_sum_ms) || 0);
			appOut.focus_latency_count  = (appOut.focus_latency_count  || 0) + (Number(appData.focus_to_first_key_count)  || 0);
			appOut.recovery_sum_ms      = (appOut.recovery_sum_ms      || 0) + (Number(appData.recovery_time_sum_ms)      || 0);
			appOut.recovery_count       = (appOut.recovery_count       || 0) + (Number(appData.recovery_time_count)       || 0);
			appOut.cascade_count        = (appOut.cascade_count        || 0) + (Number(appData.cascade_count_total)       || 0);
			appOut.auto_repeat_count    = (appOut.auto_repeat_count    || 0) + (Number(appData.auto_repeat_count)         || 0);
			// #51 same-finger streak max per app
			if ((Number(appData.same_finger_streak_max) || 0) > (appOut.same_finger_streak_max || 0)) {
				appOut.same_finger_streak_max = Number(appData.same_finger_streak_max);
			}
			// #52 modifier hold mean — sum across kc_hold for this app
			if (appData.kc_hold) {
				appOut.kc_hold_sum_ms = appOut.kc_hold_sum_ms || 0;
				appOut.kc_hold_count  = appOut.kc_hold_count  || 0;
				Object.values(appData.kc_hold).forEach((h) => {
					appOut.kc_hold_sum_ms += h.s || 0;
					appOut.kc_hold_count  += h.n || 0;
				});
			}
			// #28 collect per-session durations
			if (Array.isArray(appData.session_durations)) {
				appOut.session_durations = appOut.session_durations || [];
				appData.session_durations.forEach((d) => appOut.session_durations.push(d));
			}
			// #39 aggregate window titles
			if (appData.win_titles) {
				appOut.win_titles = appOut.win_titles || {};
				Object.entries(appData.win_titles).forEach(([t, w]) => {
					const slot = appOut.win_titles[t] || (appOut.win_titles[t] = { c: 0, ms: 0 });
					slot.c  += w.c  || 0;
					slot.ms += w.ms || 0;
				});
			}

			// Manifest-wide rollup — use the keep-awake-corrected app time so
			// the headline focus_ms reflects the toggle.
			const r = result.rich;
			r.time.focus_ms  += _appMsEff;
			r.time.active_ms += Number(appData.time)        || 0;
			r.time.think_ms  += Number(appData.think_time)  || 0;
			r.typing.chars         += Number(appData.chars)         || 0;
			r.typing.hs_chars      += Number(appData.hs_chars)      || 0;
			r.typing.llm_chars     += Number(appData.llm_chars)     || 0;
			r.typing.hs_triggers   += Number(appData.hs_triggers)   || 0;
			r.typing.llm_triggers  += Number(appData.llm_triggers)  || 0;
			r.typing.bs_total      += Number(appData.bs_total)      || 0;
			r.typing.cascade_count_total  += Number(appData.cascade_count_total)  || 0;
			r.typing.recovery_time_sum_ms += Number(appData.recovery_time_sum_ms) || 0;
			r.typing.recovery_time_count  += Number(appData.recovery_time_count)  || 0;
			r.typing.auto_repeat_count    += Number(appData.auto_repeat_count)    || 0;
			r.typing.char_letter  += Number(appData.char_letter)  || 0;
			r.typing.char_digit   += Number(appData.char_digit)   || 0;
			r.typing.char_punct   += Number(appData.char_punct)   || 0;
			r.typing.char_space   += Number(appData.char_space)   || 0;
			r.typing.char_other   += Number(appData.char_other)   || 0;
			if ((Number(appData.cascade_max_len) || 0) > r.typing.cascade_max_len) {
				r.typing.cascade_max_len = Number(appData.cascade_max_len);
			}
			r.sessions.count           += Number(appData.session_count_total)     || 0;
			r.sessions.total_active_ms += Number(appData.session_total_active_ms) || 0;
			if ((Number(appData.session_longest_ms) || 0) > r.sessions.longest_ms) {
				r.sessions.longest_ms    = Number(appData.session_longest_ms);
				r.sessions.longest_chars = Number(appData.session_longest_chars) || 0;
				r.sessions.longest_app   = appName;
			}
			if ((Number(appData.session_longest_ms) || 0) >= LONG_SESSION_THRESHOLD_MS) {
				r.long_sessions += 1;
			}
			r.bursts.count   += Number(appData.burst_count_total) || 0;
			if ((Number(appData.burst_max_cpm) || 0) > r.bursts.max_cpm) {
				r.bursts.max_cpm = Number(appData.burst_max_cpm);
			}
			if ((Number(appData.burst_max_chars) || 0) > r.bursts.max_chars) {
				r.bursts.max_chars = Number(appData.burst_max_chars);
			}
			if (appData.burst_length_buckets) {
				Object.entries(appData.burst_length_buckets).forEach(([k, v]) => {
					r.bursts.length_buckets[k] = (r.bursts.length_buckets[k] || 0) + (v || 0);
				});
			}
			if ((Number(appData.same_finger_streak_max) || 0) > r.ergonomics.same_finger_streak_max) {
				r.ergonomics.same_finger_streak_max = Number(appData.same_finger_streak_max);
			}
			if ((Number(appData.same_hand_streak_max) || 0) > r.ergonomics.same_hand_streak_max) {
				r.ergonomics.same_hand_streak_max = Number(appData.same_hand_streak_max);
			}
			r.focus_latency.sum_ms += Number(appData.focus_to_first_key_sum_ms) || 0;
			r.focus_latency.count  += Number(appData.focus_to_first_key_count)  || 0;

			// Earliest / latest typed minute on the period
			const ftm = appData.first_typed_min;
			const ltm = appData.last_typed_min;
			if (typeof ftm === 'string' && /^\d{2}:\d{2}$/.test(ftm)) {
				const candidate = { date: d.key, hh: +ftm.slice(0,2), mm: +ftm.slice(3,5), str: ftm };
				if (!r.day_first || d.key < r.day_first.date ||
					(d.key === r.day_first.date && (candidate.hh*60+candidate.mm) < (r.day_first.hh*60+r.day_first.mm))) {
					r.day_first = candidate;
				}
			}
			if (typeof ltm === 'string' && /^\d{2}:\d{2}$/.test(ltm)) {
				const candidate = { date: d.key, hh: +ltm.slice(0,2), mm: +ltm.slice(3,5), str: ltm };
				if (!r.day_last || d.key > r.day_last.date ||
					(d.key === r.day_last.date && (candidate.hh*60+candidate.mm) > (r.day_last.hh*60+r.day_last.mm))) {
					r.day_last = candidate;
				}
			}

			// kc_hold roll-up
			if (appData.kc_hold) {
				Object.entries(appData.kc_hold).forEach(([kc, h]) => {
					const t = r.kc_hold[kc] || (r.kc_hold[kc] = { s: 0, n: 0, m: 0, tap: 0, hold: 0 });
					t.s    += h.s    || 0;
					t.n    += h.n    || 0;
					t.tap  += h.tap  || 0;
					t.hold += h.hold || 0;
					if ((h.m || 0) > t.m) t.m = h.m;
				});
			}
			// Layouts seen roll-up
			if (appData.layouts_seen) {
				Object.entries(appData.layouts_seen).forEach(([id, n]) => {
					r.layouts[id] = (r.layouts[id] || 0) + (n || 0);
				});
			}

			// Per-hour rollup (manifest-wide): combines time_ms (proportionally
			// distributed when missing) and chars typed in that hour.
			// Resolved category is needed before the hourly loop for #21 score weighting.
			const _hourCat = getAppCategory(appName, appData.category);
			if (appData.hourly) {
				let totalAppCharsForHourly = 0;
				Object.values(appData.hourly).forEach((h) => (totalAppCharsForHourly += h.c || 0));
				Object.entries(appData.hourly).forEach(([hour, hData]) => {
					let hMs = hData.time_ms || 0;
					if (hMs === 0 && totalAppCharsForHourly > 0 && hData.c > 0) {
						hMs = (hData.c / totalAppCharsForHourly) * (Number(appData.app_time_ms) || 0);
					}
					const slot = r.by_hour[hour] || (r.by_hour[hour] = { time_ms: 0, chars: 0, score_x_ms: 0 });
					slot.time_ms += hMs;
					slot.chars   += hData.c || 0;
					slot.score_x_ms = (slot.score_x_ms || 0) + (_hourCat.score || 0) * hMs;
					// Ribbon (#25) per-day per-hour per-category accumulation
					const ribDay  = r.ribbon[d.key] || (r.ribbon[d.key] = {});
					const ribHour = ribDay[hour]    || (ribDay[hour]    = {});
					const ribCat  = _hourCat.type || 'Général';
					ribHour[ribCat] = (ribHour[ribCat] || 0) + hMs;
					// Hour × weekday cell — same dow as the day this app/day row
					// belongs to. Drives the heatmap.
					const cell_key = `${hour}|${dow}`;
					const cell = r.hour_weekday[cell_key]
						|| (r.hour_weekday[cell_key] = { time_ms: 0, chars: 0 });
					cell.time_ms += hMs;
					cell.chars   += hData.c || 0;
				});
			}

			// Day rollup
			byDate.time_ms   += Number(appData.app_time_ms) || 0;
			byDate.active_ms += Number(appData.time)        || 0;
			byDate.chars     += Number(appData.chars)       || 0;
			byDate.sessions  += Number(appData.session_count_total) || 0;
			if (appData.switches_to) {
				Object.values(appData.switches_to).forEach((n) => (byDate.switches += n || 0));
			}
			byWk.time_ms += Number(appData.app_time_ms) || 0;
			byWk.chars   += Number(appData.chars)       || 0;

			// Category rollup uses the resolved category (user override aware)
			const catData = getAppCategory(appName, appData.category);
			const cat = catData.type || 'Général';
			const catSlot = r.by_category[cat] || (r.by_category[cat] = { time_ms: 0, chars: 0, active_ms: 0 });
			const appMs = Number(appData.app_time_ms) || 0;
			byDate.by_category[cat] = (byDate.by_category[cat] || 0) + appMs;
			// First / last typed minute on this day across apps
			const _ftmDay = appData.first_typed_min;
			const _ltmDay = appData.last_typed_min;
			if (typeof _ftmDay === 'string' && /^\d{2}:\d{2}$/.test(_ftmDay)) {
				const _m = (+_ftmDay.slice(0,2)) * 60 + (+_ftmDay.slice(3,5));
				if (byDate.first_min == null || _m < byDate.first_min) byDate.first_min = _m;
			}
			if (typeof _ltmDay === 'string' && /^\d{2}:\d{2}$/.test(_ltmDay)) {
				const _m = (+_ltmDay.slice(0,2)) * 60 + (+_ltmDay.slice(3,5));
				if (byDate.last_min == null || _m > byDate.last_min) byDate.last_min = _m;
			}
			catSlot.time_ms   += appMs;
			catSlot.chars     += Number(appData.chars) || 0;
			catSlot.active_ms += Number(appData.time)  || 0;

			// #20 productivity split (sign of score)
			if ((catData.score || 0) > 0)      r.prod_split.positive_ms += appMs;
			else if ((catData.score || 0) < 0) r.prod_split.negative_ms += appMs;
			else                                r.prod_split.neutral_ms  += appMs;

			// #22 per-weekday × category time
			const wkSlot = r.weekday_category[dow] || (r.weekday_category[dow] = {});
			wkSlot[cat] = (wkSlot[cat] || 0) + appMs;

			const catName = cat;

			if (currentPeriod === 'day') {
				if (appData.hourly) {
					let totalAppChars = 0;
					Object.values(appData.hourly).forEach((h) => (totalAppChars += h.c || 0));

					Object.entries(appData.hourly).forEach(([hour, hData]) => {
						if (!result.timeline[hour]) result.timeline[hour] = {};

						let hTimeMs = hData.time_ms || 0;
						if (hTimeMs === 0 && totalAppChars > 0 && hData.c > 0) {
							hTimeMs = (hData.c / totalAppChars) * (Number(appData.app_time_ms) || 0);
						}

						result.timeline[hour][catName] = (result.timeline[hour][catName] || 0) + hTimeMs;
					});
				}
			} else {
				const dayLabel = formatDisplayDate(d.key).substring(0, 5);
				if (!result.timeline[dayLabel]) result.timeline[dayLabel] = {};
				result.timeline[dayLabel][catName] =
					(result.timeline[dayLabel][catName] || 0) + (Number(appData.app_time_ms) || 0);
			}
		}
	});

	return result;
}

// =================================
// =================================
// ======= 3/ Initialization =======
// =================================
// =================================

function initDashboard() {
	const dateSelect = $id('date-select');
	const periodSelect = $id('period-select');
	if (!dateSelect || !periodSelect) return;

	if (!initDashboard._listenersBound) {
		dateSelect.addEventListener('change', (e) => {
			currentSelectedDate = e.target.value;
			renderDashboard();
		});
		periodSelect.addEventListener('change', (e) => {
			currentPeriod = e.target.value;
			$id('date-select-container').style.display = currentPeriod === 'all' ? 'none' : 'block';
			renderDashboard();
		});
		$id('btn-refresh').addEventListener('click', renderDashboard);
		$id('btn-add-app').addEventListener(
			'click',
			() => {
				postBridge({ action: 'pick' });
			}
		);
		const btnCmp = $id('btn-compare-prev');
		if (btnCmp) {
			btnCmp.addEventListener('click', () => {
				currentCompareEnabled = !currentCompareEnabled;
				btnCmp.classList.toggle('active', currentCompareEnabled);
				renderDashboard();
			});
		}
		const btnAwake = $id('btn-count-awake');
		if (btnAwake) {
			btnAwake.classList.toggle('active', currentCountAwake);
			btnAwake.addEventListener('click', () => {
				currentCountAwake = !currentCountAwake;
				btnAwake.classList.toggle('active', currentCountAwake);
				renderDashboard();
			});
		}
		initDashboard._listenersBound = true;
	}

	dateSelect.innerHTML = '';
	const dates = Object.keys(manifestData)
		.map((k) => ({ key: k, ts: parseDateKey(k) }))
		.filter((d) => !isNaN(d.ts))
		.sort((a, b) => b.ts - a.ts);

	if (dates.length === 0) {
		currentSelectedDate = null;
		renderDashboard();
		return;
	}

	dates.forEach((d) => {
		const option = document.createElement('option');
		option.value = d.key;
		option.textContent = formatDisplayDate(d.key);
		dateSelect.appendChild(option);
	});

	if (!currentSelectedDate) currentSelectedDate = dates[0].key;
	dateSelect.value = currentSelectedDate;

	rebuildFilterButtons();
	wireTabs();

	// First paint with fallback colours, then re-render once dominant icon colours are computed.
	renderDashboard();
	precomputeIconColors().then(() => renderDashboard());
}

/** Activates a tab by name, toggling visibility of all `[data-tab]` sections.
 *  Triggers a fresh render after activation so any Chart.js instance whose canvas
 *  was 0×0 while the tab was hidden gets recomputed against the now-visible layout. */
function activateTab(name) {
	document.querySelectorAll('[data-tab]').forEach((el) => {
		el.classList.toggle('tab-active', el.getAttribute('data-tab') === name);
	});
	document.querySelectorAll('.tab-btn').forEach((btn) => {
		btn.classList.toggle('active', btn.getAttribute('data-tab-target') === name);
	});
	// Re-render so newly-visible canvases get a non-zero size before Chart.js
	// computes their dimensions. setTimeout(0) waits for the layout pass.
	setTimeout(() => { try { renderDashboard(); } catch (_) {} }, 0);
}

/** Wires click handlers on the tab buttons (idempotent). */
function wireTabs() {
	if (wireTabs._bound) return;
	const buttons = document.querySelectorAll('.tab-btn[data-tab-target]');
	if (buttons.length === 0) return;
	buttons.forEach((btn) => {
		btn.addEventListener('click', () => activateTab(btn.getAttribute('data-tab-target')));
	});
	// Default to the first tab so something is visible on first paint
	activateTab('overview');
	wireTabs._bound = true;
}

/**
 * Builds the category and weekday filter pill rows. Categories are derived from
 * the manifest (set of all resolved category names). Weekdays are fixed.
 */
function rebuildFilterButtons() {
	const catBox = document.getElementById('category-filter-buttons');
	const wkBox  = document.getElementById('weekday-filter-buttons');
	if (!catBox || !wkBox) return;

	// ── Categories ────────────────────────────────────────────────────
	const allCats = new Set();
	Object.values(manifestData || {}).forEach((day) => {
		Object.entries(day || {}).forEach(([name, app]) => {
			if (name === '_sys' || name === '_system') return;
			const c = getAppCategory(name, app.category).type || 'Général';
			allCats.add(c);
		});
	});
	const catList = [...allCats].sort();

	const renderCats = () => {
		catBox.innerHTML = catList.map((c) => {
			const active = !currentCategoryFilter || currentCategoryFilter.has(c);
			return `<button class="filter-btn${active ? ' active' : ''}" data-cat="${escapeHtml(c)}" style="padding:3px 9px;font-size:11px;">${escapeHtml(c)}</button>`;
		}).join('');
		[...catBox.querySelectorAll('button[data-cat]')].forEach((btn) => {
			btn.addEventListener('click', () => {
				const cat = btn.getAttribute('data-cat');
				if (!currentCategoryFilter) {
					// First exclusion: start from "everything except this"
					currentCategoryFilter = new Set(catList);
				}
				if (currentCategoryFilter.has(cat)) currentCategoryFilter.delete(cat);
				else currentCategoryFilter.add(cat);
				if (currentCategoryFilter.size === catList.length) currentCategoryFilter = null;
				renderCats();
				renderDashboard();
			});
		});
	};
	renderCats();

	// ── Weekdays ──────────────────────────────────────────────────────
	const wkLabels = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];
	const renderWk = () => {
		wkBox.innerHTML = wkLabels.map((label, idx) => {
			const active = !currentWeekdayFilter || currentWeekdayFilter.has(idx);
			return `<button class="filter-btn${active ? ' active' : ''}" data-dow="${idx}" style="padding:3px 9px;font-size:11px;">${label}</button>`;
		}).join('');
		[...wkBox.querySelectorAll('button[data-dow]')].forEach((btn) => {
			btn.addEventListener('click', () => {
				const dow = +btn.getAttribute('data-dow');
				if (!currentWeekdayFilter) currentWeekdayFilter = new Set([0,1,2,3,4,5,6]);
				if (currentWeekdayFilter.has(dow)) currentWeekdayFilter.delete(dow);
				else currentWeekdayFilter.add(dow);
				if (currentWeekdayFilter.size === 7) currentWeekdayFilter = null;
				renderWk();
				renderDashboard();
			});
		});
	};
	renderWk();
}

window.bootstrapMetricsAppsData = function (newManifest, newCategories, newIcons) {
	manifestData = newManifest || {};
	userCategories = newCategories || {};
	appIcons = newIcons || {};
	initDashboard();
};

window.receive_live_update = function (newManifest) {
	if (!newManifest) return;
	Object.keys(newManifest).forEach((k) => (manifestData[k] = newManifest[k]));
	initDashboard();
};

// =================================
// =================================
// ======= 4/ Data Rendering =======
// =================================
// =================================

const HHMM_TOOLTIP = (context) => {
	const val = context.parsed.y || context.parsed;
	const totalMins = Math.round(val * 60);
	const h = Math.floor(totalMins / 60);
	const m = String(totalMins % 60).padStart(2, '0');
	return h > 0 ? `${h}h ${m}m` : `${m}m`;
};

function updateCharts(appsArray, aggregatedData) {
	if (typeof Chart === 'undefined') return;

	// 1. Top 7 Apps — bars colored with dominant icon colour, icon drawn under each label
	const topApps = appsArray.slice(0, 7);
	const barCtx = $id('apps_bar_chart');
	if (barCtx) {
		if (appsBarChart) appsBarChart.destroy();

		// Pre-load icon images so the afterDraw plugin can paint them. Each loaded
		// image triggers a chart redraw so icons appear as soon as they decode.
		const iconImages = topApps.map((a) => {
			if (!appIcons[a.name]) return null;
			const img = new Image();
			img.onload = () => { if (appsBarChart) appsBarChart.draw(); };
			img.src = appIcons[a.name];
			return img;
		});

		// Plugin that draws 22×22 px icons immediately below the x-axis tick labels
		const iconPlugin = {
			id: 'appIconsBelow',
			afterDraw(chart) {
				const ctx = chart.ctx;
				const xAxis = chart.scales['x'];
				if (!xAxis) return;
				const ICON_SIZE = 22;
				topApps.forEach((_, i) => {
					const img = iconImages[i];
					if (!img || !img.complete || !img.naturalWidth) return;
					const tick = xAxis.getPixelForTick(i);
					// xAxis.bottom is the bottom of the axis region (after labels); place icons just under it
					const top = xAxis.bottom + 2;
					ctx.drawImage(img, tick - ICON_SIZE / 2, top, ICON_SIZE, ICON_SIZE);
				});
			}
		};

		appsBarChart = new Chart(barCtx.getContext('2d'), {
			type: 'bar',
			plugins: [iconPlugin],
			data: {
				labels: topApps.map((a) => a.name),
				datasets: [
					{
						label: 'Temps',
						data: topApps.map((a) => formatDurationDecimal(a.timeMs)),
						backgroundColor: topApps.map((a) => getAppColor(a.name, a.score)),
						borderRadius: 4
					}
				]
			},
			options: {
				responsive: true,
				maintainAspectRatio: false,
				plugins: { legend: { display: false }, tooltip: { callbacks: { label: HHMM_TOOLTIP } } },
				scales: {
					y: {
						beginAtZero: true,
						grid: { color: 'rgba(255,255,255,0.1)' },
						ticks: { color: '#ccc', callback: (val) => val + 'h' }
					},
					x: {
						grid: { display: false },
						ticks: {
							color: '#ccc',
							maxRotation: 30,
							minRotation: 0,
							padding: 4
						}
					}
				},
				layout: { padding: { bottom: 30 } }
			}
		});
	}

	// 2. Category Pie Chart (Colored by fixed category dictionary)
	const catGroups = {};
	appsArray.forEach((a) => {
		if (!catGroups[a.category]) catGroups[a.category] = { timeMs: 0, score: a.score };
		catGroups[a.category].timeMs += a.timeMs;
	});

	const catLabels = Object.keys(catGroups);
	const pieCtx = $id('category_pie_chart');
	if (pieCtx) {
		if (catPieChart) catPieChart.destroy();
		catPieChart = new Chart(pieCtx.getContext('2d'), {
			type: 'doughnut',
			data: {
				labels: catLabels,
				datasets: [
					{
						data: catLabels.map((l) => formatDurationDecimal(catGroups[l].timeMs)),
						backgroundColor: catLabels.map((l) => getCategoryColor(l, catGroups[l].score)),
						borderWidth: 0
					}
				]
			},
			options: {
				responsive: true,
				maintainAspectRatio: false,
				plugins: {
					legend: { position: 'right', labels: { color: '#ccc' } },
					tooltip: { callbacks: { label: HHMM_TOOLTIP } }
				}
			}
		});
	}

	// 3. Stacked Timeline Chart (Colored by fixed category dictionary)
	const tlCtx = $id('timeline_stacked_chart');
	if (tlCtx) {
		$id('timeline_chart_title').textContent =
			currentPeriod === 'day' ? _t('ui_apps.chart_title_day') : _t('ui_apps.chart_title_period');

		let tlKeys = Object.keys(aggregatedData.timeline);
		if (currentPeriod === 'day') tlKeys.sort((a, b) => parseInt(a) - parseInt(b));
		else tlKeys.reverse();

		const uniqueCats = new Set();
		tlKeys.forEach((k) =>
			Object.keys(aggregatedData.timeline[k]).forEach((c) => uniqueCats.add(c))
		);

		const datasets = Array.from(uniqueCats).map((catName) => {
			const data = tlKeys.map((k) =>
				formatDurationDecimal(aggregatedData.timeline[k][catName] || 0)
			);
			let catScore = 0;
			for (const a of appsArray) {
				if (a.category === catName) {
					catScore = a.score;
					break;
				}
			}

			return {
				label: catName,
				data: data,
				backgroundColor: getCategoryColor(catName, catScore),
				borderWidth: 0
			};
		});

		if (timelineChart) timelineChart.destroy();
		timelineChart = new Chart(tlCtx.getContext('2d'), {
			type: 'bar',
			data: {
				labels: tlKeys.map((k) => (currentPeriod === 'day' ? k + 'h' : k)),
				datasets: datasets
			},
			options: {
				responsive: true,
				maintainAspectRatio: false,
				plugins: { legend: { display: false }, tooltip: { callbacks: { label: HHMM_TOOLTIP } } },
				scales: {
					x: { stacked: true, grid: { display: false }, ticks: { color: '#ccc' } },
					y: {
						stacked: true,
						grid: { color: 'rgba(255,255,255,0.1)' },
						ticks: { color: '#ccc', callback: (val) => val + 'h' }
					}
				}
			}
		});
	}
}

function renderDashboard() {
	try {
		const aggData = getAggregatedData();
		// Cache so toolbar toggles (heatmap mode, future filters) can re-render
		// derived charts without re-aggregating the manifest.
		window._lastAggData = aggData;

		let totalTimeMs = 0;
		let totalSwitches = 0;
		let prodScoreSum = 0;
		let prodWeightSum = 0;
		const appsArray = [];

		for (const [appName, appData] of Object.entries(aggData.apps)) {
			totalTimeMs += appData.time_ms;

			if (appData.switches) {
				Object.values(appData.switches).forEach((count) => (totalSwitches += count));
			}

			if (appName !== 'SYSTEM_SLEEP' && appName !== 'SYSTEM_LOCK' && appName !== 'idle_start') {
				const typingProp = appData.time_ms > 0 ? (appData.typing_time / appData.time_ms) * 100 : 0;
				const catData = getAppCategory(appName, appData.category);

				prodScoreSum += catData.score * appData.time_ms;
				prodWeightSum += appData.time_ms;

				let topDestinations = Object.entries(appData.switches || {})
					.sort((a, b) => b[1] - a[1])
					.slice(0, 3)
					.map((e) => `${escapeHtml(e[0])} (${e[1]})`);

				const focus_min = appData.time_ms / 60000;
				const density   = focus_min > 0 ? (appData.chars || 0) / focus_min : 0;
				const focus_lat_mean = (appData.focus_latency_count || 0) > 0
					? (appData.focus_latency_sum_ms / appData.focus_latency_count) : 0;
				const hs_pct = (appData.chars || 0) > 0
					? ((appData.hs_chars || 0) / appData.chars) * 100 : 0;

				appsArray.push({
					name: appName,
					category: catData.type,
					score: catData.score,
					timeMs: appData.time_ms,
					chars: appData.chars || 0,
					typingProp: typingProp,
					density: density,
					sessions: appData.session_count || 0,
					focus_lat_mean: focus_lat_mean,
					hs_pct: hs_pct,
					destinations: topDestinations.join(', ') || '-'
				});
			}
		}

		let finalProd = prodWeightSum > 0 ? (prodScoreSum / (prodWeightSum * 2)) * 100 : 0;
		const scoreClass = finalProd > 20 ? 'positive' : finalProd < -20 ? 'negative' : 'neutral';

		const elTotal = $id('kpi-total-time');
		if (elTotal) elTotal.textContent = formatDuration(totalTimeMs);

		const elProd = $id('kpi-productivity');
		if (elProd) {
			elProd.innerHTML = `<span class="score-badge ${scoreClass}" style="font-size: 1.2em; padding: 5px 15px;">${Math.round(finalProd)}%</span>`;
		}

		$id('kpi-switches').textContent = totalSwitches;
		$id('kpi-unlocks').textContent = aggData._sys.unlock || 0;

		let topWifi = '--';
		if (aggData._sys.wifi && Object.keys(aggData._sys.wifi).length > 0) {
			topWifi = Object.entries(aggData._sys.wifi).sort((a, b) => b[1] - a[1])[0][0];
		}
		$id('kpi-wifi').textContent = topWifi;

		// ── Second KPI row (time / rhythm) ─────────────────────────────────
		const r = aggData.rich || {};
		const rt = r.time || {};
		const rs = r.sessions || {};
		const passive_ms = (rt.passive_locked_ms || 0) + (rt.passive_sleep_ms || 0);
		const focus_minus_passive = Math.max(0, (rt.focus_ms || 0) - passive_ms);
		const active_ratio = focus_minus_passive > 0
			? ((rt.active_ms || 0) / focus_minus_passive) * 100 : 0;

		const setText = (id, txt) => { const el = $id(id); if (el) el.textContent = txt; };
		const setHtml = (id, html) => { const el = $id(id); if (el) el.innerHTML = html; };

		setText('kpi-active-time', formatDuration(rt.active_ms || 0));
		setText('kpi-active-ratio',
			focus_minus_passive > 0 ? `${active_ratio.toFixed(1)}% du focus net` : '—');

		setText('kpi-passive-time', passive_ms > 0 ? formatDuration(passive_ms) : '—');
		setText('kpi-passive-detail',
			passive_ms > 0
				? `verrou ${formatDuration(rt.passive_locked_ms || 0)} · veille ${formatDuration(rt.passive_sleep_ms || 0)}`
				: _t('ui_apps.kpi_no_lock'));

		// First / last typed
		const fmtMin = (m) => m && m.str ? m.str : '—';
		const first = r.day_first, last = r.day_last;
		if (first && last) {
			setHtml('kpi-day-bounds', `${fmtMin(first)} → ${fmtMin(last)}`);
			// Amplitude: minutes between first and last across multi-day spans is
			// computed naively as (last - first) clock minutes; for multi-day
			// ranges we surface the per-day amplitude using earliest first-of-day
			// and latest last-of-day as a representative window.
			let amp_min;
			if (first.date === last.date) {
				amp_min = (last.hh - first.hh) * 60 + (last.mm - first.mm);
			} else {
				// Multi-day: use last-of-period − first-of-period clock distance
				amp_min = (last.hh - first.hh) * 60 + (last.mm - first.mm);
			}
			if (amp_min < 0) amp_min += 24 * 60;
			setText('kpi-day-amplitude',
				`amplitude ${Math.floor(amp_min / 60)}h${String(amp_min % 60).padStart(2, '0')}`);
		} else {
			setText('kpi-day-bounds', '—');
			setText('kpi-day-amplitude', _t('ui_apps.kpi_no_keystrokes'));
		}

		// Longest session
		if ((rs.longest_ms || 0) > 0) {
			setText('kpi-longest-session', formatDuration(rs.longest_ms));
			setText('kpi-longest-session-app',
				rs.longest_app ? _t('ui_apps.kpi_in_app').replace('{name}', rs.longest_app) : '');
		} else {
			setText('kpi-longest-session', '—');
			setText('kpi-longest-session-app', _t('ui_apps.kpi_no_session'));
		}

		// Sessions count + mean
		const session_mean_ms = (rs.count || 0) > 0 ? (rs.total_active_ms || 0) / rs.count : 0;
		setText('kpi-sessions-count', String(rs.count || 0));
		setText('kpi-sessions-mean',
			session_mean_ms > 0 ? _t('ui_apps.kpi_session_mean').replace('{dur}', formatDuration(session_mean_ms)) : '—');

		// Density: chars / focus minute
		const density_cpm = (rt.focus_ms || 0) > 0
			? ((r.typing && r.typing.chars) || 0) / (rt.focus_ms / 60000) : 0;
		setText('kpi-density', density_cpm > 0 ? `${density_cpm.toFixed(0)}` : '—');
		setText('kpi-density-detail',
			density_cpm > 0 ? _t('ui_apps.kpi_car_per_min') : _t('ui_apps.kpi_no_keystrokes'));

		// ── Multitâche / context-switching KPIs ───────────────────────────
		// Compute aggregates across the period from appsArray + aggData.
		const apps_by_time = [...appsArray].sort((a, b) => b.timeMs - a.timeMs);
		const sum_focus_ms = apps_by_time.reduce((s, a) => s + (a.timeMs || 0), 0);

		// App-hopping rate = switches / focus-minute. Focus-minute is the
		// "time you actually had an app at the foreground" minus passive.
		const focus_min_eff = focus_minus_passive / 60000;
		const hopping_rate = focus_min_eff > 0 ? totalSwitches / focus_min_eff : 0;
		setText('kpi-hopping-rate',
			focus_min_eff > 0 ? `${hopping_rate.toFixed(1)}` : '—');
		setText('kpi-hopping-detail',
			focus_min_eff > 0 ? _t('ui_apps.kpi_hopping_detail') : _t('ui_apps.kpi_no_focus'));

		// Profondeur moyenne par app = Σ app_time / Σ switches
		const depth_mean_ms = totalSwitches > 0 ? sum_focus_ms / totalSwitches : 0;
		setText('kpi-depth-mean',
			depth_mean_ms > 0 ? formatDuration(depth_mean_ms) : '—');
		setText('kpi-depth-detail',
			depth_mean_ms > 0
				? _t('ui_apps.kpi_switches_between').replace('{n}', totalSwitches)
				: _t('ui_apps.kpi_no_switch'));

		// Top trio
		const top3 = apps_by_time.slice(0, 3);
		const top3_share = sum_focus_ms > 0
			? (top3.reduce((s, a) => s + a.timeMs, 0) / sum_focus_ms) * 100 : 0;
		setText('kpi-top-trio-share',
			top3.length > 0 ? `${top3_share.toFixed(0)}%` : '—');
		setHtml('kpi-top-trio-list',
			top3.length > 0
				? top3.map(a => escapeHtml(a.name)).join(' · ')
				: '—');

		// App pivot = app with the most distinct outgoing destinations
		let pivot = null, pivot_dests = 0;
		for (const [appName, appData] of Object.entries(aggData.apps)) {
			const distinct = appData.switches ? Object.keys(appData.switches).length : 0;
			if (distinct > pivot_dests) {
				pivot = appName;
				pivot_dests = distinct;
			}
		}
		setText('kpi-pivot-app',
			pivot ? pivot : '—');
		setText('kpi-pivot-detail',
			pivot ? _t('ui_apps.kpi_towards_apps').replace('{n}', pivot_dests) : _t('ui_apps.kpi_no_switch'));

		// Index focus = part du temps focus dans la top app
		const focus_index = (sum_focus_ms > 0 && apps_by_time.length > 0)
			? (apps_by_time[0].timeMs / sum_focus_ms) * 100 : 0;
		setText('kpi-focus-index',
			apps_by_time.length > 0 ? `${focus_index.toFixed(0)}%` : '—');
		setText('kpi-focus-index-detail',
			apps_by_time.length > 0 ? _t('ui_apps.kpi_in_app').replace('{name}', apps_by_time[0].name) : '');

		// Context volume = sum of switching events on the period
		setText('kpi-context-volume', String(totalSwitches));
		setText('kpi-context-detail',
			(r.time && r.time.passive_count > 0)
				? `+ ${r.time.passive_count} verrou(s) / veille(s)`
				: _t('ui_apps.kpi_app_switches'));

		// ── Records personnels (period-best scores) ───────────────────────
		const rb = r.bursts      || {};
		const re = r.ergonomics  || {};
		const rty = r.typing     || {};
		setText('kpi-rec-burst',
			(rb.max_cpm || 0) > 0 ? `${rb.max_cpm.toFixed(0)} CPM` : '—');
		setText('kpi-rec-burst-detail',
			(rb.count || 0) > 0 ? _t('ui_apps.kpi_bursts_count').replace('{n}', rb.count) : _t('ui_apps.kpi_no_burst'));
		setText('kpi-rec-burst-chars',
			(rb.max_chars || 0) > 0 ? format_int(rb.max_chars) : '—');
		setText('kpi-rec-burst-chars-detail',
			(rb.max_chars || 0) > 0 ? _t('ui_apps.kpi_chars_in_a_row') : '');

		setText('kpi-rec-session',
			(rs.longest_ms || 0) > 0 ? formatDuration(rs.longest_ms) : '—');
		setText('kpi-rec-session-detail',
			rs.longest_app ? _t('ui_apps.kpi_in_app').replace('{name}', rs.longest_app) : '');

		setText('kpi-rec-finger-streak',
			(re.same_finger_streak_max || 0) > 0
				? `${re.same_finger_streak_max} touches` : '—');
		setText('kpi-rec-finger-streak-detail',
			(re.same_hand_streak_max || 0) > 0
				? `main : ${re.same_hand_streak_max} touches` : '');

		setText('kpi-rec-cascade',
			(rty.cascade_max_len || 0) > 0
				? `${rty.cascade_max_len} backspaces` : '—');  // "backspaces" is a technical term, kept as-is
		setText('kpi-rec-cascade-detail',
			(rty.cascade_count_total || 0) > 0
				? _t('ui_apps.kpi_cascades_period').replace('{n}', rty.cascade_count_total) : '');

		// Top day by chars
		let best_day = null, best_day_chars = 0;
		Object.entries((r.by_date || {})).forEach(([date_str, day]) => {
			if ((day.chars || 0) > best_day_chars) {
				best_day_chars = day.chars;
				best_day = date_str;
			}
		});
		setText('kpi-rec-day-chars',
			best_day_chars > 0 ? format_int(best_day_chars) : '—');
		setText('kpi-rec-day-chars-detail',
			best_day ? _t('ui_apps.kpi_day_best').replace('{date}', formatDisplayDate(best_day)) : '');

		// ── Typing × Temps (#40-43, 49) ───────────────────────────────────
		const fl   = r.focus_latency || { sum_ms: 0, count: 0 };
		const flMs = (fl.count || 0) > 0 ? fl.sum_ms / fl.count : 0;
		setText('kpi-tx-focus-lat', flMs > 0 ? `${flMs.toFixed(0)} ms` : '—');
		setText('kpi-tx-focus-lat-detail',
			(fl.count || 0) > 0 ? _t('ui_apps.kpi_focus_taken').replace('{n}', fl.count) : _t('ui_apps.kpi_not_measured'));

		const layoutsCount = Object.keys(r.layouts || {}).length;
		setText('kpi-tx-layouts', String(layoutsCount));
		const topLayout = Object.entries(r.layouts || {}).sort((a, b) => b[1] - a[1])[0];
		setText('kpi-tx-layouts-detail',
			topLayout ? _t('ui_apps.kpi_top_layout').replace('{name}', topLayout[0]) : '—');

		setText('kpi-tx-long-sessions', String(r.long_sessions || 0));
		setText('kpi-tx-long-sessions-detail',
			(r.long_sessions || 0) > 0 ? _t('ui_apps.kpi_app_days_90') : _t('ui_apps.kpi_no_long_session'));

		const totalChars   = (r.typing && r.typing.chars) || 0;
		const autoRepCount = (r.typing && r.typing.auto_repeat_count) || 0;
		const arPct = totalChars > 0 ? (autoRepCount / totalChars) * 100 : 0;
		setText('kpi-tx-autorepeat', totalChars > 0 ? `${arPct.toFixed(1)} %` : '—');
		setText('kpi-tx-autorepeat-detail',
			autoRepCount > 0 ? `${format_int(autoRepCount)} touches répétées` : _t('ui_apps.kpi_no_repeat'));

		// Worst app for errors (#49): highest bs_total / chars (min 200 chars to avoid noise)
		let wErrApp = null, wErrPct = 0;
		Object.entries(aggData.apps || {}).forEach(([name, a]) => {
			if ((a.chars || 0) >= 200) {
				const p = ((a.bs_total || 0) / a.chars) * 100;
				if (p > wErrPct) { wErrPct = p; wErrApp = name; }
			}
		});
		setText('kpi-tx-error-app', wErrApp || '—');
		setText('kpi-tx-error-app-detail',
			wErrApp ? `${wErrPct.toFixed(1)} % de backspaces` : _t('ui_apps.kpi_no_enough_typing'));

		// Worst app for recovery (#50)
		let wRecApp = null, wRecMs = 0;
		Object.entries(aggData.apps || {}).forEach(([name, a]) => {
			if ((a.recovery_count || 0) >= 5) {
				const m = a.recovery_sum_ms / a.recovery_count;
				if (m > wRecMs) { wRecMs = m; wRecApp = name; }
			}
		});
		setText('kpi-tx-recovery-app', wRecApp || '—');
		setText('kpi-tx-recovery-app-detail',
			wRecApp ? `${wRecMs.toFixed(0)} ms en moyenne` : _t('ui_apps.kpi_no_enough_errors'));

		// CPM par catégorie (#47)
		(function renderCpmByCategory() {
			const canvas = document.getElementById('cpm_by_category_chart');
			if (!canvas || typeof Chart === 'undefined') return;
			const cats = Object.entries(r.by_category || {})
				.map(([cat, c]) => ({
					cat,
					cpm: (c.time_ms || 0) > 0 ? (c.chars || 0) / (c.time_ms / 60000) : 0,
				}))
				.filter((x) => x.cpm > 0)
				.sort((a, b) => b.cpm - a.cpm);
			if (window._cpmByCatChart) window._cpmByCatChart.destroy();
			if (cats.length === 0) return;
			window._cpmByCatChart = new Chart(canvas.getContext('2d'), {
				type: 'bar',
				data: {
					labels: cats.map((c) => c.cat),
					datasets: [{
						label: 'CPM',
						data: cats.map((c) => +c.cpm.toFixed(0)),
						backgroundColor: cats.map((c) => getCategoryColor(c.cat, 0)),
						borderRadius: 4,
					}],
				},
				options: {
					responsive: true, maintainAspectRatio: false,
					plugins: { legend: { display: false } },
					scales: {
						x: { grid: { display: false }, ticks: { color: '#ccc' } },
						y: { beginAtZero: true, grid: { color: 'rgba(255,255,255,0.08)' }, ticks: { color: '#ccc' } }
					}
				}
			});
		})();

		// ── Productivité (#20–22) ─────────────────────────────────────────
		const ps   = r.prod_split || { positive_ms: 0, neutral_ms: 0, negative_ms: 0 };
		const psSum = (ps.positive_ms || 0) + (ps.neutral_ms || 0) + (ps.negative_ms || 0);
		const elProdBar = $id('kpi-prod-bar');
		if (elProdBar) {
			if (psSum > 0) {
				const pPos = (ps.positive_ms / psSum) * 100;
				const pNeu = (ps.neutral_ms  / psSum) * 100;
				const pNeg = (ps.negative_ms / psSum) * 100;
				elProdBar.innerHTML =
					`<div title="Productif" style="background:#30D158;width:${pPos}%"></div>` +
					`<div title="Neutre"    style="background:#8e8e93;width:${pNeu}%"></div>` +
					`<div title="Distraction" style="background:#FF453A;width:${pNeg}%"></div>`;
				setText('kpi-prod-bar-detail',
					_t('ui_apps.kpi_productive').replace('{p}', pPos.toFixed(0)).replace('{n}', pNeu.toFixed(0)).replace('{d}', pNeg.toFixed(0)));
			} else {
				elProdBar.innerHTML = '';
				setText('kpi-prod-bar-detail', _t('ui_apps.kpi_no_data'));
			}
		}

		// #21 Best hour by productivity (score-weighted)
		let bestHour = null, bestHourScore = -Infinity;
		Object.entries(r.by_hour || {}).forEach(([hh, slot]) => {
			if ((slot.time_ms || 0) > 0) {
				const avg = (slot.score_x_ms || 0) / slot.time_ms;
				if (avg > bestHourScore) { bestHourScore = avg; bestHour = hh; }
			}
		});
		if (bestHour != null) {
			setText('kpi-best-hour', `${bestHour}h`);
			setText('kpi-best-hour-detail',
				_t('ui_apps.kpi_best_hour_score').replace('{score}', bestHourScore.toFixed(2)));
		} else {
			setText('kpi-best-hour', '—');
			setText('kpi-best-hour-detail', _t('ui_apps.kpi_no_focus_tracked'));
		}

		// #22 Dominant category per weekday — render as compact 7-day rundown
		const DOW_LABELS = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];
		const wkLines = [];
		let domToday = null;
		const todayDow = ((new Date()).getDay() + 6) % 7;
		Object.entries(r.weekday_category || {}).forEach(([dow, cats]) => {
			let topCat = null, topMs = 0;
			Object.entries(cats).forEach(([c, ms]) => {
				if (ms > topMs) { topMs = ms; topCat = c; }
			});
			if (topCat) {
				wkLines.push(`${DOW_LABELS[+dow]} : ${topCat}`);
				if (+dow === todayDow) domToday = topCat;
			}
		});
		setText('kpi-dom-cat', domToday || (wkLines.length > 0 ? wkLines[0].split(' : ')[1] : '—'));
		setText('kpi-dom-cat-detail',
			wkLines.length > 0 ? wkLines.join(' · ') : _t('ui_apps.kpi_no_day_data'));

		// ── Streaks (#58) ─────────────────────────────────────────────────
		// Compute the longest run of consecutive calendar days where the
		// criterion holds. Uses ALL manifest dates (not just the filtered
		// period) so the streak is meaningful as a global record.
		(function renderStreaks() {
			const allKeys = Object.keys(manifestData || {})
				.map((k) => ({ key: k, ts: parseDateKey(k) }))
				.filter((d) => !isNaN(d.ts))
				.sort((a, b) => a.ts - b.ts);
			const dayChars  = {};
			const dayActive = {};
			allKeys.forEach((d) => {
				let chars = 0, active = 0;
				Object.entries(manifestData[d.key] || {}).forEach(([n, a]) => {
					if (n === '_sys' || n === '_system') return;
					chars  += a.chars || 0;
					active += a.time  || 0;
				});
				dayChars[d.key]  = chars;
				dayActive[d.key] = active;
			});
			const longestRun = (predicate) => {
				let best = 0, cur = 0, prevTs = null;
				allKeys.forEach((d) => {
					const ok = predicate(d.key);
					if (ok && (prevTs == null || d.ts - prevTs <= 86400000 + 60000)) cur += 1;
					else cur = ok ? 1 : 0;
					if (cur > best) best = cur;
					prevTs = d.ts;
				});
				return best;
			};
			const streakChars = longestRun((k) => (dayChars[k] || 0) >= 1000);
			const streakFocus = longestRun((k) => (dayActive[k] || 0) >= 30 * 60 * 1000);
			setText('kpi-streak-chars', `${streakChars} j`);
			setText('kpi-streak-chars-detail', streakChars > 0 ? _t('ui_apps.kpi_streak_chars') : _t('ui_apps.kpi_never_reached'));
			setText('kpi-streak-focus', `${streakFocus} j`);
			setText('kpi-streak-focus-detail', streakFocus > 0 ? _t('ui_apps.kpi_streak_focus') : _t('ui_apps.kpi_never_reached'));
		})();

		// ── Objectif quotidien (#60) ──────────────────────────────────────
		(function renderGoal() {
			// localStorage is unavailable in about:blank-origin WebViews
			// (Hammerspoon serves HTML via `wv:html()`, no real origin), so
			// we keep the goal in a window-scoped fallback that lives for the
			// lifetime of the open dashboard. Persistence across reloads would
			// need a Lua-side bridge — out of scope for the MVP.
			window._goalStore = window._goalStore || {};
			let goalMin = window._goalStore.daily_min || 120;

			const todayKey = currentSelectedDate || (Object.keys(manifestData).sort().slice(-1)[0]);
			let todayActiveMs = 0;
			if (todayKey && manifestData[todayKey]) {
				Object.entries(manifestData[todayKey]).forEach(([n, a]) => {
					if (n === '_sys' || n === '_system') return;
					todayActiveMs += a.time || 0;
				});
			}
			const todayMin = todayActiveMs / 60000;
			const pct = Math.min(100, (todayMin / goalMin) * 100);

			setText('kpi-goal-value', `${goalMin} min`);
			setText('kpi-goal-progress', `${todayMin.toFixed(0)} / ${goalMin} min`);
			const bar = document.getElementById('kpi-goal-bar');
			if (bar) bar.style.width = `${pct}%`;
			setText('kpi-goal-detail',
				pct >= 100 ? _t('ui_apps.goal_reached') : _t('ui_apps.goal_remaining').replace('{pct}', (100 - pct).toFixed(0)));

			const valEl = document.getElementById('kpi-goal-value');
			if (valEl && !valEl._bound) {
				valEl.addEventListener('click', () => {
					const next = prompt(_t('ui_apps.goal_prompt'), String(goalMin));
					const n = parseInt(next || '', 10);
					if (isFinite(n) && n > 0 && n < 24 * 60) {
						window._goalStore.daily_min = n;
						renderDashboard();
					}
				});
				valEl._bound = true;
			}
		})();

		// ── Système & matériel (#13–19) ──────────────────────────────────
		const sys = r.system || {};
		const lock_ms  = rt.passive_locked_ms || 0;
		const sleep_ms = rt.passive_sleep_ms  || 0;
		setText('kpi-sys-passive', String(rt.passive_count || 0));
		setText('kpi-sys-passive-detail',
			(rt.passive_count || 0) > 0
				? _t('ui_apps.kpi_lock_sleep_cumul').replace('{dur}', formatDuration(lock_ms + sleep_ms))
				: _t('ui_apps.kpi_no_lock'));

		setText('kpi-sys-lock-vs-sleep',
			(lock_ms + sleep_ms) > 0
				? `${formatDuration(lock_ms)} / ${formatDuration(sleep_ms)}`
				: '—');
		setText('kpi-sys-lock-vs-sleep-detail',
			(lock_ms + sleep_ms) > 0 ? _t('ui_apps.kpi_lock_vs_sleep') : '');

		setText('kpi-sys-wifi', String(sys.wifi_changes || 0));
		setText('kpi-sys-wifi-detail',
			(sys.wifi_changes || 0) > 0 ? _t('ui_apps.kpi_wifi_switches') : _t('ui_apps.kpi_no_mobility'));

		const bat_avg = (sys.battery_count || 0) > 0
			? Math.round(sys.battery_sum / sys.battery_count) : null;
		setText('kpi-sys-battery',
			bat_avg != null ? `${bat_avg}%` : '—');
		setText('kpi-sys-battery-detail',
			(sys.battery_min != null)
				? `min ${Math.round(sys.battery_min)}% · max ${Math.round(sys.battery_max)}%`
				: _t('ui_apps.kpi_no_data'));

		const muted_pct = (rt.focus_ms || 0) > 0
			? ((sys.audio_muted_ms || 0) / rt.focus_ms) * 100 : 0;
		setText('kpi-sys-mute',
			(sys.audio_muted_ms || 0) > 0
				? formatDuration(sys.audio_muted_ms) : '—');
		setText('kpi-sys-mute-detail',
			(sys.audio_muted_ms || 0) > 0
				? _t('ui_apps.kpi_pct_focus_time').replace('{pct}', muted_pct.toFixed(0))
				: _t('ui_apps.kpi_no_mute'));

		setText('kpi-sys-spaces', String(sys.space_switches || 0));
		setText('kpi-sys-spaces-detail',
			(sys.space_switches || 0) > 0 ? _t('ui_apps.kpi_space_switches') : '—');

		setText('kpi-sys-night', String(sys.night_wake_count || 0));
		setText('kpi-sys-night-detail',
			(sys.night_wake_count || 0) > 0 ? _t('ui_apps.kpi_night_wakes') : _t('ui_apps.kpi_sleep_intact'));

		const awakeMs = rt.awake_ms || 0;
		setText('kpi-sys-awake', awakeMs > 0 ? formatDuration(awakeMs) : '—');
		setText('kpi-sys-awake-detail',
			awakeMs > 0
				? (currentCountAwake ? _t('ui_apps.kpi_awake_included') : _t('ui_apps.kpi_awake_excluded'))
				: _t('ui_apps.kpi_never_active'));

		// Hour × weekday heatmap (decoupled from the existing day-only timeline)
		renderHourWeekdayHeatmap(aggData);

		// Ribbon Toggl-style (#25)
		renderRibbon(aggData);

		// Sankey-like flow between apps (#26)
		renderSankey(aggData);

		// Radial top 8 (#27) and burst histogram (#34)
		renderRadialTop8(appsArray);
		renderBurstHistogram(aggData);

		// Daily trajectories (#29-32)
		renderDailyTrajectories(aggData);

		// Day timeline (#33) and app-pairs table (#36)
		renderDayTimeline();
		renderAppPairsTable(aggData);

		// Top sessions (#37) and top days (#38)
		renderTopSessionsTable();
		renderTopDaysTable(aggData);

		// Session boxplots (#28) and top windows table (#39)
		renderSessionBoxplots(aggData);
		renderTopWindowsTable(aggData);

		// Period comparator (#55) — render delta panel if active
		renderComparator(aggData);

		// 12-month activity calendar — always covers the last 365 days,
		// independent of the period filter.
		renderActivityCalendar();

		// CPM by hour — typing speed across the day's hours
		renderCpmByHourChart(aggData);

		appsArray.sort((a, b) => b.timeMs - a.timeMs);
		updateCharts(appsArray, aggData);

		const tbody = $id('apps-tbody');
		if (tbody) tbody.innerHTML = '';

		if (appsArray.length === 0) {
			if (tbody)
				tbody.innerHTML = `<tr><td colspan="9" style="text-align: center;">${_t('ui_apps.empty_period')}</td></tr>`;
			return;
		}

		appsArray.forEach((app) => {
			const tr = document.createElement('tr');
			tr.title = _t('ui_apps.row_tooltip').replace('{name}', app.name);
			tr.addEventListener('click', (ev) => {
				// Ignore clicks bubbling up from the category cell (which has its own handler)
				if (ev.target && ev.target.closest('td.app-cat-cell')) return;
				openAppDrilldown(app.name);
			});

			const tdName = document.createElement('td');
			tdName.className = 'app-name-cell';
			tdName.innerHTML = `<strong>${escapeHtml(app.name)}</strong>`;
			tr.appendChild(tdName);

			const tdCat = document.createElement('td');
			tdCat.className = 'app-cat-cell';
			tdCat.innerHTML = `<span style="font-size: 0.85em; color: var(--text-muted); cursor: pointer;" title="Modifier la catégorie">${escapeHtml(app.category)} ✎</span>`;
			tdCat.addEventListener('click', (ev) => {
				ev.stopPropagation();
				postBridge({ action: 'edit', app: app.name, cat: app.category, score: app.score });
			});
			tr.appendChild(tdCat);

			const tdTime = document.createElement('td');
			tdTime.className = 'app-time-cell';
			tdTime.textContent = formatDuration(app.timeMs);
			tr.appendChild(tdTime);

			const tdType = document.createElement('td');
			tdType.className = 'app-type-cell';
			tdType.textContent = app.typingProp.toFixed(1) + '%';
			tr.appendChild(tdType);

			const tdDensity = document.createElement('td');
			tdDensity.className = 'app-time-cell';
			tdDensity.textContent = app.density > 0 ? `${app.density.toFixed(0)} c/min` : '—';
			tr.appendChild(tdDensity);

			const tdSessions = document.createElement('td');
			tdSessions.className = 'app-time-cell';
			tdSessions.textContent = app.sessions > 0 ? String(app.sessions) : '—';
			tr.appendChild(tdSessions);

			const tdLat = document.createElement('td');
			tdLat.className = 'app-time-cell';
			tdLat.textContent = app.focus_lat_mean > 0 ? `${Math.round(app.focus_lat_mean)} ms` : '—';
			tr.appendChild(tdLat);

			const tdHsPct = document.createElement('td');
			tdHsPct.className = 'app-type-cell';
			tdHsPct.textContent = app.hs_pct > 0 ? `${app.hs_pct.toFixed(1)}%` : '—';
			tr.appendChild(tdHsPct);

			// #51 SFB max for this app on the period
			const tdSfb = document.createElement('td');
			tdSfb.style.textAlign = 'right';
			const _sfbApp = aggData.apps[app.name] || {};
			tdSfb.textContent = (_sfbApp.same_finger_streak_max || 0) > 0 ? String(_sfbApp.same_finger_streak_max) : '—';
			tr.appendChild(tdSfb);

			// #52 Modifier hold mean ms for this app
			const tdHold = document.createElement('td');
			tdHold.style.textAlign = 'right';
			const _hSum = _sfbApp.kc_hold_sum_ms || 0;
			const _hCnt = _sfbApp.kc_hold_count  || 0;
			tdHold.textContent = _hCnt > 0 ? `${Math.round(_hSum / _hCnt)} ms` : '—';
			tr.appendChild(tdHold);

			const tdDest = document.createElement('td');
			tdDest.className = 'app-dest-cell';
			tdDest.innerHTML = app.destinations;
			tr.appendChild(tdDest);

			if (tbody) tbody.appendChild(tr);
		});
	} catch (err) {
		safeLog('error', 'Error rendering dashboard', err);
		// Surface the exception visibly — the WebView has no devtools so otherwise it's silent.
		let banner = document.getElementById('render-error-banner');
		if (!banner) {
			banner = document.createElement('div');
			banner.id = 'render-error-banner';
			banner.style.cssText = 'position:fixed;bottom:8px;left:8px;right:8px;z-index:9999;background:rgba(255,69,58,0.95);color:#fff;font:12px/1.4 system-ui;padding:8px 12px;border-radius:6px;white-space:pre-wrap;max-height:160px;overflow:auto;';
			document.body.appendChild(banner);
		}
		banner.textContent = `[render error] ${err && err.stack ? err.stack : err}`;
	}
}

// =====================================================
// =====================================================
// ======= 5/ Hour × Weekday Heatmap =======
// =====================================================
// =====================================================

// Active mode for the hour×weekday heatmap; flipped by setHourWeekdayMode().
let _hourWeekdayMode = 'chars'; // "chars" | "time"

const WEEKDAY_LABELS_FR = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];

/**
 * Renders a 24×7 heatmap of activity by hour-of-day × day-of-week. Reads
 * aggData.rich.hour_weekday and renders SVG cells coloured by intensity
 * relative to the period's max. Switches between "time spent" and
 * "characters typed" via the toolbar buttons above the container.
 * @param {Object} aggData - Result of getAggregatedData()
 */
function renderHourWeekdayHeatmap(aggData) {
	const container = document.getElementById('hour_weekday_heatmap_container');
	if (!container) return;
	const grid = (aggData && aggData.rich && aggData.rich.hour_weekday) || {};
	const mode = _hourWeekdayMode;

	// Determine grid bounds — 24 hours × 7 weekdays.
	const HOURS = Array.from({ length: 24 }, (_, h) => String(h).padStart(2, '0'));
	const W = 7, H = 24;

	// Find max for colour scaling
	let max_v = 0;
	HOURS.forEach((hh) => {
		for (let wd = 0; wd < W; wd++) {
			const cell = grid[`${hh}|${wd}`];
			if (!cell) continue;
			const v = mode === 'time' ? (cell.time_ms || 0) : (cell.chars || 0);
			if (v > max_v) max_v = v;
		}
	});

	if (max_v === 0) {
		container.innerHTML = `<div style="color:var(--text-muted);font-size:12px;padding:10px;">${_t('ui_apps.empty_activity')}</div>`;
		return;
	}

	const CELL = 24;     // px per cell
	const GAP = 2;
	const LABEL_LEFT = 38;
	const LABEL_TOP  = 18;
	const SVG_W = LABEL_LEFT + W * (CELL + GAP);
	const SVG_H = LABEL_TOP  + H * (CELL + GAP);

	// Heat: dark blue → orange → red, same palette as the keystroke heatmap.
	const heat = (v) => {
		if (v === 0) return '#1e1e2e';
		const t = Math.pow(v / max_v, 0.45);
		if (t < 0.5) {
			const tt = t * 2;
			return `rgb(${Math.round(30 + tt * 190)},${Math.round(50 + tt * 80)},${Math.round(130 - tt * 110)})`;
		}
		const tt = (t - 0.5) * 2;
		return `rgb(${Math.round(220 + tt * 35)},${Math.round(130 - tt * 110)},${Math.round(20 - tt * 20)})`;
	};

	let cells = '';
	let labels_x = '';
	for (let wd = 0; wd < W; wd++) {
		const cx = LABEL_LEFT + wd * (CELL + GAP) + CELL / 2;
		labels_x += `<text x="${cx}" y="14" text-anchor="middle" fill="#aaa" font-size="11" font-family="system-ui">${WEEKDAY_LABELS_FR[wd]}</text>`;
	}
	let labels_y = '';
	HOURS.forEach((hh, h_idx) => {
		const cy = LABEL_TOP + h_idx * (CELL + GAP) + CELL / 2 + 4;
		labels_y += `<text x="${LABEL_LEFT - 6}" y="${cy}" text-anchor="end" fill="#888" font-size="10" font-family="system-ui">${hh}h</text>`;
		for (let wd = 0; wd < W; wd++) {
			const cx = LABEL_LEFT + wd * (CELL + GAP);
			const cy2 = LABEL_TOP + h_idx * (CELL + GAP);
			const cell = grid[`${hh}|${wd}`];
			const v = !cell ? 0 : (mode === 'time' ? (cell.time_ms || 0) : (cell.chars || 0));
			const fill = heat(v);
			const tip_v = mode === 'time'
				? (v > 0 ? formatDuration(v) : '0')
				: (v > 0 ? `${v} car.` : '0');
			const tip = `${WEEKDAY_LABELS_FR[wd]} ${hh}h — ${tip_v}`;
			cells += `<rect x="${cx}" y="${cy2}" width="${CELL}" height="${CELL}" rx="3" fill="${fill}"><title>${tip}</title></rect>`;
		}
	});

	container.innerHTML =
		`<svg width="${SVG_W}" height="${SVG_H}" viewBox="0 0 ${SVG_W} ${SVG_H}" xmlns="http://www.w3.org/2000/svg">` +
			labels_x + labels_y + cells +
		`</svg>`;
}

/**
 * Renders the per-day Toggl-style ribbon: one row per day in the period, X = 0..24h,
 * each hour cell colored by the dominant category for that (day, hour) pair.
 * @param {object} aggData - aggregated rollup with rich.ribbon populated.
 */
function renderRibbon(aggData) {
	const container = document.getElementById('ribbon_container');
	const legend    = document.getElementById('ribbon_legend');
	if (!container) return;

	const ribbon = (aggData && aggData.rich && aggData.rich.ribbon) || {};
	const days = Object.keys(ribbon).sort(); // ascending date
	if (days.length === 0) {
		container.innerHTML = `<div style="color:var(--text-muted);font-size:12px;padding:10px;">${_t('ui_apps.empty_activity')}</div>`;
		if (legend) legend.innerHTML = '';
		return;
	}

	const HOURS      = Array.from({ length: 24 }, (_, h) => String(h).padStart(2, '0'));
	const CELL_W     = 22;
	const CELL_H     = 22;
	const ROW_GAP    = 4;
	const LABEL_LEFT = 92;
	const LABEL_TOP  = 16;
	const SVG_W = LABEL_LEFT + 24 * CELL_W + 8;
	const SVG_H = LABEL_TOP  + days.length * (CELL_H + ROW_GAP) + 4;

	const cats_seen = new Set();

	let header = '';
	for (let h = 0; h < 24; h++) {
		if (h % 3 === 0) {
			const x = LABEL_LEFT + h * CELL_W + CELL_W / 2;
			header += `<text x="${x}" y="12" text-anchor="middle" fill="#888" font-size="10" font-family="system-ui">${h}h</text>`;
		}
	}

	let rows = '';
	days.forEach((dateStr, rowIdx) => {
		const ribDay = ribbon[dateStr] || {};
		const y = LABEL_TOP + rowIdx * (CELL_H + ROW_GAP);
		// Day label (e.g. "Lun 04/05")
		const ts = parseDateKey(dateStr);
		const dow = ((new Date(ts).getDay() + 6) % 7);
		const dd = String(new Date(ts).getDate()).padStart(2, '0');
		const mm = String(new Date(ts).getMonth() + 1).padStart(2, '0');
		const label = `${WEEKDAY_LABELS_FR[dow]} ${dd}/${mm}`;
		rows += `<text x="${LABEL_LEFT - 8}" y="${y + CELL_H / 2 + 4}" text-anchor="end" fill="#aaa" font-size="11" font-family="system-ui">${label}</text>`;

		HOURS.forEach((hh, hi) => {
			const x = LABEL_LEFT + hi * CELL_W;
			const cellCats = ribDay[hh] || {};
			let topCat = null, topMs = 0, totalMs = 0;
			Object.entries(cellCats).forEach(([c, ms]) => {
				totalMs += ms;
				if (ms > topMs) { topMs = ms; topCat = c; }
			});
			const fill = topCat ? getCategoryColor(topCat, 0) : '#1e1e2e';
			if (topCat) cats_seen.add(topCat);
			// Opacity proportional to total minutes spent in that hour (capped at 1)
			const opacity = Math.min(1, totalMs / (60 * 60 * 1000)) || 0.05;
			const tip = topCat
				? `${label} · ${hh}h — ${topCat} (${formatDuration(totalMs)})`
				: `${label} · ${hh}h — inactif`;
			rows += `<rect x="${x}" y="${y}" width="${CELL_W - 1}" height="${CELL_H}" rx="2" fill="${fill}" fill-opacity="${opacity}"><title>${tip}</title></rect>`;
		});
	});

	container.innerHTML =
		`<svg width="${SVG_W}" height="${SVG_H}" viewBox="0 0 ${SVG_W} ${SVG_H}" xmlns="http://www.w3.org/2000/svg">` +
			header + rows +
		`</svg>`;

	if (legend) {
		legend.innerHTML = [...cats_seen].sort().map((c) => {
			const col = getCategoryColor(c, 0);
			return `<span style="display:inline-flex;align-items:center;gap:5px;"><span style="width:12px;height:12px;border-radius:3px;background:${col};"></span>${escapeHtml(c)}</span>`;
		}).join('');
	}
}

/**
 * Renders a sankey-like bipartite flow between top apps. Left column = source
 * apps, right column = destination apps; ribbon thickness ∝ switch count.
 * @param {object} aggData - aggregated rollup with .apps[X].switches.
 */
function renderSankey(aggData) {
	const container = document.getElementById('sankey_container');
	if (!container) return;

	// Flatten all (src, dst, count) edges
	const edges = [];
	Object.entries(aggData.apps || {}).forEach(([src, data]) => {
		Object.entries(data.switches || {}).forEach(([dst, count]) => {
			if (src !== dst && count > 0) edges.push({ src, dst, count });
		});
	});
	edges.sort((a, b) => b.count - a.count);
	const TOP_EDGES = edges.slice(0, 18);
	if (TOP_EDGES.length === 0) {
		container.innerHTML = `<div style="color:var(--text-muted);font-size:12px;padding:10px;">${_t('ui_apps.empty_switches')}</div>`;
		return;
	}

	// Collect unique apps on left and right
	const leftSet  = new Set(TOP_EDGES.map((e) => e.src));
	const rightSet = new Set(TOP_EDGES.map((e) => e.dst));
	const leftApps  = [...leftSet].sort((a, b) => {
		const sa = TOP_EDGES.filter((e) => e.src === a).reduce((s, e) => s + e.count, 0);
		const sb = TOP_EDGES.filter((e) => e.src === b).reduce((s, e) => s + e.count, 0);
		return sb - sa;
	});
	const rightApps = [...rightSet].sort((a, b) => {
		const sa = TOP_EDGES.filter((e) => e.dst === a).reduce((s, e) => s + e.count, 0);
		const sb = TOP_EDGES.filter((e) => e.dst === b).reduce((s, e) => s + e.count, 0);
		return sb - sa;
	});

	const NODE_W = 12;
	const ROW_H  = 32;
	const PAD_TOP = 12;
	const W = 720;
	const LEFT_X  = 200;
	const RIGHT_X = W - 200;
	const H = PAD_TOP * 2 + Math.max(leftApps.length, rightApps.length) * ROW_H;

	// Y for each app on each side
	const leftY  = {};
	const rightY = {};
	leftApps.forEach((n, i)  => (leftY[n]  = PAD_TOP + i * ROW_H + ROW_H / 2));
	rightApps.forEach((n, i) => (rightY[n] = PAD_TOP + i * ROW_H + ROW_H / 2));

	const max_count = TOP_EDGES[0].count;
	let svg = '';

	// Ribbons
	TOP_EDGES.forEach((e) => {
		const y1 = leftY[e.src];
		const y2 = rightY[e.dst];
		const thickness = Math.max(1.5, (e.count / max_count) * 14);
		const cx1 = LEFT_X + 80;
		const cx2 = RIGHT_X - 80;
		const path = `M ${LEFT_X + NODE_W} ${y1} C ${cx1} ${y1}, ${cx2} ${y2}, ${RIGHT_X} ${y2}`;
		const col = getAppColor(e.src, 0);
		svg += `<path d="${path}" stroke="${col}" stroke-width="${thickness}" fill="none" stroke-opacity="0.55"><title>${escapeHtml(e.src)} → ${escapeHtml(e.dst)} (${e.count})</title></path>`;
	});

	// Left nodes + labels
	leftApps.forEach((n) => {
		const y = leftY[n];
		const col = getAppColor(n, 0);
		svg += `<rect x="${LEFT_X}" y="${y - 10}" width="${NODE_W}" height="20" rx="3" fill="${col}"></rect>`;
		svg += `<text x="${LEFT_X - 6}" y="${y + 4}" text-anchor="end" fill="#ddd" font-size="11" font-family="system-ui">${escapeHtml(n)}</text>`;
	});

	// Right nodes + labels
	rightApps.forEach((n) => {
		const y = rightY[n];
		const col = getAppColor(n, 0);
		svg += `<rect x="${RIGHT_X - NODE_W}" y="${y - 10}" width="${NODE_W}" height="20" rx="3" fill="${col}"></rect>`;
		svg += `<text x="${RIGHT_X + 6}" y="${y + 4}" text-anchor="start" fill="#ddd" font-size="11" font-family="system-ui">${escapeHtml(n)}</text>`;
	});

	container.innerHTML = `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">${svg}</svg>`;
}

let radialTop8Chart = null;
let burstHistogramChart = null;
let dailyTrioChart = null;
let dailyActiveRatioChart = null;
let dailyCategoriesChart = null;
let dailyBoundsChart = null;

/**
 * Renders the per-day annotated timeline (#33). For the currently selected
 * day (or the most recent day in the period) we draw a 24-row grid where
 * each row is one hour of the day, stacked horizontally by per-app time.
 * Apps are colored by their dominant icon colour; markers for system events
 * are omitted because the manifest only stores counts, not timestamps.
 */
function renderDayTimeline() {
	const container = document.getElementById('day_timeline_container');
	if (!container) return;

	// Pick the target day: explicit selection if any, otherwise the most
	// recent day in manifestData.
	let targetDay = currentSelectedDate;
	if (!targetDay || !manifestData[targetDay]) {
		const dates = Object.keys(manifestData).sort();
		targetDay = dates[dates.length - 1] || null;
	}
	if (!targetDay) {
		container.innerHTML = `<div style="color:var(--text-muted);font-size:12px;padding:10px;">${_t('ui_apps.empty_day')}</div>`;
		return;
	}

	const dayData = manifestData[targetDay] || {};
	// hourly[hh] → array of {app, ms}
	const byHour = {};
	for (let h = 0; h < 24; h++) byHour[String(h).padStart(2, '0')] = [];

	Object.entries(dayData).forEach(([appName, appData]) => {
		if (appName === '_sys' || appName === '_system') return;
		if (!appData.hourly) return;
		Object.entries(appData.hourly).forEach(([hh, hData]) => {
			let ms = hData.time_ms || 0;
			if (ms === 0 && hData.c > 0) {
				// Estimate from chars proportion if time_ms missing
				let totalChars = 0;
				Object.values(appData.hourly).forEach((h) => (totalChars += h.c || 0));
				if (totalChars > 0) ms = (hData.c / totalChars) * (appData.app_time_ms || 0);
			}
			if (ms > 0 && byHour[hh]) byHour[hh].push({ app: appName, ms });
		});
	});

	const ROW_H      = 18;
	const GAP        = 3;
	const LABEL_LEFT = 38;
	const HOUR_W     = 720;
	const SVG_W      = LABEL_LEFT + HOUR_W + 8;
	const SVG_H      = 24 * (ROW_H + GAP) + 8;

	let svg = '';
	for (let h = 0; h < 24; h++) {
		const hh    = String(h).padStart(2, '0');
		const slots = byHour[hh] || [];
		const totalMs = Math.min(slots.reduce((s, x) => s + x.ms, 0), 60 * 60 * 1000);
		const y = h * (ROW_H + GAP);
		svg += `<text x="${LABEL_LEFT - 6}" y="${y + ROW_H / 2 + 4}" text-anchor="end" fill="#888" font-size="10" font-family="system-ui">${hh}h</text>`;
		// Background
		svg += `<rect x="${LABEL_LEFT}" y="${y}" width="${HOUR_W}" height="${ROW_H}" rx="2" fill="rgba(255,255,255,0.04)"></rect>`;
		// Stacked apps
		slots.sort((a, b) => b.ms - a.ms);
		let cursor = 0;
		slots.forEach((s) => {
			const w = (s.ms / (60 * 60 * 1000)) * HOUR_W;
			const col = getAppColor(s.app, 0);
			const tip = `${s.app} · ${formatDuration(s.ms)} (${hh}h)`;
			svg += `<rect x="${LABEL_LEFT + cursor}" y="${y}" width="${w}" height="${ROW_H}" rx="2" fill="${col}" fill-opacity="0.9"><title>${escapeHtml(tip)}</title></rect>`;
			cursor += w;
		});
	}

	container.innerHTML =
		`<div style="font-size:11px;color:var(--text-muted);margin-bottom:6px;">Jour : ${formatDisplayDate(targetDay)}</div>` +
		`<svg width="${SVG_W}" height="${SVG_H}" viewBox="0 0 ${SVG_W} ${SVG_H}" xmlns="http://www.w3.org/2000/svg">${svg}</svg>`;
}

/**
 * Computes a compact stats summary {focus_ms, active_ms, chars, switches,
 * sessions, productivity_pct} for the given aggregateData payload.
 */
function summarizeAggregate(agg) {
	const r  = agg && agg.rich || {};
	const t  = r.time   || {};
	const ty = r.typing || {};
	const sw = Object.values(agg.apps || {}).reduce((s, a) => s + Object.values(a.switches || {}).reduce((s2, n) => s2 + n, 0), 0);
	let prodSum = 0, prodWt = 0;
	Object.entries(agg.apps || {}).forEach(([n, a]) => {
		const cat = getAppCategory(n, a.category);
		prodSum += (cat.score || 0) * (a.time_ms || 0);
		prodWt  += (a.time_ms || 0);
	});
	const prod = prodWt > 0 ? (prodSum / (prodWt * 2)) * 100 : 0;
	return {
		focus_ms:  t.focus_ms   || 0,
		active_ms: t.active_ms  || 0,
		chars:     ty.chars     || 0,
		switches:  sw,
		sessions:  (r.sessions && r.sessions.count) || 0,
		productivity_pct: prod,
	};
}

/**
 * Renders the period-comparator panel (#55). When enabled, computes stats for
 * the current period and the equivalent previous one (e.g. last 7d vs the 7d
 * before that) and shows deltas in a row of mini-cards.
 */
function renderComparator(currentAgg) {
	const panel = document.getElementById('compare-panel');
	if (!panel) return;
	if (!currentCompareEnabled) {
		panel.style.display = 'none';
		return;
	}
	panel.style.display = 'block';

	// Compute the equivalent prior period by shifting the anchor backwards
	// by the period length. Restore state after.
	const PERIOD_DAYS = { day: 1, week: 7, month: 30, year: 365 };
	const days = PERIOD_DAYS[currentPeriod];
	if (!days || !currentSelectedDate) {
		panel.innerHTML = `<div style="font-size:12px;color:var(--text-muted);">${_t('ui_apps.empty_comparator')}</div>`;
		return;
	}

	const anchorTs   = parseDateKey(currentSelectedDate);
	const prevAnchor = new Date(anchorTs - days * 86400000);
	const yyyy       = prevAnchor.getFullYear();
	const mm         = String(prevAnchor.getMonth() + 1).padStart(2, '0');
	const dd         = String(prevAnchor.getDate()).padStart(2, '0');
	const prevKey    = `${yyyy}-${mm}-${dd}`;

	const savedDate = currentSelectedDate;
	currentSelectedDate = prevKey;
	const prevAgg = getAggregatedData();
	currentSelectedDate = savedDate;

	const cur  = summarizeAggregate(currentAgg);
	const prev = summarizeAggregate(prevAgg);

	const win = document.getElementById('compare-window');
	if (win) win.textContent = _t('ui_apps.cmp_window').replace('{cur}', formatDisplayDate(currentSelectedDate)).replace('{period}', currentPeriod).replace('{prev}', formatDisplayDate(prevKey));

	const rows = document.getElementById('compare-rows');
	if (!rows) return;
	const fmtDelta = (curV, prevV, fmt) => {
		const d = curV - prevV;
		const pct = prevV > 0 ? (d / prevV) * 100 : (curV > 0 ? 100 : 0);
		const sign = d >= 0 ? '+' : '−';
		const colour = d > 0 ? '#30D158' : d < 0 ? '#FF453A' : '#888';
		return `<div style="font-size:18px;color:#fff;font-weight:600;">${fmt(curV)}</div>
			<div style="font-size:11px;color:${colour};">${sign}${fmt(Math.abs(d))} (${sign}${Math.abs(pct).toFixed(0)}%)</div>
			<div style="font-size:10px;color:var(--text-muted);">avant : ${fmt(prevV)}</div>`;
	};
	const card = (label, html) =>
		`<div style="background:rgba(0,0,0,0.25);border-radius:6px;padding:8px;">
			<div style="font-size:11px;color:var(--text-muted);margin-bottom:4px;">${label}</div>${html}
		</div>`;

	rows.innerHTML =
		card(_t('ui_apps.cmp_focus_time'),    fmtDelta(cur.focus_ms,         prev.focus_ms,         (v) => formatDuration(v))) +
		card(_t('ui_apps.cmp_active_time'),    fmtDelta(cur.active_ms,        prev.active_ms,        (v) => formatDuration(v))) +
		card(_t('ui_apps.cmp_chars'),     fmtDelta(cur.chars,            prev.chars,            (v) => format_int(Math.round(v)))) +
		card(_t('ui_apps.cmp_switches'),       fmtDelta(cur.switches,         prev.switches,         (v) => format_int(Math.round(v)))) +
		card(_t('ui_apps.cmp_sessions'),        fmtDelta(cur.sessions,         prev.sessions,         (v) => format_int(Math.round(v)))) +
		card(_t('ui_apps.cmp_productivity'),   fmtDelta(cur.productivity_pct, prev.productivity_pct, (v) => `${v.toFixed(0)}%`));
}

/**
 * Renders SVG boxplots of session durations per app (#28). For each of the
 * top 8 apps with ≥ 4 finalised sessions, computes min/Q1/median/Q3/max and
 * draws a horizontal whisker plot.
 */
function renderSessionBoxplots(aggData) {
	const container = document.getElementById('session_boxplot_container');
	if (!container) return;
	const quantile = (sorted, q) => {
		if (sorted.length === 0) return 0;
		const pos = (sorted.length - 1) * q;
		const base = Math.floor(pos);
		const rest = pos - base;
		return sorted[base] + ((sorted[base + 1] || sorted[base]) - sorted[base]) * rest;
	};
	const rows = [];
	Object.entries(aggData.apps || {}).forEach(([name, data]) => {
		const arr = (data.session_durations || []).filter((d) => d > 0).slice().sort((a, b) => a - b);
		if (arr.length >= 4) {
			rows.push({
				name,
				time_ms: data.time_ms || 0,
				min:    arr[0],
				q1:     quantile(arr, 0.25),
				med:    quantile(arr, 0.5),
				q3:     quantile(arr, 0.75),
				max:    arr[arr.length - 1],
				count:  arr.length,
			});
		}
	});
	rows.sort((a, b) => b.time_ms - a.time_ms);
	const top = rows.slice(0, 10);
	if (top.length === 0) {
		container.innerHTML = `<div style="color:var(--text-muted);font-size:12px;padding:10px;">${_t('ui_apps.empty_boxplot')}</div>`;
		return;
	}
	const max_ms = Math.max(...top.map((r) => r.max));
	const ROW_H      = 36;
	const LABEL_LEFT = 160;
	const W          = 760;
	const TRACK_W    = W - LABEL_LEFT - 60;
	const SVG_H      = top.length * ROW_H + 16;
	const xFor = (ms) => LABEL_LEFT + (ms / max_ms) * TRACK_W;

	let svg = '';
	top.forEach((r, idx) => {
		const y = idx * ROW_H + ROW_H / 2 + 8;
		// Label
		svg += `<text x="${LABEL_LEFT - 10}" y="${y + 4}" text-anchor="end" fill="#ddd" font-size="11" font-family="system-ui">${escapeHtml(r.name)}</text>`;
		// Whisker line
		svg += `<line x1="${xFor(r.min)}" x2="${xFor(r.max)}" y1="${y}" y2="${y}" stroke="#666" stroke-width="1"/>`;
		// Min / max caps
		svg += `<line x1="${xFor(r.min)}" x2="${xFor(r.min)}" y1="${y - 6}" y2="${y + 6}" stroke="#aaa"/>`;
		svg += `<line x1="${xFor(r.max)}" x2="${xFor(r.max)}" y1="${y - 6}" y2="${y + 6}" stroke="#aaa"/>`;
		// IQR box
		const col = getAppColor(r.name, 0);
		const x1 = xFor(r.q1), x2 = xFor(r.q3);
		svg += `<rect x="${x1}" y="${y - 10}" width="${Math.max(2, x2 - x1)}" height="20" rx="3" fill="${col}" fill-opacity="0.6"/>`;
		// Median tick
		svg += `<line x1="${xFor(r.med)}" x2="${xFor(r.med)}" y1="${y - 12}" y2="${y + 12}" stroke="#fff" stroke-width="2"/>`;
		// Tooltip rect (transparent overlay)
		const tip = `${r.name} — ${_t('ui_apps.boxplot_tip').replace('{n}', r.count).replace('{med}', formatDuration(r.med)).replace('{q1}', formatDuration(r.q1)).replace('{q3}', formatDuration(r.q3))}`;
		svg += `<rect x="${LABEL_LEFT}" y="${y - 16}" width="${TRACK_W}" height="32" fill="transparent"><title>${escapeHtml(tip)}</title></rect>`;
	});
	container.innerHTML =
		`<svg width="${W}" height="${SVG_H}" viewBox="0 0 ${W} ${SVG_H}" xmlns="http://www.w3.org/2000/svg">${svg}</svg>` +
		`<div style="font-size:11px;color:var(--text-muted);margin-top:6px;">${_t('ui_apps.boxplot_scale').replace('{max}', formatDuration(max_ms))}</div>`;
}

/**
 * Renders the top window titles table (#39): titles ranked by characters typed,
 * with the originating app and total dwell time.
 */
function renderTopWindowsTable(aggData) {
	const tbody = document.getElementById('top_windows_tbody');
	if (!tbody) return;
	const rows = [];
	Object.entries(aggData.apps || {}).forEach(([app, data]) => {
		Object.entries(data.win_titles || {}).forEach(([title, w]) => {
			if ((w.c || 0) > 0) rows.push({ title, app, c: w.c, ms: w.ms || 0 });
		});
	});
	rows.sort((a, b) => b.c - a.c);
	if (rows.length === 0) {
		tbody.innerHTML = `<tr><td colspan="4" style="text-align:center;color:var(--text-muted);">${_t('ui_apps.empty_windows')}</td></tr>`;
		return;
	}
	tbody.innerHTML = rows.slice(0, 30).map((r) => `<tr>
		<td style="max-width:480px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="${escapeHtml(r.title)}">${escapeHtml(r.title)}</td>
		<td>${escapeHtml(r.app)}</td>
		<td style="text-align:right;">${format_int(r.c)}</td>
		<td style="text-align:right;">${formatDuration(r.ms)}</td>
	</tr>`).join('');
}

/**
 * Renders the top sessions table (#37). Uses per-app-day session_longest_ms
 * as a proxy: for each (date, app) row we surface its longest single session.
 */
function renderTopSessionsTable() {
	const tbody = document.getElementById('top_sessions_tbody');
	if (!tbody) return;
	const rows = [];
	Object.entries(manifestData || {}).forEach(([dateStr, dayData]) => {
		Object.entries(dayData || {}).forEach(([appName, appData]) => {
			if (appName === '_sys' || appName === '_system') return;
			const longest = Number(appData.session_longest_ms) || 0;
			if (longest > 0) {
				rows.push({
					date:  dateStr,
					app:   appName,
					ms:    longest,
					chars: Number(appData.session_longest_chars) || 0,
				});
			}
		});
	});
	rows.sort((a, b) => b.ms - a.ms);
	const top = rows.slice(0, 30);
	if (top.length === 0) {
		tbody.innerHTML = `<tr><td colspan="4" style="text-align:center;color:var(--text-muted);">${_t('ui_apps.empty_sessions')}</td></tr>`;
		return;
	}
	tbody.innerHTML = top.map((r) => `<tr>
		<td>${formatDisplayDate(r.date)}</td>
		<td>${escapeHtml(r.app)}</td>
		<td style="text-align:right;">${formatDuration(r.ms)}</td>
		<td style="text-align:right;">${format_int(r.chars)}</td>
	</tr>`).join('');
}

/**
 * Renders the top days table (#38) — full day rollups (chars / focus / switches /
 * sessions), sorted by chars desc.
 */
function renderTopDaysTable(aggData) {
	const tbody = document.getElementById('top_days_tbody');
	if (!tbody) return;
	const days = Object.entries((aggData.rich && aggData.rich.by_date) || {})
		.map(([date, d]) => ({ date, ...d }))
		.sort((a, b) => (b.chars || 0) - (a.chars || 0))
		.slice(0, 20);
	if (days.length === 0) {
		tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:var(--text-muted);">${_t('ui_apps.empty_days')}</td></tr>`;
		return;
	}
	tbody.innerHTML = days.map((d) => `<tr>
		<td>${formatDisplayDate(d.date)}</td>
		<td style="text-align:right;">${format_int(d.chars || 0)}</td>
		<td style="text-align:right;">${formatDuration(d.time_ms || 0)}</td>
		<td style="text-align:right;">${d.switches || 0}</td>
		<td style="text-align:right;">${d.sessions || 0}</td>
	</tr>`).join('');
}

/**
 * Renders the top app-pairs table (#36): src → dst transitions ranked by count.
 */
function renderAppPairsTable(aggData) {
	const tbody = document.getElementById('app_pairs_tbody');
	if (!tbody) return;
	const edges = [];
	Object.entries(aggData.apps || {}).forEach(([src, data]) => {
		Object.entries(data.switches || {}).forEach(([dst, count]) => {
			if (src !== dst && count > 0) edges.push({ src, dst, count });
		});
	});
	edges.sort((a, b) => b.count - a.count);
	const total = edges.reduce((s, e) => s + e.count, 0);
	if (edges.length === 0) {
		tbody.innerHTML = `<tr><td colspan="4" style="text-align:center;color:var(--text-muted);">${_t('ui_apps.empty_app_switches')}</td></tr>`;
		return;
	}
	const top = edges.slice(0, 30);
	tbody.innerHTML = top.map((e) => {
		const pct = total > 0 ? (e.count / total) * 100 : 0;
		return `<tr>
			<td>${escapeHtml(e.src)}</td>
			<td>${escapeHtml(e.dst)}</td>
			<td style="text-align:right;">${e.count}</td>
			<td style="text-align:right;color:var(--text-muted);">${pct.toFixed(1)} %</td>
		</tr>`;
	}).join('');
}

/**
 * Renders four time-series charts driven by rich.by_date:
 *   #29 daily trio (focus_ms, chars, switches) on dual axes
 *   #30 daily active ratio (active_ms / max(0, focus_ms - passive_ms))
 *   #31 daily stacked area by category
 *   #32 daily first / last typed minute as two lines
 */
function renderDailyTrajectories(aggData) {
	if (typeof Chart === 'undefined') return;
	const byDate = (aggData.rich && aggData.rich.by_date) || {};
	const dates  = Object.keys(byDate).sort();
	const labels = dates.map(formatDisplayDate);

	// #29 — focus_ms (h), chars, switches
	const c29 = document.getElementById('daily_trio_chart');
	if (c29) {
		if (dailyTrioChart) dailyTrioChart.destroy();
		dailyTrioChart = new Chart(c29.getContext('2d'), {
			type: 'line',
			data: {
				labels,
				datasets: [
					{ label: _t('ui_apps.ds_focus_h'),    data: dates.map((d) => +(byDate[d].time_ms / 3600000).toFixed(2)),  borderColor: '#0A84FF', backgroundColor: 'rgba(10,132,255,0.15)', tension: 0.25, yAxisID: 'y1', borderWidth: 2 },
					{ label: _t('ui_apps.ds_chars'),   data: dates.map((d) => byDate[d].chars || 0),                      borderColor: '#FF9F0A', backgroundColor: 'rgba(255,159,10,0.10)', tension: 0.25, yAxisID: 'y2', borderWidth: 2 },
					{ label: _t('ui_apps.ds_switches'),     data: dates.map((d) => byDate[d].switches || 0),                   borderColor: '#BF5AF2', backgroundColor: 'rgba(191,90,242,0.10)', tension: 0.25, yAxisID: 'y2', borderWidth: 2 },
				]
			},
			options: {
				responsive: true, maintainAspectRatio: false,
				plugins: { legend: { labels: { color: '#ccc' } } },
				scales: {
					x:  { grid: { display: false }, ticks: { color: '#888' } },
					y1: { position: 'left',  beginAtZero: true, grid: { color: 'rgba(255,255,255,0.08)' }, ticks: { color: '#0A84FF' } },
					y2: { position: 'right', beginAtZero: true, grid: { drawOnChartArea: false }, ticks: { color: '#FF9F0A' } }
				}
			}
		});
	}

	// #30 — active ratio per day (%)
	const c30 = document.getElementById('daily_active_ratio_chart');
	if (c30) {
		const ratios = dates.map((d) => {
			const eff = Math.max(0, (byDate[d].time_ms || 0) - (byDate[d].passive_ms || 0));
			return eff > 0 ? +(((byDate[d].active_ms || 0) / eff) * 100).toFixed(1) : 0;
		});
		const colors = ratios.map((r) => r >= 60 ? '#30D158' : r >= 30 ? '#FFD60A' : '#FF453A');
		if (dailyActiveRatioChart) dailyActiveRatioChart.destroy();
		dailyActiveRatioChart = new Chart(c30.getContext('2d'), {
			type: 'bar',
			data: { labels, datasets: [{ label: _t('ui_apps.ds_active_ratio'), data: ratios, backgroundColor: colors, borderRadius: 4 }] },
			options: {
				responsive: true, maintainAspectRatio: false,
				plugins: { legend: { display: false } },
				scales: {
					x: { grid: { display: false }, ticks: { color: '#888' } },
					y: { beginAtZero: true, max: 100, grid: { color: 'rgba(255,255,255,0.08)' }, ticks: { color: '#ccc', callback: (v) => `${v}%` } }
				}
			}
		});
	}

	// #31 — stacked area per category
	const c31 = document.getElementById('daily_categories_chart');
	if (c31) {
		const allCats = new Set();
		dates.forEach((d) => Object.keys(byDate[d].by_category || {}).forEach((c) => allCats.add(c)));
		const catList = [...allCats];
		const datasets = catList.map((cat) => ({
			label: cat,
			data: dates.map((d) => +(((byDate[d].by_category || {})[cat] || 0) / 3600000).toFixed(2)),
			backgroundColor: getCategoryColor(cat, 0),
			borderColor:     getCategoryColor(cat, 0),
			fill: true,
			tension: 0.25,
			borderWidth: 1,
		}));
		if (dailyCategoriesChart) dailyCategoriesChart.destroy();
		dailyCategoriesChart = new Chart(c31.getContext('2d'), {
			type: 'line',
			data: { labels, datasets },
			options: {
				responsive: true, maintainAspectRatio: false,
				plugins: { legend: { labels: { color: '#ccc' } } },
				scales: {
					x: { grid: { display: false }, ticks: { color: '#888' }, stacked: true },
					y: { stacked: true, beginAtZero: true, grid: { color: 'rgba(255,255,255,0.08)' }, ticks: { color: '#ccc', callback: (v) => `${v}h` } }
				}
			}
		});
	}

	// #32 — first / last typed minute per day, plotted as decimal hours
	const c32 = document.getElementById('daily_bounds_chart');
	if (c32) {
		const firstHrs = dates.map((d) => byDate[d].first_min != null ? +(byDate[d].first_min / 60).toFixed(2) : null);
		const lastHrs  = dates.map((d) => byDate[d].last_min  != null ? +(byDate[d].last_min  / 60).toFixed(2) : null);
		if (dailyBoundsChart) dailyBoundsChart.destroy();
		dailyBoundsChart = new Chart(c32.getContext('2d'), {
			type: 'line',
			data: {
				labels,
				datasets: [
					{ label: _t('ui_apps.ds_first_key'), data: firstHrs, borderColor: '#0A84FF', backgroundColor: 'rgba(10,132,255,0.10)', tension: 0.25, borderWidth: 2, spanGaps: true },
					{ label: _t('ui_apps.ds_last_key'), data: lastHrs,  borderColor: '#FF453A', backgroundColor: 'rgba(255,69,58,0.10)',  tension: 0.25, borderWidth: 2, spanGaps: true },
				]
			},
			options: {
				responsive: true, maintainAspectRatio: false,
				plugins: { legend: { labels: { color: '#ccc' } } },
				scales: {
					x: { grid: { display: false }, ticks: { color: '#888' } },
					y: { min: 0, max: 24, grid: { color: 'rgba(255,255,255,0.08)' }, ticks: { color: '#ccc', stepSize: 4, callback: (v) => `${v}h` } }
				}
			}
		});
	}
}



/**
 * Renders a radar chart of the top 8 apps with two normalized series:
 * total focus time and total characters typed. Apps are oriented around
 * the radar so the user can see profile imbalances at a glance.
 */
function renderRadialTop8(appsArray) {
	const canvas = document.getElementById('radial_top8_chart');
	if (!canvas || typeof Chart === 'undefined') return;
	const top = appsArray.slice(0, 8);
	if (top.length === 0) {
		if (radialTop8Chart) { radialTop8Chart.destroy(); radialTop8Chart = null; }
		return;
	}
	const max_time  = Math.max(...top.map((a) => a.timeMs || 0)) || 1;
	const max_chars = Math.max(...top.map((a) => a.chars  || 0)) || 1;
	const labels = top.map((a) => a.name);
	const time_norm  = top.map((a) => Math.round(((a.timeMs || 0) / max_time)  * 100));
	const chars_norm = top.map((a) => Math.round(((a.chars  || 0) / max_chars) * 100));
	if (radialTop8Chart) radialTop8Chart.destroy();
	radialTop8Chart = new Chart(canvas.getContext('2d'), {
		type: 'radar',
		data: {
			labels,
			datasets: [
				{ label: _t('ui_apps.ds_focus_time'), data: time_norm,  borderColor: '#0A84FF', backgroundColor: 'rgba(10,132,255,0.18)', borderWidth: 2 },
				{ label: _t('ui_apps.ds_chars'),  data: chars_norm, borderColor: '#FF9F0A', backgroundColor: 'rgba(255,159,10,0.18)', borderWidth: 2 },
			],
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: { legend: { labels: { color: '#ccc' } } },
			scales: {
				r: {
					suggestedMin: 0, suggestedMax: 100,
					grid:       { color: 'rgba(255,255,255,0.08)' },
					angleLines: { color: 'rgba(255,255,255,0.08)' },
					pointLabels:{ color: '#ddd', font: { size: 11 } },
					ticks:      { color: '#888', backdropColor: 'transparent', stepSize: 25 }
				}
			}
		}
	});
}

/**
 * Renders the burst-length histogram from rich.bursts.length_buckets, i.e.
 * how many bursts fell into each character-length bucket on the period.
 */
function renderBurstHistogram(aggData) {
	const canvas = document.getElementById('burst_histogram_chart');
	if (!canvas || typeof Chart === 'undefined') return;
	const buckets = (aggData.rich && aggData.rich.bursts && aggData.rich.bursts.length_buckets) || {};
	const ORDER = ['1', '5', '10', '20', '50', '100', '200', '500', '500+'];
	const labels = [];
	const data   = [];
	ORDER.forEach((k) => {
		if (buckets[k] != null) {
			labels.push(`≤ ${k}`);
			data.push(buckets[k]);
		}
	});
	if (labels.length === 0) {
		if (burstHistogramChart) { burstHistogramChart.destroy(); burstHistogramChart = null; }
		return;
	}
	if (burstHistogramChart) burstHistogramChart.destroy();
	burstHistogramChart = new Chart(canvas.getContext('2d'), {
		type: 'bar',
		data: { labels, datasets: [{ label: _t('ui_apps.ds_bursts'), data, backgroundColor: '#30D158', borderRadius: 4 }] },
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: { legend: { display: false } },
			scales: {
				y: { beginAtZero: true, grid: { color: 'rgba(255,255,255,0.1)' }, ticks: { color: '#ccc' } },
				x: { grid: { display: false }, ticks: { color: '#ccc' } }
			}
		}
	});
}

/** Toggle button handler for the hour×weekday heatmap mode. */
window.setHourWeekdayMode = function (mode) {
	_hourWeekdayMode = (mode === 'time') ? 'time' : 'chars';
	const btn_t = document.getElementById('hwk-mode-time');
	const btn_c = document.getElementById('hwk-mode-chars');
	if (btn_t) btn_t.classList.toggle('active', _hourWeekdayMode === 'time');
	if (btn_c) btn_c.classList.toggle('active', _hourWeekdayMode === 'chars');
	if (window._lastAggData) renderHourWeekdayHeatmap(window._lastAggData);
};

// =====================================================
// =====================================================
// ======= 6/ 12-Month Activity Calendar =======
// =====================================================
// =====================================================

let _calendarMode = 'chars';

const MONTHS_FR_SHORT = ['Jan','Fév','Mar','Avr','Mai','Juin','Juil','Août','Sep','Oct','Nov','Déc'];

/**
 * Renders a GitHub-style 53-week × 7-day calendar covering the last 365
 * days. Intensity per cell scales with either characters typed (default)
 * or focus time. Reads manifestData directly so the view always covers
 * a full year regardless of the active period filter.
 */
function renderActivityCalendar() {
	const container = document.getElementById('activity_calendar_container');
	if (!container) return;

	const today = new Date();
	today.setHours(0, 0, 0, 0);
	const start = new Date(today);
	start.setDate(start.getDate() - 364);

	// Build a date_str → { time_ms, chars } lookup from manifestData. We sum
	// across all apps (excluding pseudo-apps) for each calendar day.
	const per_day = {};
	Object.entries(manifestData || {}).forEach(([date_str, day]) => {
		if (!day || typeof day !== 'object') return;
		const slot = per_day[date_str] || (per_day[date_str] = { time_ms: 0, chars: 0 });
		Object.entries(day).forEach(([app_name, app_data]) => {
			if (app_name === '_sys' || app_name === '_system') return;
			slot.time_ms += Number(app_data.app_time_ms) || 0;
			slot.chars   += Number(app_data.chars)       || 0;
		});
	});

	// Walk the 365-day window day-by-day, snapped to start on Monday. Each
	// cell is a date; weeks are columns.
	const cells = [];
	const cursor = new Date(start);
	// Snap cursor back to the previous Monday so the first column is aligned.
	cursor.setDate(cursor.getDate() - ((cursor.getDay() + 6) % 7));
	const end = new Date(today);
	end.setDate(end.getDate() + 1);

	let max_v = 0;
	while (cursor < end) {
		const yyyy = cursor.getFullYear();
		const mm   = String(cursor.getMonth() + 1).padStart(2, '0');
		const dd   = String(cursor.getDate()).padStart(2, '0');
		const key  = `${yyyy}-${mm}-${dd}`;
		const day  = per_day[key];
		const v = !day ? 0
			: (_calendarMode === 'time' ? (day.time_ms || 0) : (day.chars || 0));
		if (v > max_v) max_v = v;
		cells.push({
			key,
			date: new Date(cursor),
			weekday: (cursor.getDay() + 6) % 7,    // 0=Mon … 6=Sun
			value: v,
			in_window: cursor >= start && cursor <= today,
		});
		cursor.setDate(cursor.getDate() + 1);
	}

	const CELL = 11, GAP = 2;
	const HEAD_H = 16;
	const LABEL_W = 22;
	const cols = Math.ceil(cells.length / 7);
	const SVG_W = LABEL_W + cols * (CELL + GAP);
	const SVG_H = HEAD_H + 7 * (CELL + GAP) + 4;

	const heat = (v) => {
		if (v === 0) return '#1e1e2e';
		const t = Math.pow(v / Math.max(1, max_v), 0.45);
		if (t < 0.4) return `rgb(${Math.round(40 + t * 60)},${Math.round(70 + t * 110)},${Math.round(50 + t * 30)})`;
		if (t < 0.7) {
			const tt = (t - 0.4) / 0.3;
			return `rgb(${Math.round(100 + tt * 100)},${Math.round(180 - tt * 50)},${Math.round(80 - tt * 60)})`;
		}
		const tt = (t - 0.7) / 0.3;
		return `rgb(${Math.round(200 + tt * 55)},${Math.round(130 - tt * 100)},${Math.round(20)})`;
	};

	// Month-header labels: render the month name at the column where its 1st falls.
	let month_labels = '';
	let last_label_month = -1;
	cells.forEach((c, i) => {
		if (c.weekday !== 0) return; // only consider Monday cells for column header
		const col = Math.floor(i / 7);
		if (c.date.getDate() <= 7 && c.date.getMonth() !== last_label_month) {
			last_label_month = c.date.getMonth();
			const cx = LABEL_W + col * (CELL + GAP);
			month_labels += `<text x="${cx}" y="12" fill="#888" font-size="10" font-family="system-ui">${MONTHS_FR_SHORT[c.date.getMonth()]}</text>`;
		}
	});

	const wd_labels_short = ['L','M','M','J','V','S','D'];
	let wd_labels = '';
	[1, 3, 5].forEach((wd_i) => {
		const cy = HEAD_H + wd_i * (CELL + GAP) + 9;
		wd_labels += `<text x="0" y="${cy}" fill="#666" font-size="9" font-family="system-ui">${wd_labels_short[wd_i]}</text>`;
	});

	let rects = '';
	cells.forEach((c, i) => {
		const col = Math.floor(i / 7);
		const row = c.weekday;
		const x = LABEL_W + col * (CELL + GAP);
		const y = HEAD_H + row * (CELL + GAP);
		if (!c.in_window) {
			rects += `<rect x="${x}" y="${y}" width="${CELL}" height="${CELL}" rx="2" fill="rgba(255,255,255,0.02)"/>`;
			return;
		}
		const fill = heat(c.value);
		const dt   = `${c.date.getDate()}/${c.date.getMonth() + 1}/${c.date.getFullYear()}`;
		const v_txt = _calendarMode === 'time'
			? (c.value > 0 ? formatDuration(c.value) : '0')
			: (c.value > 0 ? `${c.value} car.` : '0');
		rects += `<rect x="${x}" y="${y}" width="${CELL}" height="${CELL}" rx="2" fill="${fill}"><title>${dt} — ${v_txt}</title></rect>`;
	});

	container.innerHTML =
		`<svg width="${SVG_W}" height="${SVG_H}" viewBox="0 0 ${SVG_W} ${SVG_H}" xmlns="http://www.w3.org/2000/svg">` +
			month_labels + wd_labels + rects +
		`</svg>`;
}

// =====================================================
// =====================================================
// ======= 7/ CPM by Hour Chart =======
// =====================================================
// =====================================================

let _cpmByHourChart = null;

/**
 * Renders a bar+line chart of typing speed (characters per focus minute)
 * for each hour of the day, aggregated across all days in the active
 * period. Uses by_hour from the rich aggregator.
 */
function renderCpmByHourChart(aggData) {
	const canvas = document.getElementById('cpm_by_hour_chart');
	if (!canvas) return;
	const by_hour = (aggData && aggData.rich && aggData.rich.by_hour) || {};

	const labels = [];
	const cpm    = [];
	const chars  = [];
	for (let h = 0; h < 24; h++) {
		const hh = String(h).padStart(2, '0');
		labels.push(`${hh}h`);
		const slot = by_hour[hh] || { time_ms: 0, chars: 0 };
		const minutes = slot.time_ms / 60000;
		cpm.push(minutes > 0 ? Math.round(slot.chars / minutes) : 0);
		chars.push(slot.chars || 0);
	}

	const ctx = canvas.getContext('2d');
	if (_cpmByHourChart) _cpmByHourChart.destroy();
	_cpmByHourChart = new Chart(ctx, {
		type: 'bar',
		data: {
			labels,
			datasets: [
				{
					type: 'bar',
					label: _t('ui_apps.ds_chars'),
					data: chars,
					backgroundColor: 'rgba(34, 211, 238, 0.35)',
					borderColor: 'rgba(34, 211, 238, 0.8)',
					borderWidth: 1,
					yAxisID: 'y_chars',
				},
				{
					type: 'line',
					label: _t('ui_apps.ds_speed'),
					data: cpm,
					borderColor: 'rgba(245, 158, 11, 1)',
					backgroundColor: 'rgba(245, 158, 11, 0.15)',
					tension: 0.3,
					yAxisID: 'y_cpm',
					pointRadius: 3,
				},
			],
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			interaction: { mode: 'index', intersect: false },
			plugins: {
				legend: { labels: { color: '#ddd', font: { size: 11 } } },
				tooltip: {
					callbacks: {
						title: (items) => items[0] ? items[0].label : '',
					},
				},
			},
			scales: {
				x: { ticks: { color: '#888', font: { size: 10 } }, grid: { color: 'rgba(255,255,255,0.04)' } },
				y_chars: {
					type: 'linear', position: 'left',
					ticks: { color: '#888', font: { size: 10 } },
					grid: { color: 'rgba(255,255,255,0.04)' },
					title: { display: true, text: _t('ui_apps.axis_chars'), color: '#888', font: { size: 10 } },
				},
				y_cpm: {
					type: 'linear', position: 'right',
					ticks: { color: '#f59e0b', font: { size: 10 } },
					grid: { drawOnChartArea: false },
					title: { display: true, text: _t('ui_apps.axis_speed'), color: '#f59e0b', font: { size: 10 } },
				},
			},
		},
	});
}

window.setCalendarMode = function (mode) {
	_calendarMode = (mode === 'time') ? 'time' : 'chars';
	const btn_t = document.getElementById('cal-mode-time');
	const btn_c = document.getElementById('cal-mode-chars');
	if (btn_t) btn_t.classList.toggle('active', _calendarMode === 'time');
	if (btn_c) btn_c.classList.toggle('active', _calendarMode === 'chars');
	renderActivityCalendar();
};

// =====================================================
// =====================================================
// ======= 8/ App Drill-Down Modal =======
// =====================================================
// =====================================================

let _appModalChart = null;

/**
 * Aggregates the manifest for a single app within the active period and
 * renders the drill-down modal: 6 stat tiles, an hourly chart, top
 * destinations, layouts, records, and hotstrings/IA share.
 * @param {string} appName
 */
function openAppDrilldown(appName) {
	const modal = document.getElementById('app_drilldown_modal');
	if (!modal) return;
	const agg = window._lastAggData;
	if (!agg) return;
	const a = agg.apps[appName];
	if (!a) return;

	// Walk the filtered manifest once more to harvest hourly data for THIS app.
	const allDates = Object.keys(manifestData)
		.map((k) => ({ key: k, ts: parseDateKey(k) }))
		.filter((d) => !isNaN(d.ts));
	let targetTsStart = 0;
	const anchorTs = currentSelectedDate ? parseDateKey(currentSelectedDate)
		: (allDates.length > 0 ? Math.max(...allDates.map(d => d.ts)) : 0);
	if (currentPeriod === 'day')   targetTsStart = anchorTs;
	if (currentPeriod === 'week')  targetTsStart = anchorTs - 7  * 86400000;
	if (currentPeriod === 'month') targetTsStart = anchorTs - 30 * 86400000;
	if (currentPeriod === 'year')  targetTsStart = anchorTs - 365 * 86400000;

	const hourly = {};
	for (let h = 0; h < 24; h++) hourly[String(h).padStart(2, '0')] = { time_ms: 0, chars: 0 };

	allDates.forEach((d) => {
		if (currentPeriod !== 'all' && (d.ts > anchorTs || d.ts < targetTsStart)) return;
		const day = manifestData[d.key];
		if (!day) return;
		const app_data = day[appName];
		if (!app_data || !app_data.hourly) return;
		let totalAppChars = 0;
		Object.values(app_data.hourly).forEach((h) => (totalAppChars += h.c || 0));
		Object.entries(app_data.hourly).forEach(([hour, hData]) => {
			const slot = hourly[hour] || (hourly[hour] = { time_ms: 0, chars: 0 });
			let hMs = hData.time_ms || 0;
			if (hMs === 0 && totalAppChars > 0 && hData.c > 0) {
				hMs = (hData.c / totalAppChars) * (Number(app_data.app_time_ms) || 0);
			}
			slot.time_ms += hMs;
			slot.chars   += hData.c || 0;
		});
	});

	// Title
	document.getElementById('app_modal_title').textContent = appName;

	// Stat tiles
	const focus_min = (a.time_ms || 0) / 60000;
	const density = focus_min > 0 ? (a.chars || 0) / focus_min : 0;
	const focus_lat_mean = (a.focus_latency_count || 0) > 0
		? a.focus_latency_sum_ms / a.focus_latency_count : 0;
	const tiles = [
		{ label: _t('ui_apps.tile_focus'),          value: formatDuration(a.time_ms || 0), detail: '' },
		{ label: _t('ui_apps.tile_typing'),  value: formatDuration(a.typing_time || 0),
			detail: a.time_ms > 0 ? _t('ui_apps.modal_pct_focus').replace('{pct}', ((a.typing_time / a.time_ms) * 100).toFixed(1)) : '' },
		{ label: _t('ui_apps.tile_chars'),     value: format_int(a.chars || 0),
			detail: density > 0 ? _t('ui_apps.modal_density').replace('{n}', density.toFixed(0)) : '' },
		{ label: _t('ui_apps.tile_sessions'),        value: String(a.session_count || 0),
			detail: a.session_longest_ms > 0 ? _t('ui_apps.modal_longest_session').replace('{dur}', formatDuration(a.session_longest_ms)) : '' },
		{ label: _t('ui_apps.tile_focus_lat'),  value: focus_lat_mean > 0 ? `${Math.round(focus_lat_mean)} ms` : '—',
			detail: a.focus_latency_count > 0 ? `n=${a.focus_latency_count}` : '' },
		{ label: _t('ui_apps.tile_backspaces'),     value: format_int(a.bs_total || 0),
			detail: a.chars > 0 ? _t('ui_apps.modal_backspace_pct').replace('{pct}', ((a.bs_total / a.chars) * 100).toFixed(1)) : '' },
	];
	document.getElementById('app_modal_tiles').innerHTML = tiles.map(t =>
		`<div class="app-modal-tile">
			<div class="app-modal-tile-label">${escapeHtml(t.label)}</div>
			<div class="app-modal-tile-value">${escapeHtml(t.value)}</div>
			${t.detail ? `<div class="app-modal-tile-detail">${escapeHtml(t.detail)}</div>` : ''}
		</div>`
	).join('');

	// Hourly chart
	const labels = [], chars_arr = [];
	for (let h = 0; h < 24; h++) {
		const hh = String(h).padStart(2, '0');
		labels.push(`${hh}h`);
		chars_arr.push((hourly[hh] && hourly[hh].chars) || 0);
	}
	const ctx = document.getElementById('app_modal_hourly').getContext('2d');
	if (_appModalChart) _appModalChart.destroy();
	_appModalChart = new Chart(ctx, {
		type: 'bar',
		data: { labels, datasets: [{
			label: _t('ui_apps.ds_chars'),
			data: chars_arr,
			backgroundColor: 'rgba(34, 211, 238, 0.55)',
			borderRadius: 2,
		}]},
		options: {
			responsive: true, maintainAspectRatio: false,
			plugins: { legend: { display: false } },
			scales: {
				x: { ticks: { color: '#888', font: { size: 9 } }, grid: { color: 'rgba(255,255,255,0.04)' } },
				y: { ticks: { color: '#888', font: { size: 9 } }, grid: { color: 'rgba(255,255,255,0.04)' } },
			},
		},
	});

	// Destinations
	const dest_html = a.switches && Object.keys(a.switches).length > 0
		? Object.entries(a.switches).sort((x, y) => y[1] - x[1]).slice(0, 8)
			.map(([dest, n]) => `<div style="display:flex;justify-content:space-between;padding:3px 0;font-size:12px;"><span>${escapeHtml(dest)}</span><span style="color:#aaa;">${n}</span></div>`)
			.join('')
		: `<div style="color:#888;font-size:12px;">${_t('ui_apps.kpi_no_backslash_out')}</div>`;
	document.getElementById('app_modal_dests').innerHTML = dest_html;

	// Layouts seen — sum from manifest for this app within the period.
	const layouts = {};
	allDates.forEach((d) => {
		if (currentPeriod !== 'all' && (d.ts > anchorTs || d.ts < targetTsStart)) return;
		const ls = manifestData[d.key] && manifestData[d.key][appName] && manifestData[d.key][appName].layouts_seen;
		if (!ls) return;
		Object.entries(ls).forEach(([id, n]) => {
			layouts[id] = (layouts[id] || 0) + (n || 0);
		});
	});
	const layouts_html = Object.keys(layouts).length > 0
		? Object.entries(layouts).sort((x, y) => y[1] - x[1])
			.map(([id, n]) => `<div style="display:flex;justify-content:space-between;padding:3px 0;font-size:12px;"><span>${escapeHtml(id)}</span><span style="color:#aaa;">${n}×</span></div>`)
			.join('')
		: `<div style="color:#888;font-size:12px;">${_t('ui_apps.kpi_no_layout')}</div>`;
	document.getElementById('app_modal_layouts').innerHTML = layouts_html;

	// Records
	const recs = [];
	if (a.session_longest_ms > 0) {
		recs.push(`<div>${_t('ui_apps.modal_record_session').replace('{dur}', formatDuration(a.session_longest_ms)).replace('{chars}', a.session_longest_chars > 0 ? ` (${a.session_longest_chars} car.)` : '')}</div>`);
	}
	if ((a.burst_max_cpm || 0) > 0) {
		recs.push(`<div>${_t('ui_apps.modal_record_burst').replace('{n}', a.burst_max_cpm.toFixed(0))}</div>`);
	}
	if ((a.cascade_count || 0) > 0) {
		recs.push(`<div>${_t('ui_apps.modal_record_cascade').replace('{n}', a.cascade_count)}</div>`);
	}
	const rec_html = recs.length > 0
		? recs.map(r => `<div style="font-size:12px;padding:3px 0;">${r}</div>`).join('')
		: `<div style="color:#888;font-size:12px;">${_t('ui_apps.kpi_no_record')}</div>`;
	document.getElementById('app_modal_records').innerHTML = rec_html;

	// Hotstrings & IA
	const hs_pct  = (a.chars || 0) > 0 ? (a.hs_chars  / a.chars) * 100 : 0;
	const llm_pct = (a.chars || 0) > 0 ? (a.llm_chars / a.chars) * 100 : 0;
	document.getElementById('app_modal_assist').innerHTML =
		`<div style="font-size:12px;padding:3px 0;">${_t('ui_apps.modal_hs_line').replace('{n}', format_int(a.hs_chars || 0)).replace('{pct}', hs_pct.toFixed(1))}</div>` +
		`<div style="font-size:12px;padding:3px 0;">${_t('ui_apps.modal_llm_line').replace('{n}', format_int(a.llm_chars || 0)).replace('{pct}', llm_pct.toFixed(1))}</div>` +
		`<div style="font-size:12px;padding:3px 0;color:#888;">${_t('ui_apps.modal_total_chars').replace('{n}', format_int(a.chars || 0))}</div>`;

	modal.style.display = 'flex';
}

window.openAppDrilldown = openAppDrilldown;
window.closeAppDrilldown = function () {
	const modal = document.getElementById('app_drilldown_modal');
	if (modal) modal.style.display = 'none';
};

function format_int(n) {
	return new Intl.NumberFormat('fr-FR').format(Math.round(n || 0));
}

document.addEventListener('DOMContentLoaded', initDashboard);
