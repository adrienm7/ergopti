// _shared/ui/metrics_apps/helpers.js
/**
 * _shared/ui/metrics_apps/script.js
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

// Map macOS LSApplicationCategoryType (English) → stable i18n id matching
// _shared/data/locales/<code>.json app_category.* keys.
const CATEGORY_ID_MAP = {
	Productivity: 'productivity',
	'Social networking': 'social',
	Games: 'games',
	Entertainment: 'entertainment',
	Utilities: 'utility',
	Education: 'education',
	Finance: 'finance',
	Business: 'business',
	'Graphics design': 'graphics_design',
	Photography: 'photography',
	Video: 'video',
	Music: 'music',
	Medical: 'medical',
	'Health fitness': 'health',
	Lifestyle: 'lifestyle',
	News: 'news',
	Weather: 'weather',
	Sports: 'sports',
	Travel: 'travel',
	Navigation: 'navigation',
	Reference: 'reference',
	'Developer tools': 'development',
	Unknown: 'general'
};

// Reverse map (any locale label → stable id), populated lazily by translateCategory
// so getCategoryColor can resolve a translated label back to its id.
const _labelToId = {};

// Pre-seed the French legacy labels so existing user categories stored with
// the old hardcoded French strings still resolve to the correct id.
const _FRENCH_LEGACY_LABELS = {
	'Productivité': 'productivity',
	'Réseaux sociaux': 'social',
	'Jeux': 'games',
	'Divertissement': 'entertainment',
	'Utilitaires': 'utility',
	'Éducation': 'education',
	'Finance': 'finance',
	'Business': 'business',
	'Design graphique': 'graphics_design',
	'Photographie': 'photography',
	'Vidéo': 'video',
	'Musique': 'music',
	'Médical': 'medical',
	'Santé & Forme': 'health',
	'Style de vie': 'lifestyle',
	'Actualités': 'news',
	'Météo': 'weather',
	'Sport': 'sports',
	'Voyage': 'travel',
	'Navigation': 'navigation',
	'Références': 'reference',
	'Développement': 'development',
	'Général': 'general'
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
	'#5AC8FA' // Light Blue
];

// Fixed aesthetic mappings for standard categories keyed on stable i18n ids —
// each hue is deliberately distant from the others on the colour wheel.
const FIXED_CAT_COLORS = {
	productivity: '#0A84FF',
	development: '#5E5CE6',
	social: '#FF375F',
	games: '#FF453A',
	entertainment: '#BF5AF2',
	utility: '#64D2FF',
	education: '#FF9F0A',
	business: '#FFD60A',
	finance: '#30B0C7',
	graphics_design: '#E588F8',
	photography: '#FF6B35',
	video: '#FF375F',
	music: '#32D74B',
	health: '#34C759',
	news: '#F4A460',
	weather: '#5AC8FA',
	travel: '#00C7BE',
	general: '#8E8E93'
};

/**
 * Resolves a category name to its stable i18n id.
 * Accepts an English macOS category, a French legacy label, or an already-stable id.
 * @param {string} catName
 * @returns {string} stable id (falls back to 'utility').
 */
function categoryToId(catName) {
	if (!catName) return 'utility';
	// Direct English → id
	if (CATEGORY_ID_MAP[catName]) return CATEGORY_ID_MAP[catName];
	// French legacy label → id (backward compat with existing user categories)
	if (_FRENCH_LEGACY_LABELS[catName]) return _FRENCH_LEGACY_LABELS[catName];
	// Already a stable id?
	if (FIXED_CAT_COLORS[catName]) return catName;
	// Reverse cache populated by previous translateCategory calls
	if (_labelToId[catName]) return _labelToId[catName];
	return 'utility';
}

function translateCategory(catName) {
	const id = categoryToId(catName);
	const label = _t('app_category.' + id);
	_labelToId[label] = id;
	return label;
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
		h = Math.imul(h, 16777619) >>> 0;
	}
	return h % CHART_PALETTE.length;
}

function getCategoryColor(catName, score) {
	if (score > 0) return '#30D158';
	if (score < 0) return '#FF453A';
	const id = categoryToId(catName);
	if (FIXED_CAT_COLORS[id]) return FIXED_CAT_COLORS[id];
	return CHART_PALETTE[paletteIndex(catName)];
}

const postBridge = makeHostBridge('metrics_apps_bridge');

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
			const r = data[i],
				g = data[i + 1],
				b = data[i + 2],
				a = data[i + 3];
			if (a < 100) continue;
			const lum = (r + g + b) / 3;
			if (lum > 235 || lum < 20) continue;
			const max = Math.max(r, g, b),
				min = Math.min(r, g, b);
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
		entries.map(
			([appName, dataUrl]) =>
				new Promise((resolve) => {
					const img = new Image();
					img.onload = () => {
						const color = extractDominantColorFromImage(img);
						if (color) _dominantColorCache[appName] = color;
						resolve();
					};
					img.onerror = () => resolve();
					img.src = dataUrl;
				})
		)
	).then(() => undefined);
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
