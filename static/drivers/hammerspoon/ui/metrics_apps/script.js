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

let manifestData = window.ManifestData || {};
let userCategories = window.UserCategories || {};
let currentSelectedDate = null;
let currentPeriod = 'day';

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

// Beautiful vibrant palette for neutral/uncategorized elements
const CHART_PALETTE = [
	'#0A84FF', // Blue
	'#BF5AF2', // Purple
	'#FF375F', // Pink
	'#FF9F0A', // Orange
	'#FFD60A', // Yellow
	'#64D2FF', // Light Blue
	'#5E5CE6', // Indigo
	'#32ADE6', // Cyan
	'#E588F8', // Light Pink
	'#F4A460' // Sandy Brown
];

// Fixed aesthetic mappings for standard categories
const FIXED_CAT_COLORS = {
	Productivité: '#0A84FF',
	Développement: '#5E5CE6',
	'Réseaux sociaux': '#FF375F',
	Jeux: '#FF453A',
	Divertissement: '#BF5AF2',
	Utilitaires: '#64D2FF',
	Éducation: '#FF9F0A',
	Business: '#FFD60A',
	Général: '#8E8E93' // Neutral Gray for uncategorized pie pieces
};

function translateCategory(catName) {
	return MAC_CATEGORIES_FR[catName] || catName;
}

function getCategoryColor(catName, score) {
	if (score > 0) return '#30D158'; // Bright Green
	if (score < 0) return '#FF453A'; // Bright Red

	if (FIXED_CAT_COLORS[catName]) return FIXED_CAT_COLORS[catName];

	// Fallback hash for custom categories
	let hash = 0;
	for (let i = 0; i < catName.length; i++) hash = catName.charCodeAt(i) + ((hash << 5) - hash);
	return CHART_PALETTE[Math.abs(hash) % CHART_PALETTE.length];
}

function getAppColor(appName, score) {
	if (score > 0) return '#30D158'; // Bright Green
	if (score < 0) return '#FF453A'; // Bright Red

	// Distribute unique colors to unrated apps for a colorful bar chart
	let hash = 0;
	for (let i = 0; i < appName.length; i++) hash = appName.charCodeAt(i) + ((hash << 5) - hash);
	return CHART_PALETTE[Math.abs(hash) % CHART_PALETTE.length];
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
		timeline: {}
	};

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

	const validDates = allDates.filter(
		(d) => currentPeriod === 'all' || (d.ts <= anchorTs && d.ts >= targetTsStart)
	);

	validDates.forEach((d) => {
		const dayData = manifestData[d.key];
		if (!dayData) return;

		if (dayData._sys) {
			result._sys.sleep += dayData._sys.sleep || 0;
			result._sys.unlock += dayData._sys.unlock || 0;
			result._sys.spaces += dayData._sys.spaces || 0;
			Object.entries(dayData._sys.wifi || {}).forEach(
				([k, v]) => (result._sys.wifi[k] = (result._sys.wifi[k] || 0) + v)
			);
		}

		for (const [appName, appData] of Object.entries(dayData)) {
			if (appName === '_sys') continue;

			if (!result.apps[appName]) {
				result.apps[appName] = { time_ms: 0, typing_time: 0, switches: {} };
			}

			result.apps[appName].time_ms += Number(appData.app_time_ms) || 0;
			result.apps[appName].typing_time +=
				(Number(appData.time) || 0) + (Number(appData.think_time) || 0);
			result.apps[appName].category = appData.category;

			if (appData.switches_to) {
				Object.entries(appData.switches_to).forEach(([dest, count]) => {
					result.apps[appName].switches[dest] = (result.apps[appName].switches[dest] || 0) + count;
				});
			}

			const catData = getAppCategory(appName, appData.category);
			const catName = catData.type;

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
			() => (window.location.href = 'hammerspoon://metricsAppsAction?action=pick')
		);
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

	renderDashboard();
}

window.bootstrapMetricsAppsData = function (newManifest, newCategories) {
	manifestData = newManifest || {};
	userCategories = newCategories || {};
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

	// 1. Top 7 Apps (Colored uniquely by app name, not category)
	const topApps = appsArray.slice(0, 7);
	const barCtx = $id('apps_bar_chart');
	if (barCtx) {
		if (appsBarChart) appsBarChart.destroy();
		appsBarChart = new Chart(barCtx.getContext('2d'), {
			type: 'bar',
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
					x: { grid: { display: false }, ticks: { color: '#ccc', maxRotation: 45, minRotation: 0 } }
				}
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
			currentPeriod === 'day' ? 'Évolution de la journée' : 'Évolution sur la période';

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

				appsArray.push({
					name: appName,
					category: catData.type,
					score: catData.score,
					timeMs: appData.time_ms,
					typingProp: typingProp,
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

		appsArray.sort((a, b) => b.timeMs - a.timeMs);
		updateCharts(appsArray, aggData);

		const tbody = $id('apps-tbody');
		if (tbody) tbody.innerHTML = '';

		if (appsArray.length === 0) {
			if (tbody)
				tbody.innerHTML = `<tr><td colspan="5" style="text-align: center;">Aucune donnée pour cette période.</td></tr>`;
			return;
		}

		appsArray.forEach((app) => {
			const tr = document.createElement('tr');

			const tdName = document.createElement('td');
			tdName.className = 'app-name-cell';
			tdName.innerHTML = `<strong>${escapeHtml(app.name)}</strong>`;
			tr.appendChild(tdName);

			const tdCat = document.createElement('td');
			tdCat.innerHTML = `<span style="font-size: 0.85em; color: var(--text-muted); cursor: pointer;" title="Modifier la catégorie">${escapeHtml(app.category)} ✎</span>`;
			tdCat.addEventListener('click', () => {
				window.location.href = `hammerspoon://metricsAppsAction?action=edit&app=${encodeURIComponent(app.name)}&cat=${encodeURIComponent(app.category)}&score=${app.score}`;
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

			const tdDest = document.createElement('td');
			tdDest.className = 'app-dest-cell';
			tdDest.innerHTML = app.destinations;
			tr.appendChild(tdDest);

			if (tbody) tbody.appendChild(tr);
		});
	} catch (err) {
		safeLog('error', 'Error rendering dashboard', err);
	}
}

document.addEventListener('DOMContentLoaded', initDashboard);
