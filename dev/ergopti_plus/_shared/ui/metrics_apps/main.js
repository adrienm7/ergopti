// _shared/ui/metrics_apps/main.js
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
		$id('btn-add-app').addEventListener('click', () => {
			postBridge({ action: 'pick' });
		});
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
	setTimeout(() => {
		try {
			renderDashboard();
		} catch (_) {}
	}, 0);
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
	const wkBox = document.getElementById('weekday-filter-buttons');
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
		catBox.innerHTML = catList
			.map((c) => {
				const active = !currentCategoryFilter || currentCategoryFilter.has(c);
				return `<button class="filter-btn${active ? ' active' : ''}" data-cat="${escapeHtml(c)}" style="padding:3px 9px;font-size:11px;">${escapeHtml(c)}</button>`;
			})
			.join('');
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
		wkBox.innerHTML = wkLabels
			.map((label, idx) => {
				const active = !currentWeekdayFilter || currentWeekdayFilter.has(idx);
				return `<button class="filter-btn${active ? ' active' : ''}" data-dow="${idx}" style="padding:3px 9px;font-size:11px;">${label}</button>`;
			})
			.join('');
		[...wkBox.querySelectorAll('button[data-dow]')].forEach((btn) => {
			btn.addEventListener('click', () => {
				const dow = +btn.getAttribute('data-dow');
				if (!currentWeekdayFilter) currentWeekdayFilter = new Set([0, 1, 2, 3, 4, 5, 6]);
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
			img.onload = () => {
				if (appsBarChart) appsBarChart.draw();
			};
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
				const density = focus_min > 0 ? (appData.chars || 0) / focus_min : 0;
				const focus_lat_mean =
					(appData.focus_latency_count || 0) > 0
						? appData.focus_latency_sum_ms / appData.focus_latency_count
						: 0;
				const hs_pct =
					(appData.chars || 0) > 0 ? ((appData.hs_chars || 0) / appData.chars) * 100 : 0;

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
		const active_ratio =
			focus_minus_passive > 0 ? ((rt.active_ms || 0) / focus_minus_passive) * 100 : 0;

		const setText = (id, txt) => {
			const el = $id(id);
			if (el) el.textContent = txt;
		};
		const setHtml = (id, html) => {
			const el = $id(id);
			if (el) el.innerHTML = html;
		};

		setText('kpi-active-time', formatDuration(rt.active_ms || 0));
		setText(
			'kpi-active-ratio',
			focus_minus_passive > 0 ? `${active_ratio.toFixed(1)}% du focus net` : '—'
		);

		setText('kpi-passive-time', passive_ms > 0 ? formatDuration(passive_ms) : '—');
		setText(
			'kpi-passive-detail',
			passive_ms > 0
				? `verrou ${formatDuration(rt.passive_locked_ms || 0)} · veille ${formatDuration(rt.passive_sleep_ms || 0)}`
				: _t('ui_apps.kpi_no_lock')
		);

		// First / last typed
		const fmtMin = (m) => (m && m.str ? m.str : '—');
		const first = r.day_first,
			last = r.day_last;
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
			setText(
				'kpi-day-amplitude',
				`amplitude ${Math.floor(amp_min / 60)}h${String(amp_min % 60).padStart(2, '0')}`
			);
		} else {
			setText('kpi-day-bounds', '—');
			setText('kpi-day-amplitude', _t('ui_apps.kpi_no_keystrokes'));
		}

		// Longest session
		if ((rs.longest_ms || 0) > 0) {
			setText('kpi-longest-session', formatDuration(rs.longest_ms));
			setText(
				'kpi-longest-session-app',
				rs.longest_app ? _t('ui_apps.kpi_in_app').replace('{name}', rs.longest_app) : ''
			);
		} else {
			setText('kpi-longest-session', '—');
			setText('kpi-longest-session-app', _t('ui_apps.kpi_no_session'));
		}

		// Sessions count + mean
		const session_mean_ms = (rs.count || 0) > 0 ? (rs.total_active_ms || 0) / rs.count : 0;
		setText('kpi-sessions-count', String(rs.count || 0));
		setText(
			'kpi-sessions-mean',
			session_mean_ms > 0
				? _t('ui_apps.kpi_session_mean').replace('{dur}', formatDuration(session_mean_ms))
				: '—'
		);

		// Density: chars / focus minute
		const density_cpm =
			(rt.focus_ms || 0) > 0 ? ((r.typing && r.typing.chars) || 0) / (rt.focus_ms / 60000) : 0;
		setText('kpi-density', density_cpm > 0 ? `${density_cpm.toFixed(0)}` : '—');
		setText(
			'kpi-density-detail',
			density_cpm > 0 ? _t('ui_apps.kpi_car_per_min') : _t('ui_apps.kpi_no_keystrokes')
		);

		// ── Multitâche / context-switching KPIs ───────────────────────────
		// Compute aggregates across the period from appsArray + aggData.
		const apps_by_time = [...appsArray].sort((a, b) => b.timeMs - a.timeMs);
		const sum_focus_ms = apps_by_time.reduce((s, a) => s + (a.timeMs || 0), 0);

		// App-hopping rate = switches / focus-minute. Focus-minute is the
		// "time you actually had an app at the foreground" minus passive.
		const focus_min_eff = focus_minus_passive / 60000;
		const hopping_rate = focus_min_eff > 0 ? totalSwitches / focus_min_eff : 0;
		setText('kpi-hopping-rate', focus_min_eff > 0 ? `${hopping_rate.toFixed(1)}` : '—');
		setText(
			'kpi-hopping-detail',
			focus_min_eff > 0 ? _t('ui_apps.kpi_hopping_detail') : _t('ui_apps.kpi_no_focus')
		);

		// Profondeur moyenne par app = Σ app_time / Σ switches
		const depth_mean_ms = totalSwitches > 0 ? sum_focus_ms / totalSwitches : 0;
		setText('kpi-depth-mean', depth_mean_ms > 0 ? formatDuration(depth_mean_ms) : '—');
		setText(
			'kpi-depth-detail',
			depth_mean_ms > 0
				? _t('ui_apps.kpi_switches_between').replace('{n}', totalSwitches)
				: _t('ui_apps.kpi_no_switch')
		);

		// Top trio
		const top3 = apps_by_time.slice(0, 3);
		const top3_share =
			sum_focus_ms > 0 ? (top3.reduce((s, a) => s + a.timeMs, 0) / sum_focus_ms) * 100 : 0;
		setText('kpi-top-trio-share', top3.length > 0 ? `${top3_share.toFixed(0)}%` : '—');
		setHtml(
			'kpi-top-trio-list',
			top3.length > 0 ? top3.map((a) => escapeHtml(a.name)).join(' · ') : '—'
		);

		// App pivot = app with the most distinct outgoing destinations
		let pivot = null,
			pivot_dests = 0;
		for (const [appName, appData] of Object.entries(aggData.apps)) {
			const distinct = appData.switches ? Object.keys(appData.switches).length : 0;
			if (distinct > pivot_dests) {
				pivot = appName;
				pivot_dests = distinct;
			}
		}
		setText('kpi-pivot-app', pivot ? pivot : '—');
		setText(
			'kpi-pivot-detail',
			pivot
				? _t('ui_apps.kpi_towards_apps').replace('{n}', pivot_dests)
				: _t('ui_apps.kpi_no_switch')
		);

		// Index focus = part du temps focus dans la top app
		const focus_index =
			sum_focus_ms > 0 && apps_by_time.length > 0
				? (apps_by_time[0].timeMs / sum_focus_ms) * 100
				: 0;
		setText('kpi-focus-index', apps_by_time.length > 0 ? `${focus_index.toFixed(0)}%` : '—');
		setText(
			'kpi-focus-index-detail',
			apps_by_time.length > 0
				? _t('ui_apps.kpi_in_app').replace('{name}', apps_by_time[0].name)
				: ''
		);

		// Context volume = sum of switching events on the period
		setText('kpi-context-volume', String(totalSwitches));
		setText(
			'kpi-context-detail',
			r.time && r.time.passive_count > 0
				? `+ ${r.time.passive_count} verrou(s) / veille(s)`
				: _t('ui_apps.kpi_app_switches')
		);

		// ── Records personnels (period-best scores) ───────────────────────
		const rb = r.bursts || {};
		const re = r.ergonomics || {};
		const rty = r.typing || {};
		setText('kpi-rec-burst', (rb.max_cpm || 0) > 0 ? `${rb.max_cpm.toFixed(0)} CPM` : '—');
		setText(
			'kpi-rec-burst-detail',
			(rb.count || 0) > 0
				? _t('ui_apps.kpi_bursts_count').replace('{n}', rb.count)
				: _t('ui_apps.kpi_no_burst')
		);
		setText('kpi-rec-burst-chars', (rb.max_chars || 0) > 0 ? format_int(rb.max_chars) : '—');
		setText(
			'kpi-rec-burst-chars-detail',
			(rb.max_chars || 0) > 0 ? _t('ui_apps.kpi_chars_in_a_row') : ''
		);

		setText('kpi-rec-session', (rs.longest_ms || 0) > 0 ? formatDuration(rs.longest_ms) : '—');
		setText(
			'kpi-rec-session-detail',
			rs.longest_app ? _t('ui_apps.kpi_in_app').replace('{name}', rs.longest_app) : ''
		);

		setText(
			'kpi-rec-finger-streak',
			(re.same_finger_streak_max || 0) > 0 ? `${re.same_finger_streak_max} touches` : '—'
		);
		setText(
			'kpi-rec-finger-streak-detail',
			(re.same_hand_streak_max || 0) > 0 ? `main : ${re.same_hand_streak_max} touches` : ''
		);

		setText(
			'kpi-rec-cascade',
			(rty.cascade_max_len || 0) > 0 ? `${rty.cascade_max_len} backspaces` : '—'
		); // "backspaces" is a technical term, kept as-is
		setText(
			'kpi-rec-cascade-detail',
			(rty.cascade_count_total || 0) > 0
				? _t('ui_apps.kpi_cascades_period').replace('{n}', rty.cascade_count_total)
				: ''
		);

		// Top day by chars
		let best_day = null,
			best_day_chars = 0;
		Object.entries(r.by_date || {}).forEach(([date_str, day]) => {
			if ((day.chars || 0) > best_day_chars) {
				best_day_chars = day.chars;
				best_day = date_str;
			}
		});
		setText('kpi-rec-day-chars', best_day_chars > 0 ? format_int(best_day_chars) : '—');
		setText(
			'kpi-rec-day-chars-detail',
			best_day ? _t('ui_apps.kpi_day_best').replace('{date}', formatDisplayDate(best_day)) : ''
		);

		// ── Typing × Temps (#40-43, 49) ───────────────────────────────────
		const fl = r.focus_latency || { sum_ms: 0, count: 0 };
		const flMs = (fl.count || 0) > 0 ? fl.sum_ms / fl.count : 0;
		setText('kpi-tx-focus-lat', flMs > 0 ? `${flMs.toFixed(0)} ms` : '—');
		setText(
			'kpi-tx-focus-lat-detail',
			(fl.count || 0) > 0
				? _t('ui_apps.kpi_focus_taken').replace('{n}', fl.count)
				: _t('ui_apps.kpi_not_measured')
		);

		const layoutsCount = Object.keys(r.layouts || {}).length;
		setText('kpi-tx-layouts', String(layoutsCount));
		const topLayout = Object.entries(r.layouts || {}).sort((a, b) => b[1] - a[1])[0];
		setText(
			'kpi-tx-layouts-detail',
			topLayout ? _t('ui_apps.kpi_top_layout').replace('{name}', topLayout[0]) : '—'
		);

		setText('kpi-tx-long-sessions', String(r.long_sessions || 0));
		setText(
			'kpi-tx-long-sessions-detail',
			(r.long_sessions || 0) > 0 ? _t('ui_apps.kpi_app_days_90') : _t('ui_apps.kpi_no_long_session')
		);

		const totalChars = (r.typing && r.typing.chars) || 0;
		const autoRepCount = (r.typing && r.typing.auto_repeat_count) || 0;
		const arPct = totalChars > 0 ? (autoRepCount / totalChars) * 100 : 0;
		setText('kpi-tx-autorepeat', totalChars > 0 ? `${arPct.toFixed(1)} %` : '—');
		setText(
			'kpi-tx-autorepeat-detail',
			autoRepCount > 0
				? `${format_int(autoRepCount)} touches répétées`
				: _t('ui_apps.kpi_no_repeat')
		);

		// Worst app for errors (#49): highest bs_total / chars (min 200 chars to avoid noise)
		let wErrApp = null,
			wErrPct = 0;
		Object.entries(aggData.apps || {}).forEach(([name, a]) => {
			if ((a.chars || 0) >= 200) {
				const p = ((a.bs_total || 0) / a.chars) * 100;
				if (p > wErrPct) {
					wErrPct = p;
					wErrApp = name;
				}
			}
		});
		setText('kpi-tx-error-app', wErrApp || '—');
		setText(
			'kpi-tx-error-app-detail',
			wErrApp ? `${wErrPct.toFixed(1)} % de backspaces` : _t('ui_apps.kpi_no_enough_typing')
		);

		// Worst app for recovery (#50)
		let wRecApp = null,
			wRecMs = 0;
		Object.entries(aggData.apps || {}).forEach(([name, a]) => {
			if ((a.recovery_count || 0) >= 5) {
				const m = a.recovery_sum_ms / a.recovery_count;
				if (m > wRecMs) {
					wRecMs = m;
					wRecApp = name;
				}
			}
		});
		setText('kpi-tx-recovery-app', wRecApp || '—');
		setText(
			'kpi-tx-recovery-app-detail',
			wRecApp ? `${wRecMs.toFixed(0)} ms en moyenne` : _t('ui_apps.kpi_no_enough_errors')
		);

		// CPM par catégorie (#47)
		(function renderCpmByCategory() {
			const canvas = document.getElementById('cpm_by_category_chart');
			if (!canvas || typeof Chart === 'undefined') return;
			const cats = Object.entries(r.by_category || {})
				.map(([cat, c]) => ({
					cat,
					cpm: (c.time_ms || 0) > 0 ? (c.chars || 0) / (c.time_ms / 60000) : 0
				}))
				.filter((x) => x.cpm > 0)
				.sort((a, b) => b.cpm - a.cpm);
			if (window._cpmByCatChart) window._cpmByCatChart.destroy();
			if (cats.length === 0) return;
			window._cpmByCatChart = new Chart(canvas.getContext('2d'), {
				type: 'bar',
				data: {
					labels: cats.map((c) => c.cat),
					datasets: [
						{
							label: 'CPM',
							data: cats.map((c) => +c.cpm.toFixed(0)),
							backgroundColor: cats.map((c) => getCategoryColor(c.cat, 0)),
							borderRadius: 4
						}
					]
				},
				options: {
					responsive: true,
					maintainAspectRatio: false,
					plugins: { legend: { display: false } },
					scales: {
						x: { grid: { display: false }, ticks: { color: '#ccc' } },
						y: {
							beginAtZero: true,
							grid: { color: 'rgba(255,255,255,0.08)' },
							ticks: { color: '#ccc' }
						}
					}
				}
			});
		})();

		// ── Productivité (#20–22) ─────────────────────────────────────────
		const ps = r.prod_split || { positive_ms: 0, neutral_ms: 0, negative_ms: 0 };
		const psSum = (ps.positive_ms || 0) + (ps.neutral_ms || 0) + (ps.negative_ms || 0);
		const elProdBar = $id('kpi-prod-bar');
		if (elProdBar) {
			if (psSum > 0) {
				const pPos = (ps.positive_ms / psSum) * 100;
				const pNeu = (ps.neutral_ms / psSum) * 100;
				const pNeg = (ps.negative_ms / psSum) * 100;
				elProdBar.innerHTML =
					`<div title="Productif" style="background:#30D158;width:${pPos}%"></div>` +
					`<div title="Neutre"    style="background:#8e8e93;width:${pNeu}%"></div>` +
					`<div title="Distraction" style="background:#FF453A;width:${pNeg}%"></div>`;
				setText(
					'kpi-prod-bar-detail',
					_t('ui_apps.kpi_productive')
						.replace('{p}', pPos.toFixed(0))
						.replace('{n}', pNeu.toFixed(0))
						.replace('{d}', pNeg.toFixed(0))
				);
			} else {
				elProdBar.innerHTML = '';
				setText('kpi-prod-bar-detail', _t('ui_apps.kpi_no_data'));
			}
		}

		// #21 Best hour by productivity (score-weighted)
		let bestHour = null,
			bestHourScore = -Infinity;
		Object.entries(r.by_hour || {}).forEach(([hh, slot]) => {
			if ((slot.time_ms || 0) > 0) {
				const avg = (slot.score_x_ms || 0) / slot.time_ms;
				if (avg > bestHourScore) {
					bestHourScore = avg;
					bestHour = hh;
				}
			}
		});
		if (bestHour != null) {
			setText('kpi-best-hour', `${bestHour}h`);
			setText(
				'kpi-best-hour-detail',
				_t('ui_apps.kpi_best_hour_score').replace('{score}', bestHourScore.toFixed(2))
			);
		} else {
			setText('kpi-best-hour', '—');
			setText('kpi-best-hour-detail', _t('ui_apps.kpi_no_focus_tracked'));
		}

		// #22 Dominant category per weekday — render as compact 7-day rundown
		const DOW_LABELS = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];
		const wkLines = [];
		let domToday = null;
		const todayDow = (new Date().getDay() + 6) % 7;
		Object.entries(r.weekday_category || {}).forEach(([dow, cats]) => {
			let topCat = null,
				topMs = 0;
			Object.entries(cats).forEach(([c, ms]) => {
				if (ms > topMs) {
					topMs = ms;
					topCat = c;
				}
			});
			if (topCat) {
				wkLines.push(`${DOW_LABELS[+dow]} : ${topCat}`);
				if (+dow === todayDow) domToday = topCat;
			}
		});
		setText('kpi-dom-cat', domToday || (wkLines.length > 0 ? wkLines[0].split(' : ')[1] : '—'));
		setText(
			'kpi-dom-cat-detail',
			wkLines.length > 0 ? wkLines.join(' · ') : _t('ui_apps.kpi_no_day_data')
		);

		// ── Streaks (#58) ─────────────────────────────────────────────────
		// Compute the longest run of consecutive calendar days where the
		// criterion holds. Uses ALL manifest dates (not just the filtered
		// period) so the streak is meaningful as a global record.
		(function renderStreaks() {
			const allKeys = Object.keys(manifestData || {})
				.map((k) => ({ key: k, ts: parseDateKey(k) }))
				.filter((d) => !isNaN(d.ts))
				.sort((a, b) => a.ts - b.ts);
			const dayChars = {};
			const dayActive = {};
			allKeys.forEach((d) => {
				let chars = 0,
					active = 0;
				Object.entries(manifestData[d.key] || {}).forEach(([n, a]) => {
					if (n === '_sys' || n === '_system') return;
					chars += a.chars || 0;
					active += a.time || 0;
				});
				dayChars[d.key] = chars;
				dayActive[d.key] = active;
			});
			const longestRun = (predicate) => {
				let best = 0,
					cur = 0,
					prevTs = null;
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
			setText(
				'kpi-streak-chars-detail',
				streakChars > 0 ? _t('ui_apps.kpi_streak_chars') : _t('ui_apps.kpi_never_reached')
			);
			setText('kpi-streak-focus', `${streakFocus} j`);
			setText(
				'kpi-streak-focus-detail',
				streakFocus > 0 ? _t('ui_apps.kpi_streak_focus') : _t('ui_apps.kpi_never_reached')
			);
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

			const todayKey = currentSelectedDate || Object.keys(manifestData).sort().slice(-1)[0];
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
			setText(
				'kpi-goal-detail',
				pct >= 100
					? _t('ui_apps.goal_reached')
					: _t('ui_apps.goal_remaining').replace('{pct}', (100 - pct).toFixed(0))
			);

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
		const lock_ms = rt.passive_locked_ms || 0;
		const sleep_ms = rt.passive_sleep_ms || 0;
		setText('kpi-sys-passive', String(rt.passive_count || 0));
		setText(
			'kpi-sys-passive-detail',
			(rt.passive_count || 0) > 0
				? _t('ui_apps.kpi_lock_sleep_cumul').replace('{dur}', formatDuration(lock_ms + sleep_ms))
				: _t('ui_apps.kpi_no_lock')
		);

		setText(
			'kpi-sys-lock-vs-sleep',
			lock_ms + sleep_ms > 0 ? `${formatDuration(lock_ms)} / ${formatDuration(sleep_ms)}` : '—'
		);
		setText(
			'kpi-sys-lock-vs-sleep-detail',
			lock_ms + sleep_ms > 0 ? _t('ui_apps.kpi_lock_vs_sleep') : ''
		);

		setText('kpi-sys-wifi', String(sys.wifi_changes || 0));
		setText(
			'kpi-sys-wifi-detail',
			(sys.wifi_changes || 0) > 0 ? _t('ui_apps.kpi_wifi_switches') : _t('ui_apps.kpi_no_mobility')
		);

		const bat_avg =
			(sys.battery_count || 0) > 0 ? Math.round(sys.battery_sum / sys.battery_count) : null;
		setText('kpi-sys-battery', bat_avg != null ? `${bat_avg}%` : '—');
		setText(
			'kpi-sys-battery-detail',
			sys.battery_min != null
				? `min ${Math.round(sys.battery_min)}% · max ${Math.round(sys.battery_max)}%`
				: _t('ui_apps.kpi_no_data')
		);

		const muted_pct = (rt.focus_ms || 0) > 0 ? ((sys.audio_muted_ms || 0) / rt.focus_ms) * 100 : 0;
		setText(
			'kpi-sys-mute',
			(sys.audio_muted_ms || 0) > 0 ? formatDuration(sys.audio_muted_ms) : '—'
		);
		setText(
			'kpi-sys-mute-detail',
			(sys.audio_muted_ms || 0) > 0
				? _t('ui_apps.kpi_pct_focus_time').replace('{pct}', muted_pct.toFixed(0))
				: _t('ui_apps.kpi_no_mute')
		);

		setText('kpi-sys-spaces', String(sys.space_switches || 0));
		setText(
			'kpi-sys-spaces-detail',
			(sys.space_switches || 0) > 0 ? _t('ui_apps.kpi_space_switches') : '—'
		);

		setText('kpi-sys-night', String(sys.night_wake_count || 0));
		setText(
			'kpi-sys-night-detail',
			(sys.night_wake_count || 0) > 0
				? _t('ui_apps.kpi_night_wakes')
				: _t('ui_apps.kpi_sleep_intact')
		);

		const awakeMs = rt.awake_ms || 0;
		setText('kpi-sys-awake', awakeMs > 0 ? formatDuration(awakeMs) : '—');
		setText(
			'kpi-sys-awake-detail',
			awakeMs > 0
				? currentCountAwake
					? _t('ui_apps.kpi_awake_included')
					: _t('ui_apps.kpi_awake_excluded')
				: _t('ui_apps.kpi_never_active')
		);

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
			tdSfb.textContent =
				(_sfbApp.same_finger_streak_max || 0) > 0 ? String(_sfbApp.same_finger_streak_max) : '—';
			tr.appendChild(tdSfb);

			// #52 Modifier hold mean ms for this app
			const tdHold = document.createElement('td');
			tdHold.style.textAlign = 'right';
			const _hSum = _sfbApp.kc_hold_sum_ms || 0;
			const _hCnt = _sfbApp.kc_hold_count || 0;
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
			banner.style.cssText =
				'position:fixed;bottom:8px;left:8px;right:8px;z-index:9999;background:rgba(255,69,58,0.95);color:#fff;font:12px/1.4 system-ui;padding:8px 12px;border-radius:6px;white-space:pre-wrap;max-height:160px;overflow:auto;';
			document.body.appendChild(banner);
		}
		banner.textContent = `[render error] ${err && err.stack ? err.stack : err}`;
	}
}

// =====================================================
// =====================================================
