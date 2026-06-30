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
	'#5AC8FA' // Light Blue
];

// Fixed aesthetic mappings for standard categories — each hue is deliberately distant
const FIXED_CAT_COLORS = {
	Productivité: '#0A84FF', // Blue
	Développement: '#5E5CE6', // Indigo
	'Réseaux sociaux': '#FF375F', // Pink-Red
	Jeux: '#FF453A', // Deep Red
	Divertissement: '#BF5AF2', // Purple
	Utilitaires: '#64D2FF', // Sky Blue
	Éducation: '#FF9F0A', // Orange
	Business: '#FFD60A', // Yellow
	Finance: '#30B0C7', // Teal
	Design: '#E588F8', // Lavender
	Photographie: '#FF6B35', // Burnt Orange
	Vidéo: '#FF375F', // Coral
	Musique: '#32D74B', // Green
	'Santé & Forme': '#34C759', // Leaf Green
	Actualités: '#F4A460', // Sandy
	Météo: '#5AC8FA', // Light Blue
	Voyage: '#00C7BE', // Cyan-Teal
	Général: '#8E8E93' // Neutral Gray for uncategorized pieces
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
		h = Math.imul(h, 16777619) >>> 0;
	}
	return h % CHART_PALETTE.length;
}

function getCategoryColor(catName, score) {
	if (score > 0) return '#30D158';
	if (score < 0) return '#FF453A';
	if (FIXED_CAT_COLORS[catName]) return FIXED_CAT_COLORS[catName];
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
