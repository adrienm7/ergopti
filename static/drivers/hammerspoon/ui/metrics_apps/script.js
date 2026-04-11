/**
 * ==============================================================================
 * MODULE: Apps Time UI Logic
 * DESCRIPTION:
 * Logic for the apps time tracker UI.
 *
 * FEATURES & RATIONALE:
 * 1. Visualizer Engine: Computes raw milliseconds into human-readable tables.
 * 2. Dynamic Categories: Uses macOS native categories provided by the backend.
 * 3. JSON Config Driven: Relies entirely on the Lua backend to store user preferences.
 * 4. Real-Time Updates: Merges live background activity effortlessly.
 * ==============================================================================
 */

let manifestData = window.ManifestData || {};
let userCategories = window.UserCategories || {};
let currentSelectedDate = null;

// Safe console wrapper to avoid errors in older webviews
const safeLog = (fn, ...args) => {
	try {
		if (console && typeof console[fn] === 'function') console[fn](...args);
	} catch (e) {}
};

/** Safe DOM getter */
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

/**
 * Escapes HTML characters to prevent XSS.
 * @param {string} unsafe - The unsafe string.
 * @returns {string} The escaped string.
 */
function escapeHtml(unsafe) {
	if (!unsafe) return '';
	return unsafe
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#039;');
}

/**
 * Formats milliseconds into a readable duration (HHh MMm).
 * @param {number} ms - Milliseconds to format.
 * @returns {string} Formatted string.
 */
function formatDuration(ms) {
	if (!ms && ms !== 0) return '0m';
	const n = Number(ms) || 0;
	const totalMinutes = Math.floor(n / 60000);
	const hours = Math.floor(totalMinutes / 60);
	const minutes = totalMinutes % 60;
	if (hours > 0) {
		return `${hours}h ${minutes}m`;
	}
	return `${minutes}m`;
}

/**
 * Parse a date key produced by the backend into a timestamp (ms).
 * Supports ISO (YYYY-MM-DD) and French-style (DD/MM/YYYY) formats.
 * @param {string} dateStr - The date string key.
 * @returns {number} Timestamp in milliseconds, or NaN if unparsable.
 */
function parseDateKey(dateStr) {
	if (!dateStr || (typeof dateStr !== 'string' && typeof dateStr !== 'number')) return NaN;

	// Numeric epoch keys (seconds or milliseconds)
	if (/^\d+$/.test(String(dateStr))) {
		const n = Number(dateStr);
		// If length <= 10, assume seconds -> convert to ms
		if (String(dateStr).length <= 10) return n * 1000;
		return n; // assume milliseconds
	}

	const s = String(dateStr);

	// ISO-like: 2026-04-11 or 2026/04/11
	const isoMatch = s.match(/^(\d{4})[-\/](\d{2})[-\/](\d{2})/);
	if (isoMatch) {
		const y = parseInt(isoMatch[1], 10);
		const m = parseInt(isoMatch[2], 10) - 1;
		const d = parseInt(isoMatch[3], 10);
		return new Date(y, m, d).getTime();
	}

	// French-style: 11/04/2026
	const frMatch = s.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
	if (frMatch) {
		const d = parseInt(frMatch[1], 10);
		const m = parseInt(frMatch[2], 10) - 1;
		const y = parseInt(frMatch[3], 10);
		return new Date(y, m, d).getTime();
	}

	// Fallback to Date.parse for other formats
	const t = Date.parse(s);
	return isNaN(t) ? NaN : t;
}

/**
 * Returns a user-friendly display label for a date key (DD/MM/YYYY).
 * If parsing fails, returns the original string.
 * @param {string} dateStr
 * @returns {string}
 */
function formatDisplayDate(dateStr) {
	const ts = parseDateKey(dateStr);
	if (isNaN(ts)) return dateStr;
	const d = new Date(ts);
	const dd = String(d.getDate()).padStart(2, '0');
	const mm = String(d.getMonth() + 1).padStart(2, '0');
	const yyyy = d.getFullYear();
	return `${dd}/${mm}/${yyyy}`;
}

// ===================================
// ===================================
// ======= 2/ State Management =======
// ===================================
// ===================================

/**
 * Updates the user categories dictionary injected by the Lua backend.
 * @param {object} newCategories - The updated JSON dictionary.
 */
window.updateUserCategories = function (newCategories) {
	console.log('Received updated categories from Lua config.');
	userCategories = newCategories || {};
	renderDashboard();
};

/**
 * Retrieves the category and productivity score for a given app.
 * @param {string} appName - The name of the application.
 * @param {string} nativeCategory - The official category retrieved from macOS.
 * @returns {object} The category name and score (-2 to 2).
 */
function getAppCategory(appName, nativeCategory) {
	if (userCategories[appName]) {
		return userCategories[appName];
	}
	return { type: nativeCategory || 'Général', score: 0 };
}

// =================================
// =================================
// ======= 3/ Initialization =======
// =================================
// =================================

/**
 * Initializes the dashboard and fills the date select drop-down.
 */
function initDashboard() {
	safeLog('debug', 'Initializing dashboard…');
	const dateSelect = $id('date-select');
	if (!dateSelect) return;

	if (!initDashboard._listenersBound) {
		dateSelect.addEventListener('change', (e) => {
			currentSelectedDate = e.target.value;
			renderDashboard();
		});

		document.getElementById('btn-refresh').addEventListener('click', () => {
			renderDashboard();
		});

		document.getElementById('btn-add-app').addEventListener('click', () => {
			window.location.href = 'hammerspoon://metricsAppsAction?action=pick';
		});

		initDashboard._listenersBound = true;
	}

	dateSelect.innerHTML = '';
	// Build list of date keys with best-effort timestamps.
	const dates = Object.keys(manifestData)
		.map((k) => {
			// accept numeric epoch keys
			if (/^\d+$/.test(k)) return { key: k, ts: Number(k) };
			const ts = parseDateKey(k);
			return { key: k, ts: isNaN(ts) ? Number.NEGATIVE_INFINITY : ts };
		})
		.sort((a, b) => b.ts - a.ts)
		.map((e) => e.key);

	if (dates.length === 0) {
		currentSelectedDate = null;
		renderDashboard();
		console.log('No data available.');
		return;
	}

	dates.forEach((date) => {
		try {
			const option = document.createElement('option');
			option.value = date;
			option.textContent = formatDisplayDate(date);
			dateSelect.appendChild(option);
		} catch (e) {
			safeLog('warn', 'Failed to render date option', date, e);
		}
	});

	currentSelectedDate = dates[0] || null;
	dateSelect.value = currentSelectedDate;

	renderDashboard();
	console.log('Dashboard initialized successfully.');
}

/**
 * Receives data from Lua and refreshes the full dashboard state.
 * @param {object} newManifest - Updated manifest dictionary.
 * @param {object} newCategories - Updated custom categories.
 */
window.bootstrapMetricsAppsData = function (newManifest, newCategories) {
	console.log('Bootstrapping dashboard data from Lua…');
	manifestData = newManifest || {};
	userCategories = newCategories || {};
	initDashboard();
};

/**
 * Updates the local dataset live directly injected by Hammerspoon's daemon.
 * @param {object} newManifest - The updated dictionary.
 */
window.receive_live_update = function (newManifest) {
	if (!newManifest) return;
	console.log('Receiving live updates…');

	Object.keys(newManifest).forEach((dateKey) => {
		manifestData[dateKey] = newManifest[dateKey];
	});

	const dateSelect = document.getElementById('date-select');
	if (dateSelect && Object.keys(newManifest).length > 0) {
		Object.keys(newManifest)
			.sort((a, b) => (parseDateKey(b) || 0) - (parseDateKey(a) || 0))
			.forEach((date) => {
				let exists = false;
				for (let i = 0; i < dateSelect.options.length; i++) {
					if (dateSelect.options[i].value === date) exists = true;
				}
				if (!exists) {
					const option = document.createElement('option');
					option.value = date;
					option.textContent = formatDisplayDate(date);
					dateSelect.insertBefore(option, dateSelect.firstChild);
				}
			});
	}

	renderDashboard();
	console.log('Live updates applied.');
};

// =================================
// =================================
// ======= 4/ Data Rendering =======
// =================================
// =================================

/**
 * Computes metrics and renders the dashboard UI.
 */
function renderDashboard() {
	safeLog('debug', 'Rendering dashboard…', { currentSelectedDate });
	try {
		const dayData = manifestData[currentSelectedDate] || {};
		let totalTimeMs = 0;
		let totalSwitches = 0;
		let productivityScoreSum = 0;
		let productivityWeightSum = 0;
		let topApp = { name: '--', time: 0 };
		const appsArray = [];

		for (const [appName, appData] of Object.entries(dayData)) {
			const appTime = Number(appData.app_time_ms) || 0;
			totalTimeMs += appTime;

			if (appTime > topApp.time && appName !== 'SYSTEM_SLEEP' && appName !== 'SYSTEM_LOCK') {
				topApp = { name: appName, time: appTime };
			}

			if (appData.switches_to) {
				for (const count of Object.values(appData.switches_to)) {
					totalSwitches += Number(count) || 0;
				}
			}

			if (appName !== 'SYSTEM_SLEEP' && appName !== 'SYSTEM_LOCK') {
				const typingTime = (Number(appData.time) || 0) + (Number(appData.think_time) || 0);
				const typingProportion = appTime > 0 ? (typingTime / appTime) * 100 : 0;
				const categoryData = getAppCategory(appName, appData.category);

				productivityScoreSum += categoryData.score * appTime;
				productivityWeightSum += appTime;

				let topDestinations = [];
				if (appData.switches_to) {
					topDestinations = Object.entries(appData.switches_to)
						.sort((a, b) => b[1] - a[1])
						.slice(0, 3)
						.map((entry) => `${escapeHtml(entry[0])} (${entry[1]})`);
				}

				appsArray.push({
					name: appName,
					category: categoryData.type,
					nativeCategory: appData.category,
					score: categoryData.score,
					timeMs: appTime,
					typingProp: typingProportion,
					destinations: topDestinations.join(', ') || '-'
				});
			}
		}

		let finalProductivity = 0;
		if (productivityWeightSum > 0) {
			finalProductivity = (productivityScoreSum / (productivityWeightSum * 2)) * 100;
		}

		const scoreClass =
			finalProductivity > 20 ? 'positive' : finalProductivity < -20 ? 'negative' : 'neutral';

		const elTotal = $id('kpi-total-time');
		if (elTotal) elTotal.innerHTML = `${formatDuration(totalTimeMs)}`;
		const elTop = $id('kpi-top-app');
		if (elTop)
			elTop.innerHTML = `
		<div style="font-size: 0.9em; font-weight: normal;">${escapeHtml(topApp.name)}</div>
		<div><span class="score-badge ${scoreClass}">${Math.round(finalProductivity)}%</span> <span style="font-size: 0.5em; color: var(--text-muted); margin-left:6px;">Score</span></div>
	`;
		const elTopTime = $id('kpi-top-app-time');
		if (elTopTime) elTopTime.textContent = formatDuration(topApp.time);
		const elSwitches = $id('kpi-switches');
		if (elSwitches) elSwitches.textContent = String(totalSwitches);

		appsArray.sort((a, b) => b.timeMs - a.timeMs);

		const tbody = $id('apps-tbody');
		if (tbody) tbody.innerHTML = '';

		if (appsArray.length === 0) {
			if (tbody)
				tbody.innerHTML = `<tr><td colspan="5" style="text-align: center;">Aucune donnée pour ce jour.</td></tr>`;
			return;
		}

		appsArray.forEach((app) => {
			const tr = document.createElement('tr');

			const tdName = document.createElement('td');
			tdName.className = 'app-name-cell';

			const strongEl = document.createElement('strong');
			strongEl.textContent = app.name;

			const brEl = document.createElement('br');

			const catSpan = document.createElement('span');
			catSpan.style.fontSize = '0.8em';
			catSpan.style.color = 'var(--text-muted)';
			catSpan.style.cursor = 'pointer';
			catSpan.title = 'Cliquez pour reclasser l’application';
			catSpan.textContent = `${app.category} ✎`;

			// Ping Lua backend to show native dialog
			catSpan.addEventListener('click', () => {
				const currentCat = encodeURIComponent(app.category);
				const currentScore = app.score;
				window.location.href = `hammerspoon://metricsAppsAction?action=edit&app=${encodeURIComponent(app.name)}&cat=${currentCat}&score=${currentScore}`;
			});

			tdName.appendChild(strongEl);
			tdName.appendChild(brEl);
			tdName.appendChild(catSpan);

			tr.appendChild(tdName);

			const tdTime = document.createElement('td');
			tdTime.className = 'app-time-cell';
			tdTime.textContent = formatDuration(app.timeMs);
			tr.appendChild(tdTime);

			const tdProd = document.createElement('td');
			tdProd.className = 'app-type-cell';
			let dotColor = app.score > 0 ? '#34c759' : app.score < 0 ? '#ff3b30' : '#ffcc00';
			tdProd.innerHTML = `<span style="display:inline-block; width:10px; height:10px; border-radius:50%; background-color:${dotColor}; margin-right:5px;"></span>`;
			tr.appendChild(tdProd);

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
		safeLog('info', 'Dashboard rendered successfully.');
		// If everything shows zero time but apps exist, log the raw dayData for debugging
		if (totalTimeMs === 0 && appsArray.length > 0) {
			safeLog(
				'warn',
				'Total time is zero but apps present for date',
				currentSelectedDate,
				manifestData[currentSelectedDate]
			);
		}
	} catch (err) {
		safeLog('error', 'Error while rendering dashboard', err);
	}
}

document.addEventListener('DOMContentLoaded', initDashboard);
