// _shared/ui/metrics_apps/modal.js
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
	const anchorTs = currentSelectedDate
		? parseDateKey(currentSelectedDate)
		: allDates.length > 0
			? Math.max(...allDates.map((d) => d.ts))
			: 0;
	if (currentPeriod === 'day') targetTsStart = anchorTs;
	if (currentPeriod === 'week') targetTsStart = anchorTs - 7 * 86400000;
	if (currentPeriod === 'month') targetTsStart = anchorTs - 30 * 86400000;
	if (currentPeriod === 'year') targetTsStart = anchorTs - 365 * 86400000;

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
			slot.chars += hData.c || 0;
		});
	});

	// Title
	document.getElementById('app_modal_title').textContent = appName;

	// Stat tiles
	const focus_min = (a.time_ms || 0) / 60000;
	const density = focus_min > 0 ? (a.chars || 0) / focus_min : 0;
	const focus_lat_mean =
		(a.focus_latency_count || 0) > 0 ? a.focus_latency_sum_ms / a.focus_latency_count : 0;
	const tiles = [
		{ label: _t('ui_apps.tile_focus'), value: formatDuration(a.time_ms || 0), detail: '' },
		{
			label: _t('ui_apps.tile_typing'),
			value: formatDuration(a.typing_time || 0),
			detail:
				a.time_ms > 0
					? _t('ui_apps.modal_pct_focus').replace(
							'{pct}',
							((a.typing_time / a.time_ms) * 100).toFixed(1)
						)
					: ''
		},
		{
			label: _t('ui_apps.tile_chars'),
			value: format_int(a.chars || 0),
			detail: density > 0 ? _t('ui_apps.modal_density').replace('{n}', density.toFixed(0)) : ''
		},
		{
			label: _t('ui_apps.tile_sessions'),
			value: String(a.session_count || 0),
			detail:
				a.session_longest_ms > 0
					? _t('ui_apps.modal_longest_session').replace(
							'{dur}',
							formatDuration(a.session_longest_ms)
						)
					: ''
		},
		{
			label: _t('ui_apps.tile_focus_lat'),
			value: focus_lat_mean > 0 ? `${Math.round(focus_lat_mean)} ms` : '—',
			detail: a.focus_latency_count > 0 ? `n=${a.focus_latency_count}` : ''
		},
		{
			label: _t('ui_apps.tile_backspaces'),
			value: format_int(a.bs_total || 0),
			detail:
				a.chars > 0
					? _t('ui_apps.modal_backspace_pct').replace(
							'{pct}',
							((a.bs_total / a.chars) * 100).toFixed(1)
						)
					: ''
		}
	];
	document.getElementById('app_modal_tiles').innerHTML = tiles
		.map(
			(t) =>
				`<div class="app-modal-tile">
			<div class="app-modal-tile-label">${escapeHtml(t.label)}</div>
			<div class="app-modal-tile-value">${escapeHtml(t.value)}</div>
			${t.detail ? `<div class="app-modal-tile-detail">${escapeHtml(t.detail)}</div>` : ''}
		</div>`
		)
		.join('');

	// Hourly chart
	const labels = [],
		chars_arr = [];
	for (let h = 0; h < 24; h++) {
		const hh = String(h).padStart(2, '0');
		labels.push(`${hh}h`);
		chars_arr.push((hourly[hh] && hourly[hh].chars) || 0);
	}
	const ctx = document.getElementById('app_modal_hourly').getContext('2d');
	if (_appModalChart) _appModalChart.destroy();
	_appModalChart = new Chart(ctx, {
		type: 'bar',
		data: {
			labels,
			datasets: [
				{
					label: _t('ui_apps.ds_chars'),
					data: chars_arr,
					backgroundColor: 'rgba(34, 211, 238, 0.55)',
					borderRadius: 2
				}
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: { legend: { display: false } },
			scales: {
				x: {
					ticks: { color: '#888', font: { size: 9 } },
					grid: { color: 'rgba(255,255,255,0.04)' }
				},
				y: {
					ticks: { color: '#888', font: { size: 9 } },
					grid: { color: 'rgba(255,255,255,0.04)' }
				}
			}
		}
	});

	// Destinations
	const dest_html =
		a.switches && Object.keys(a.switches).length > 0
			? Object.entries(a.switches)
					.sort((x, y) => y[1] - x[1])
					.slice(0, 8)
					.map(
						([dest, n]) =>
							`<div style="display:flex;justify-content:space-between;padding:3px 0;font-size:12px;"><span>${escapeHtml(dest)}</span><span style="color:#aaa;">${n}</span></div>`
					)
					.join('')
			: `<div style="color:#888;font-size:12px;">${_t('ui_apps.kpi_no_backslash_out')}</div>`;
	document.getElementById('app_modal_dests').innerHTML = dest_html;

	// Layouts seen — sum from manifest for this app within the period.
	const layouts = {};
	allDates.forEach((d) => {
		if (currentPeriod !== 'all' && (d.ts > anchorTs || d.ts < targetTsStart)) return;
		const ls =
			manifestData[d.key] &&
			manifestData[d.key][appName] &&
			manifestData[d.key][appName].layouts_seen;
		if (!ls) return;
		Object.entries(ls).forEach(([id, n]) => {
			layouts[id] = (layouts[id] || 0) + (n || 0);
		});
	});
	const layouts_html =
		Object.keys(layouts).length > 0
			? Object.entries(layouts)
					.sort((x, y) => y[1] - x[1])
					.map(
						([id, n]) =>
							`<div style="display:flex;justify-content:space-between;padding:3px 0;font-size:12px;"><span>${escapeHtml(id)}</span><span style="color:#aaa;">${n}×</span></div>`
					)
					.join('')
			: `<div style="color:#888;font-size:12px;">${_t('ui_apps.kpi_no_layout')}</div>`;
	document.getElementById('app_modal_layouts').innerHTML = layouts_html;

	// Records
	const recs = [];
	if (a.session_longest_ms > 0) {
		recs.push(
			`<div>${_t('ui_apps.modal_record_session')
				.replace('{dur}', formatDuration(a.session_longest_ms))
				.replace(
					'{chars}',
					a.session_longest_chars > 0 ? ` (${a.session_longest_chars} car.)` : ''
				)}</div>`
		);
	}
	if ((a.burst_max_cpm || 0) > 0) {
		recs.push(
			`<div>${_t('ui_apps.modal_record_burst').replace('{n}', a.burst_max_cpm.toFixed(0))}</div>`
		);
	}
	if ((a.cascade_count || 0) > 0) {
		recs.push(`<div>${_t('ui_apps.modal_record_cascade').replace('{n}', a.cascade_count)}</div>`);
	}
	const rec_html =
		recs.length > 0
			? recs.map((r) => `<div style="font-size:12px;padding:3px 0;">${r}</div>`).join('')
			: `<div style="color:#888;font-size:12px;">${_t('ui_apps.kpi_no_record')}</div>`;
	document.getElementById('app_modal_records').innerHTML = rec_html;

	// Hotstrings & IA
	const hs_pct = (a.chars || 0) > 0 ? (a.hs_chars / a.chars) * 100 : 0;
	const llm_pct = (a.chars || 0) > 0 ? (a.llm_chars / a.chars) * 100 : 0;
	document.getElementById('app_modal_assist').innerHTML =
		`<div style="font-size:12px;padding:3px 0;">${_t('ui_apps.modal_hs_line')
			.replace('{n}', format_int(a.hs_chars || 0))
			.replace('{pct}', hs_pct.toFixed(1))}</div>` +
		`<div style="font-size:12px;padding:3px 0;">${_t('ui_apps.modal_llm_line')
			.replace('{n}', format_int(a.llm_chars || 0))
			.replace('{pct}', llm_pct.toFixed(1))}</div>` +
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
