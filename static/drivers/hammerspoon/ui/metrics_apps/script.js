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
	if (!ms) return '0m';
	const totalMinutes = Math.floor(ms / 60000);
	const hours = Math.floor(totalMinutes / 60);
	const minutes = totalMinutes % 60;
	if (hours > 0) {
		return `${hours}h ${minutes}m`;
	}
	return `${minutes}m`;
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
	console.log('Initializing dashboard…');
	const dateSelect = document.getElementById('date-select');
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
	const dates = Object.keys(manifestData).sort().reverse();

	if (dates.length === 0) {
		currentSelectedDate = null;
		renderDashboard();
		console.log('No data available.');
		return;
	}

	dates.forEach((date) => {
		const option = document.createElement('option');
		option.value = date;
		option.textContent = date;
		dateSelect.appendChild(option);
	});

	currentSelectedDate = dates[0];
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
			.sort()
			.forEach((date) => {
				let exists = false;
				for (let i = 0; i < dateSelect.options.length; i++) {
					if (dateSelect.options[i].value === date) exists = true;
				}
				if (!exists) {
					const option = document.createElement('option');
					option.value = date;
					option.textContent = date;
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
	console.log('Rendering dashboard…');
	const dayData = manifestData[currentSelectedDate] || {};
	let totalTimeMs = 0;
	let totalSwitches = 0;
	let productivityScoreSum = 0;
	let productivityWeightSum = 0;
	let topApp = { name: '--', time: 0 };
	const appsArray = [];

	for (const [appName, appData] of Object.entries(dayData)) {
		const appTime = appData.app_time_ms || 0;
		totalTimeMs += appTime;

		if (appTime > topApp.time && appName !== 'SYSTEM_SLEEP' && appName !== 'SYSTEM_LOCK') {
			topApp = { name: appName, time: appTime };
		}

		if (appData.switches_to) {
			for (const count of Object.values(appData.switches_to)) {
				totalSwitches += count;
			}
		}

		if (appName !== 'SYSTEM_SLEEP' && appName !== 'SYSTEM_LOCK') {
			const typingTime = (appData.time || 0) + (appData.think_time || 0);
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

	const prodColor =
		finalProductivity > 20 ? '#34c759' : finalProductivity < -20 ? '#ff3b30' : '#ffcc00';

	document.getElementById('kpi-total-time').innerHTML = `${formatDuration(totalTimeMs)}`;
	document.getElementById('kpi-top-app').innerHTML = `
		<div style="font-size: 0.9em; font-weight: normal;">${escapeHtml(topApp.name)}</div>
		<div style="color: ${prodColor};">${Math.round(finalProductivity)}% <span style="font-size: 0.5em; color: var(--text-muted);">Score</span></div>
	`;
	document.getElementById('kpi-top-app-time').textContent = formatDuration(topApp.time);
	document.getElementById('kpi-switches').textContent = totalSwitches;

	appsArray.sort((a, b) => b.timeMs - a.timeMs);

	const tbody = document.getElementById('apps-tbody');
	tbody.innerHTML = '';

	if (appsArray.length === 0) {
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

		tbody.appendChild(tr);
	});

	console.log('Dashboard rendered successfully.');
}

document.addEventListener('DOMContentLoaded', initDashboard);
