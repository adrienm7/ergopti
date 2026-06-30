// _shared/ui/metrics_apps/charts.js
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
	const W = 7,
		H = 24;

	// Find max for colour scaling
	let max_v = 0;
	HOURS.forEach((hh) => {
		for (let wd = 0; wd < W; wd++) {
			const cell = grid[`${hh}|${wd}`];
			if (!cell) continue;
			const v = mode === 'time' ? cell.time_ms || 0 : cell.chars || 0;
			if (v > max_v) max_v = v;
		}
	});

	if (max_v === 0) {
		container.innerHTML = `<div style="color:var(--text-muted);font-size:12px;padding:10px;">${_t('ui_apps.empty_activity')}</div>`;
		return;
	}

	const CELL = 24; // px per cell
	const GAP = 2;
	const LABEL_LEFT = 38;
	const LABEL_TOP = 18;
	const SVG_W = LABEL_LEFT + W * (CELL + GAP);
	const SVG_H = LABEL_TOP + H * (CELL + GAP);

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
			const v = !cell ? 0 : mode === 'time' ? cell.time_ms || 0 : cell.chars || 0;
			const fill = heat(v);
			const tip_v = mode === 'time' ? (v > 0 ? formatDuration(v) : '0') : v > 0 ? `${v} car.` : '0';
			const tip = `${WEEKDAY_LABELS_FR[wd]} ${hh}h — ${tip_v}`;
			cells += `<rect x="${cx}" y="${cy2}" width="${CELL}" height="${CELL}" rx="3" fill="${fill}"><title>${tip}</title></rect>`;
		}
	});

	container.innerHTML =
		`<svg width="${SVG_W}" height="${SVG_H}" viewBox="0 0 ${SVG_W} ${SVG_H}" xmlns="http://www.w3.org/2000/svg">` +
		labels_x +
		labels_y +
		cells +
		`</svg>`;
}

/**
 * Renders the per-day Toggl-style ribbon: one row per day in the period, X = 0..24h,
 * each hour cell colored by the dominant category for that (day, hour) pair.
 * @param {object} aggData - aggregated rollup with rich.ribbon populated.
 */
function renderRibbon(aggData) {
	const container = document.getElementById('ribbon_container');
	const legend = document.getElementById('ribbon_legend');
	if (!container) return;

	const ribbon = (aggData && aggData.rich && aggData.rich.ribbon) || {};
	const days = Object.keys(ribbon).sort(); // ascending date
	if (days.length === 0) {
		container.innerHTML = `<div style="color:var(--text-muted);font-size:12px;padding:10px;">${_t('ui_apps.empty_activity')}</div>`;
		if (legend) legend.innerHTML = '';
		return;
	}

	const HOURS = Array.from({ length: 24 }, (_, h) => String(h).padStart(2, '0'));
	const CELL_W = 22;
	const CELL_H = 22;
	const ROW_GAP = 4;
	const LABEL_LEFT = 92;
	const LABEL_TOP = 16;
	const SVG_W = LABEL_LEFT + 24 * CELL_W + 8;
	const SVG_H = LABEL_TOP + days.length * (CELL_H + ROW_GAP) + 4;

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
		const dow = (new Date(ts).getDay() + 6) % 7;
		const dd = String(new Date(ts).getDate()).padStart(2, '0');
		const mm = String(new Date(ts).getMonth() + 1).padStart(2, '0');
		const label = `${WEEKDAY_LABELS_FR[dow]} ${dd}/${mm}`;
		rows += `<text x="${LABEL_LEFT - 8}" y="${y + CELL_H / 2 + 4}" text-anchor="end" fill="#aaa" font-size="11" font-family="system-ui">${label}</text>`;

		HOURS.forEach((hh, hi) => {
			const x = LABEL_LEFT + hi * CELL_W;
			const cellCats = ribDay[hh] || {};
			let topCat = null,
				topMs = 0,
				totalMs = 0;
			Object.entries(cellCats).forEach(([c, ms]) => {
				totalMs += ms;
				if (ms > topMs) {
					topMs = ms;
					topCat = c;
				}
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
		header +
		rows +
		`</svg>`;

	if (legend) {
		legend.innerHTML = [...cats_seen]
			.sort()
			.map((c) => {
				const col = getCategoryColor(c, 0);
				return `<span style="display:inline-flex;align-items:center;gap:5px;"><span style="width:12px;height:12px;border-radius:3px;background:${col};"></span>${escapeHtml(c)}</span>`;
			})
			.join('');
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
	const leftSet = new Set(TOP_EDGES.map((e) => e.src));
	const rightSet = new Set(TOP_EDGES.map((e) => e.dst));
	const leftApps = [...leftSet].sort((a, b) => {
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
	const ROW_H = 32;
	const PAD_TOP = 12;
	const W = 720;
	const LEFT_X = 200;
	const RIGHT_X = W - 200;
	const H = PAD_TOP * 2 + Math.max(leftApps.length, rightApps.length) * ROW_H;

	// Y for each app on each side
	const leftY = {};
	const rightY = {};
	leftApps.forEach((n, i) => (leftY[n] = PAD_TOP + i * ROW_H + ROW_H / 2));
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

	const ROW_H = 18;
	const GAP = 3;
	const LABEL_LEFT = 38;
	const HOUR_W = 720;
	const SVG_W = LABEL_LEFT + HOUR_W + 8;
	const SVG_H = 24 * (ROW_H + GAP) + 8;

	let svg = '';
	for (let h = 0; h < 24; h++) {
		const hh = String(h).padStart(2, '0');
		const slots = byHour[hh] || [];
		const totalMs = Math.min(
			slots.reduce((s, x) => s + x.ms, 0),
			60 * 60 * 1000
		);
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
	const r = (agg && agg.rich) || {};
	const t = r.time || {};
	const ty = r.typing || {};
	const sw = Object.values(agg.apps || {}).reduce(
		(s, a) => s + Object.values(a.switches || {}).reduce((s2, n) => s2 + n, 0),
		0
	);
	let prodSum = 0,
		prodWt = 0;
	Object.entries(agg.apps || {}).forEach(([n, a]) => {
		const cat = getAppCategory(n, a.category);
		prodSum += (cat.score || 0) * (a.time_ms || 0);
		prodWt += a.time_ms || 0;
	});
	const prod = prodWt > 0 ? (prodSum / (prodWt * 2)) * 100 : 0;
	return {
		focus_ms: t.focus_ms || 0,
		active_ms: t.active_ms || 0,
		chars: ty.chars || 0,
		switches: sw,
		sessions: (r.sessions && r.sessions.count) || 0,
		productivity_pct: prod
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

	const anchorTs = parseDateKey(currentSelectedDate);
	const prevAnchor = new Date(anchorTs - days * 86400000);
	const yyyy = prevAnchor.getFullYear();
	const mm = String(prevAnchor.getMonth() + 1).padStart(2, '0');
	const dd = String(prevAnchor.getDate()).padStart(2, '0');
	const prevKey = `${yyyy}-${mm}-${dd}`;

	const savedDate = currentSelectedDate;
	currentSelectedDate = prevKey;
	const prevAgg = getAggregatedData();
	currentSelectedDate = savedDate;

	const cur = summarizeAggregate(currentAgg);
	const prev = summarizeAggregate(prevAgg);

	const win = document.getElementById('compare-window');
	if (win)
		win.textContent = _t('ui_apps.cmp_window')
			.replace('{cur}', formatDisplayDate(currentSelectedDate))
			.replace('{period}', currentPeriod)
			.replace('{prev}', formatDisplayDate(prevKey));

	const rows = document.getElementById('compare-rows');
	if (!rows) return;
	const fmtDelta = (curV, prevV, fmt) => {
		const d = curV - prevV;
		const pct = prevV > 0 ? (d / prevV) * 100 : curV > 0 ? 100 : 0;
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
		card(
			_t('ui_apps.cmp_focus_time'),
			fmtDelta(cur.focus_ms, prev.focus_ms, (v) => formatDuration(v))
		) +
		card(
			_t('ui_apps.cmp_active_time'),
			fmtDelta(cur.active_ms, prev.active_ms, (v) => formatDuration(v))
		) +
		card(
			_t('ui_apps.cmp_chars'),
			fmtDelta(cur.chars, prev.chars, (v) => format_int(Math.round(v)))
		) +
		card(
			_t('ui_apps.cmp_switches'),
			fmtDelta(cur.switches, prev.switches, (v) => format_int(Math.round(v)))
		) +
		card(
			_t('ui_apps.cmp_sessions'),
			fmtDelta(cur.sessions, prev.sessions, (v) => format_int(Math.round(v)))
		) +
		card(
			_t('ui_apps.cmp_productivity'),
			fmtDelta(cur.productivity_pct, prev.productivity_pct, (v) => `${v.toFixed(0)}%`)
		);
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
		const arr = (data.session_durations || [])
			.filter((d) => d > 0)
			.slice()
			.sort((a, b) => a - b);
		if (arr.length >= 4) {
			rows.push({
				name,
				time_ms: data.time_ms || 0,
				min: arr[0],
				q1: quantile(arr, 0.25),
				med: quantile(arr, 0.5),
				q3: quantile(arr, 0.75),
				max: arr[arr.length - 1],
				count: arr.length
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
	const ROW_H = 36;
	const LABEL_LEFT = 160;
	const W = 760;
	const TRACK_W = W - LABEL_LEFT - 60;
	const SVG_H = top.length * ROW_H + 16;
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
		const x1 = xFor(r.q1),
			x2 = xFor(r.q3);
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
	tbody.innerHTML = rows
		.slice(0, 30)
		.map(
			(r) => `<tr>
		<td style="max-width:480px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="${escapeHtml(r.title)}">${escapeHtml(r.title)}</td>
		<td>${escapeHtml(r.app)}</td>
		<td style="text-align:right;">${format_int(r.c)}</td>
		<td style="text-align:right;">${formatDuration(r.ms)}</td>
	</tr>`
		)
		.join('');
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
					date: dateStr,
					app: appName,
					ms: longest,
					chars: Number(appData.session_longest_chars) || 0
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
	tbody.innerHTML = top
		.map(
			(r) => `<tr>
		<td>${formatDisplayDate(r.date)}</td>
		<td>${escapeHtml(r.app)}</td>
		<td style="text-align:right;">${formatDuration(r.ms)}</td>
		<td style="text-align:right;">${format_int(r.chars)}</td>
	</tr>`
		)
		.join('');
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
	tbody.innerHTML = days
		.map(
			(d) => `<tr>
		<td>${formatDisplayDate(d.date)}</td>
		<td style="text-align:right;">${format_int(d.chars || 0)}</td>
		<td style="text-align:right;">${formatDuration(d.time_ms || 0)}</td>
		<td style="text-align:right;">${d.switches || 0}</td>
		<td style="text-align:right;">${d.sessions || 0}</td>
	</tr>`
		)
		.join('');
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
	tbody.innerHTML = top
		.map((e) => {
			const pct = total > 0 ? (e.count / total) * 100 : 0;
			return `<tr>
			<td>${escapeHtml(e.src)}</td>
			<td>${escapeHtml(e.dst)}</td>
			<td style="text-align:right;">${e.count}</td>
			<td style="text-align:right;color:var(--text-muted);">${pct.toFixed(1)} %</td>
		</tr>`;
		})
		.join('');
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
	const dates = Object.keys(byDate).sort();
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
					{
						label: _t('ui_apps.ds_focus_h'),
						data: dates.map((d) => +(byDate[d].time_ms / 3600000).toFixed(2)),
						borderColor: '#0A84FF',
						backgroundColor: 'rgba(10,132,255,0.15)',
						tension: 0.25,
						yAxisID: 'y1',
						borderWidth: 2
					},
					{
						label: _t('ui_apps.ds_chars'),
						data: dates.map((d) => byDate[d].chars || 0),
						borderColor: '#FF9F0A',
						backgroundColor: 'rgba(255,159,10,0.10)',
						tension: 0.25,
						yAxisID: 'y2',
						borderWidth: 2
					},
					{
						label: _t('ui_apps.ds_switches'),
						data: dates.map((d) => byDate[d].switches || 0),
						borderColor: '#BF5AF2',
						backgroundColor: 'rgba(191,90,242,0.10)',
						tension: 0.25,
						yAxisID: 'y2',
						borderWidth: 2
					}
				]
			},
			options: {
				responsive: true,
				maintainAspectRatio: false,
				plugins: { legend: { labels: { color: '#ccc' } } },
				scales: {
					x: { grid: { display: false }, ticks: { color: '#888' } },
					y1: {
						position: 'left',
						beginAtZero: true,
						grid: { color: 'rgba(255,255,255,0.08)' },
						ticks: { color: '#0A84FF' }
					},
					y2: {
						position: 'right',
						beginAtZero: true,
						grid: { drawOnChartArea: false },
						ticks: { color: '#FF9F0A' }
					}
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
		const colors = ratios.map((r) => (r >= 60 ? '#30D158' : r >= 30 ? '#FFD60A' : '#FF453A'));
		if (dailyActiveRatioChart) dailyActiveRatioChart.destroy();
		dailyActiveRatioChart = new Chart(c30.getContext('2d'), {
			type: 'bar',
			data: {
				labels,
				datasets: [
					{
						label: _t('ui_apps.ds_active_ratio'),
						data: ratios,
						backgroundColor: colors,
						borderRadius: 4
					}
				]
			},
			options: {
				responsive: true,
				maintainAspectRatio: false,
				plugins: { legend: { display: false } },
				scales: {
					x: { grid: { display: false }, ticks: { color: '#888' } },
					y: {
						beginAtZero: true,
						max: 100,
						grid: { color: 'rgba(255,255,255,0.08)' },
						ticks: { color: '#ccc', callback: (v) => `${v}%` }
					}
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
			borderColor: getCategoryColor(cat, 0),
			fill: true,
			tension: 0.25,
			borderWidth: 1
		}));
		if (dailyCategoriesChart) dailyCategoriesChart.destroy();
		dailyCategoriesChart = new Chart(c31.getContext('2d'), {
			type: 'line',
			data: { labels, datasets },
			options: {
				responsive: true,
				maintainAspectRatio: false,
				plugins: { legend: { labels: { color: '#ccc' } } },
				scales: {
					x: { grid: { display: false }, ticks: { color: '#888' }, stacked: true },
					y: {
						stacked: true,
						beginAtZero: true,
						grid: { color: 'rgba(255,255,255,0.08)' },
						ticks: { color: '#ccc', callback: (v) => `${v}h` }
					}
				}
			}
		});
	}

	// #32 — first / last typed minute per day, plotted as decimal hours
	const c32 = document.getElementById('daily_bounds_chart');
	if (c32) {
		const firstHrs = dates.map((d) =>
			byDate[d].first_min != null ? +(byDate[d].first_min / 60).toFixed(2) : null
		);
		const lastHrs = dates.map((d) =>
			byDate[d].last_min != null ? +(byDate[d].last_min / 60).toFixed(2) : null
		);
		if (dailyBoundsChart) dailyBoundsChart.destroy();
		dailyBoundsChart = new Chart(c32.getContext('2d'), {
			type: 'line',
			data: {
				labels,
				datasets: [
					{
						label: _t('ui_apps.ds_first_key'),
						data: firstHrs,
						borderColor: '#0A84FF',
						backgroundColor: 'rgba(10,132,255,0.10)',
						tension: 0.25,
						borderWidth: 2,
						spanGaps: true
					},
					{
						label: _t('ui_apps.ds_last_key'),
						data: lastHrs,
						borderColor: '#FF453A',
						backgroundColor: 'rgba(255,69,58,0.10)',
						tension: 0.25,
						borderWidth: 2,
						spanGaps: true
					}
				]
			},
			options: {
				responsive: true,
				maintainAspectRatio: false,
				plugins: { legend: { labels: { color: '#ccc' } } },
				scales: {
					x: { grid: { display: false }, ticks: { color: '#888' } },
					y: {
						min: 0,
						max: 24,
						grid: { color: 'rgba(255,255,255,0.08)' },
						ticks: { color: '#ccc', stepSize: 4, callback: (v) => `${v}h` }
					}
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
		if (radialTop8Chart) {
			radialTop8Chart.destroy();
			radialTop8Chart = null;
		}
		return;
	}
	const max_time = Math.max(...top.map((a) => a.timeMs || 0)) || 1;
	const max_chars = Math.max(...top.map((a) => a.chars || 0)) || 1;
	const labels = top.map((a) => a.name);
	const time_norm = top.map((a) => Math.round(((a.timeMs || 0) / max_time) * 100));
	const chars_norm = top.map((a) => Math.round(((a.chars || 0) / max_chars) * 100));
	if (radialTop8Chart) radialTop8Chart.destroy();
	radialTop8Chart = new Chart(canvas.getContext('2d'), {
		type: 'radar',
		data: {
			labels,
			datasets: [
				{
					label: _t('ui_apps.ds_focus_time'),
					data: time_norm,
					borderColor: '#0A84FF',
					backgroundColor: 'rgba(10,132,255,0.18)',
					borderWidth: 2
				},
				{
					label: _t('ui_apps.ds_chars'),
					data: chars_norm,
					borderColor: '#FF9F0A',
					backgroundColor: 'rgba(255,159,10,0.18)',
					borderWidth: 2
				}
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: { legend: { labels: { color: '#ccc' } } },
			scales: {
				r: {
					suggestedMin: 0,
					suggestedMax: 100,
					grid: { color: 'rgba(255,255,255,0.08)' },
					angleLines: { color: 'rgba(255,255,255,0.08)' },
					pointLabels: { color: '#ddd', font: { size: 11 } },
					ticks: { color: '#888', backdropColor: 'transparent', stepSize: 25 }
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
	const data = [];
	ORDER.forEach((k) => {
		if (buckets[k] != null) {
			labels.push(`≤ ${k}`);
			data.push(buckets[k]);
		}
	});
	if (labels.length === 0) {
		if (burstHistogramChart) {
			burstHistogramChart.destroy();
			burstHistogramChart = null;
		}
		return;
	}
	if (burstHistogramChart) burstHistogramChart.destroy();
	burstHistogramChart = new Chart(canvas.getContext('2d'), {
		type: 'bar',
		data: {
			labels,
			datasets: [
				{ label: _t('ui_apps.ds_bursts'), data, backgroundColor: '#30D158', borderRadius: 4 }
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: { legend: { display: false } },
			scales: {
				y: {
					beginAtZero: true,
					grid: { color: 'rgba(255,255,255,0.1)' },
					ticks: { color: '#ccc' }
				},
				x: { grid: { display: false }, ticks: { color: '#ccc' } }
			}
		}
	});
}

/** Toggle button handler for the hour×weekday heatmap mode. */
window.setHourWeekdayMode = function (mode) {
	_hourWeekdayMode = mode === 'time' ? 'time' : 'chars';
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

const MONTHS_FR_SHORT = [
	'Jan',
	'Fév',
	'Mar',
	'Avr',
	'Mai',
	'Juin',
	'Juil',
	'Août',
	'Sep',
	'Oct',
	'Nov',
	'Déc'
];

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
			slot.chars += Number(app_data.chars) || 0;
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
		const mm = String(cursor.getMonth() + 1).padStart(2, '0');
		const dd = String(cursor.getDate()).padStart(2, '0');
		const key = `${yyyy}-${mm}-${dd}`;
		const day = per_day[key];
		const v = !day ? 0 : _calendarMode === 'time' ? day.time_ms || 0 : day.chars || 0;
		if (v > max_v) max_v = v;
		cells.push({
			key,
			date: new Date(cursor),
			weekday: (cursor.getDay() + 6) % 7, // 0=Mon … 6=Sun
			value: v,
			in_window: cursor >= start && cursor <= today
		});
		cursor.setDate(cursor.getDate() + 1);
	}

	const CELL = 11,
		GAP = 2;
	const HEAD_H = 16;
	const LABEL_W = 22;
	const cols = Math.ceil(cells.length / 7);
	const SVG_W = LABEL_W + cols * (CELL + GAP);
	const SVG_H = HEAD_H + 7 * (CELL + GAP) + 4;

	const heat = (v) => {
		if (v === 0) return '#1e1e2e';
		const t = Math.pow(v / Math.max(1, max_v), 0.45);
		if (t < 0.4)
			return `rgb(${Math.round(40 + t * 60)},${Math.round(70 + t * 110)},${Math.round(50 + t * 30)})`;
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

	const wd_labels_short = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
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
		const dt = `${c.date.getDate()}/${c.date.getMonth() + 1}/${c.date.getFullYear()}`;
		const v_txt =
			_calendarMode === 'time'
				? c.value > 0
					? formatDuration(c.value)
					: '0'
				: c.value > 0
					? `${c.value} car.`
					: '0';
		rects += `<rect x="${x}" y="${y}" width="${CELL}" height="${CELL}" rx="2" fill="${fill}"><title>${dt} — ${v_txt}</title></rect>`;
	});

	container.innerHTML =
		`<svg width="${SVG_W}" height="${SVG_H}" viewBox="0 0 ${SVG_W} ${SVG_H}" xmlns="http://www.w3.org/2000/svg">` +
		month_labels +
		wd_labels +
		rects +
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
	const cpm = [];
	const chars = [];
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
					yAxisID: 'y_chars'
				},
				{
					type: 'line',
					label: _t('ui_apps.ds_speed'),
					data: cpm,
					borderColor: 'rgba(245, 158, 11, 1)',
					backgroundColor: 'rgba(245, 158, 11, 0.15)',
					tension: 0.3,
					yAxisID: 'y_cpm',
					pointRadius: 3
				}
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			interaction: { mode: 'index', intersect: false },
			plugins: {
				legend: { labels: { color: '#ddd', font: { size: 11 } } },
				tooltip: {
					callbacks: {
						title: (items) => (items[0] ? items[0].label : '')
					}
				}
			},
			scales: {
				x: {
					ticks: { color: '#888', font: { size: 10 } },
					grid: { color: 'rgba(255,255,255,0.04)' }
				},
				y_chars: {
					type: 'linear',
					position: 'left',
					ticks: { color: '#888', font: { size: 10 } },
					grid: { color: 'rgba(255,255,255,0.04)' },
					title: {
						display: true,
						text: _t('ui_apps.axis_chars'),
						color: '#888',
						font: { size: 10 }
					}
				},
				y_cpm: {
					type: 'linear',
					position: 'right',
					ticks: { color: '#f59e0b', font: { size: 10 } },
					grid: { drawOnChartArea: false },
					title: {
						display: true,
						text: _t('ui_apps.axis_speed'),
						color: '#f59e0b',
						font: { size: 10 }
					}
				}
			}
		}
	});
}

window.setCalendarMode = function (mode) {
	_calendarMode = mode === 'time' ? 'time' : 'chars';
	const btn_t = document.getElementById('cal-mode-time');
	const btn_c = document.getElementById('cal-mode-chars');
	if (btn_t) btn_t.classList.toggle('active', _calendarMode === 'time');
	if (btn_c) btn_c.classList.toggle('active', _calendarMode === 'chars');
	renderActivityCalendar();
};

// =====================================================
// =====================================================
