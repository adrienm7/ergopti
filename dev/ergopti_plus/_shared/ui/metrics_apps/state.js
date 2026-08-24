// _shared/ui/metrics_apps/state.js
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
				focus_ms: 0, // Σ app_time_ms across non-system apps
				active_ms: 0, // Σ time (truly typing inter-key gaps)
				think_ms: 0, // Σ think_time
				passive_locked_ms: 0,
				passive_sleep_ms: 0,
				passive_count: 0,
				// Keep-awake duration aggregated from _system.awake_ms across days.
				// Subtracted from focus_ms when the "compter le keep-awake" toggle is OFF.
				awake_ms: 0
			},
			system: {
				wifi_changes: 0,
				space_switches: 0,
				battery_sum: 0,
				battery_count: 0,
				battery_min: null,
				battery_max: null,
				audio_muted_ms: 0,
				night_wake_count: 0
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
				char_letter: 0,
				char_digit: 0,
				char_punct: 0,
				char_space: 0,
				char_other: 0
			},
			sessions: {
				count: 0,
				total_active_ms: 0,
				longest_ms: 0,
				longest_chars: 0,
				longest_app: null
			},
			bursts: {
				count: 0,
				max_cpm: 0,
				max_chars: 0,
				length_buckets: {} // bucket_label → count, rolled up across apps
			},
			ergonomics: {
				same_finger_streak_max: 0,
				same_hand_streak_max: 0
			},
			focus_latency: { sum_ms: 0, count: 0 },
			// First / last typed minute observed across all apps in the range,
			// stored as { date, hh, mm } so we can format both the time and
			// the absolute moment for amplitude computation.
			day_first: null,
			day_last: null,
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
			ribbon: {}
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
			const dow = (new Date(d.ts).getDay() + 6) % 7;
			if (!currentWeekdayFilter.has(dow)) return false;
		}
		return true;
	});

	// Date range bookkeeping for the rich rollup
	if (validDates.length > 0) {
		const sorted = [...validDates].sort((a, b) => a.ts - b.ts);
		result.rich.date_range.start = sorted[0].key;
		result.rich.date_range.end = sorted[sorted.length - 1].key;
		result.rich.date_range.days = sorted.length;
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
			result.rich.time.passive_sleep_ms += sysEntry.sleep_ms || 0;
			result.rich.time.passive_count += sysEntry.passive_count || 0;
			result.rich.time.awake_ms += sysEntry.awake_ms || 0;

			// System counters (#13–19)
			const rsys = result.rich.system;
			rsys.wifi_changes += sysEntry.wifi_changes || 0;
			rsys.space_switches += sysEntry.space_switches || 0;
			rsys.audio_muted_ms += sysEntry.audio_muted_ms || 0;
			rsys.night_wake_count += sysEntry.night_wake_count || 0;
			if (sysEntry.battery_count) {
				rsys.battery_sum += sysEntry.battery_sum || 0;
				rsys.battery_count += sysEntry.battery_count || 0;
				if (
					sysEntry.battery_min != null &&
					(rsys.battery_min == null || sysEntry.battery_min < rsys.battery_min)
				)
					rsys.battery_min = sysEntry.battery_min;
				if (
					sysEntry.battery_max != null &&
					(rsys.battery_max == null || sysEntry.battery_max > rsys.battery_max)
				)
					rsys.battery_max = sysEntry.battery_max;
			}
		}

		// Day-level rollup row
		const byDate =
			result.rich.by_date[d.key] ||
			(result.rich.by_date[d.key] = {
				time_ms: 0,
				active_ms: 0,
				chars: 0,
				switches: 0,
				sessions: 0,
				passive_ms: 0,
				by_category: {},
				first_min: null,
				last_min: null
			});
		if (sysEntry) {
			byDate.passive_ms += (sysEntry.locked_ms || 0) + (sysEntry.sleep_ms || 0);
		}

		// Weekday: parseDateKey returns a JS-compatible ts; convert to Mon=0..Sun=6
		const dow = (new Date(d.ts).getDay() + 6) % 7;
		const byWk =
			result.rich.by_weekday[dow] || (result.rich.by_weekday[dow] = { time_ms: 0, chars: 0 });

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
			const _appMsRaw = Number(appData.app_time_ms) || 0;
			const _appAwake = Number(appData.awake_ms) || 0;
			const _appMsEff = currentCountAwake ? _appMsRaw : Math.max(0, _appMsRaw - _appAwake);
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
			appOut.chars = (appOut.chars || 0) + (Number(appData.chars) || 0);
			appOut.hs_chars = (appOut.hs_chars || 0) + (Number(appData.hs_chars) || 0);
			appOut.llm_chars = (appOut.llm_chars || 0) + (Number(appData.llm_chars) || 0);
			appOut.bs_total = (appOut.bs_total || 0) + (Number(appData.bs_total) || 0);
			appOut.session_count =
				(appOut.session_count || 0) + (Number(appData.session_count_total) || 0);
			appOut.session_total_active_ms =
				(appOut.session_total_active_ms || 0) + (Number(appData.session_total_active_ms) || 0);
			if ((Number(appData.session_longest_ms) || 0) > (appOut.session_longest_ms || 0)) {
				appOut.session_longest_ms = Number(appData.session_longest_ms) || 0;
				appOut.session_longest_chars = Number(appData.session_longest_chars) || 0;
			}
			if ((Number(appData.burst_max_cpm) || 0) > (appOut.burst_max_cpm || 0)) {
				appOut.burst_max_cpm = Number(appData.burst_max_cpm) || 0;
			}
			appOut.focus_latency_sum_ms =
				(appOut.focus_latency_sum_ms || 0) + (Number(appData.focus_to_first_key_sum_ms) || 0);
			appOut.focus_latency_count =
				(appOut.focus_latency_count || 0) + (Number(appData.focus_to_first_key_count) || 0);
			appOut.recovery_sum_ms =
				(appOut.recovery_sum_ms || 0) + (Number(appData.recovery_time_sum_ms) || 0);
			appOut.recovery_count =
				(appOut.recovery_count || 0) + (Number(appData.recovery_time_count) || 0);
			appOut.cascade_count =
				(appOut.cascade_count || 0) + (Number(appData.cascade_count_total) || 0);
			appOut.auto_repeat_count =
				(appOut.auto_repeat_count || 0) + (Number(appData.auto_repeat_count) || 0);
			// #51 same-finger streak max per app
			if ((Number(appData.same_finger_streak_max) || 0) > (appOut.same_finger_streak_max || 0)) {
				appOut.same_finger_streak_max = Number(appData.same_finger_streak_max);
			}
			// #52 modifier hold mean — sum across kc_hold for this app
			if (appData.kc_hold) {
				appOut.kc_hold_sum_ms = appOut.kc_hold_sum_ms || 0;
				appOut.kc_hold_count = appOut.kc_hold_count || 0;
				Object.values(appData.kc_hold).forEach((h) => {
					appOut.kc_hold_sum_ms += h.s || 0;
					appOut.kc_hold_count += h.n || 0;
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
					slot.c += w.c || 0;
					slot.ms += w.ms || 0;
				});
			}

			// Manifest-wide rollup — use the keep-awake-corrected app time so
			// the headline focus_ms reflects the toggle.
			const r = result.rich;
			r.time.focus_ms += _appMsEff;
			r.time.active_ms += Number(appData.time) || 0;
			r.time.think_ms += Number(appData.think_time) || 0;
			r.typing.chars += Number(appData.chars) || 0;
			r.typing.hs_chars += Number(appData.hs_chars) || 0;
			r.typing.llm_chars += Number(appData.llm_chars) || 0;
			r.typing.hs_triggers += Number(appData.hs_triggers) || 0;
			r.typing.llm_triggers += Number(appData.llm_triggers) || 0;
			r.typing.bs_total += Number(appData.bs_total) || 0;
			r.typing.cascade_count_total += Number(appData.cascade_count_total) || 0;
			r.typing.recovery_time_sum_ms += Number(appData.recovery_time_sum_ms) || 0;
			r.typing.recovery_time_count += Number(appData.recovery_time_count) || 0;
			r.typing.auto_repeat_count += Number(appData.auto_repeat_count) || 0;
			r.typing.char_letter += Number(appData.char_letter) || 0;
			r.typing.char_digit += Number(appData.char_digit) || 0;
			r.typing.char_punct += Number(appData.char_punct) || 0;
			r.typing.char_space += Number(appData.char_space) || 0;
			r.typing.char_other += Number(appData.char_other) || 0;
			if ((Number(appData.cascade_max_len) || 0) > r.typing.cascade_max_len) {
				r.typing.cascade_max_len = Number(appData.cascade_max_len);
			}
			r.sessions.count += Number(appData.session_count_total) || 0;
			r.sessions.total_active_ms += Number(appData.session_total_active_ms) || 0;
			if ((Number(appData.session_longest_ms) || 0) > r.sessions.longest_ms) {
				r.sessions.longest_ms = Number(appData.session_longest_ms);
				r.sessions.longest_chars = Number(appData.session_longest_chars) || 0;
				r.sessions.longest_app = appName;
			}
			if ((Number(appData.session_longest_ms) || 0) >= LONG_SESSION_THRESHOLD_MS) {
				r.long_sessions += 1;
			}
			r.bursts.count += Number(appData.burst_count_total) || 0;
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
			r.focus_latency.count += Number(appData.focus_to_first_key_count) || 0;

			// Earliest / latest typed minute on the period
			const ftm = appData.first_typed_min;
			const ltm = appData.last_typed_min;
			if (typeof ftm === 'string' && /^\d{2}:\d{2}$/.test(ftm)) {
				const candidate = { date: d.key, hh: +ftm.slice(0, 2), mm: +ftm.slice(3, 5), str: ftm };
				if (
					!r.day_first ||
					d.key < r.day_first.date ||
					(d.key === r.day_first.date &&
						candidate.hh * 60 + candidate.mm < r.day_first.hh * 60 + r.day_first.mm)
				) {
					r.day_first = candidate;
				}
			}
			if (typeof ltm === 'string' && /^\d{2}:\d{2}$/.test(ltm)) {
				const candidate = { date: d.key, hh: +ltm.slice(0, 2), mm: +ltm.slice(3, 5), str: ltm };
				if (
					!r.day_last ||
					d.key > r.day_last.date ||
					(d.key === r.day_last.date &&
						candidate.hh * 60 + candidate.mm > r.day_last.hh * 60 + r.day_last.mm)
				) {
					r.day_last = candidate;
				}
			}

			// kc_hold roll-up
			if (appData.kc_hold) {
				Object.entries(appData.kc_hold).forEach(([kc, h]) => {
					const t = r.kc_hold[kc] || (r.kc_hold[kc] = { s: 0, n: 0, m: 0, tap: 0, hold: 0 });
					t.s += h.s || 0;
					t.n += h.n || 0;
					t.tap += h.tap || 0;
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
					const slot =
						r.by_hour[hour] || (r.by_hour[hour] = { time_ms: 0, chars: 0, score_x_ms: 0 });
					slot.time_ms += hMs;
					slot.chars += hData.c || 0;
					slot.score_x_ms = (slot.score_x_ms || 0) + (_hourCat.score || 0) * hMs;
					// Ribbon (#25) per-day per-hour per-category accumulation
					const ribDay = r.ribbon[d.key] || (r.ribbon[d.key] = {});
					const ribHour = ribDay[hour] || (ribDay[hour] = {});
					const ribCat = _hourCat.type || 'Général';
					ribHour[ribCat] = (ribHour[ribCat] || 0) + hMs;
					// Hour × weekday cell — same dow as the day this app/day row
					// belongs to. Drives the heatmap.
					const cell_key = `${hour}|${dow}`;
					const cell =
						r.hour_weekday[cell_key] || (r.hour_weekday[cell_key] = { time_ms: 0, chars: 0 });
					cell.time_ms += hMs;
					cell.chars += hData.c || 0;
				});
			}

			// Day rollup
			byDate.time_ms += Number(appData.app_time_ms) || 0;
			byDate.active_ms += Number(appData.time) || 0;
			byDate.chars += Number(appData.chars) || 0;
			byDate.sessions += Number(appData.session_count_total) || 0;
			if (appData.switches_to) {
				Object.values(appData.switches_to).forEach((n) => (byDate.switches += n || 0));
			}
			byWk.time_ms += Number(appData.app_time_ms) || 0;
			byWk.chars += Number(appData.chars) || 0;

			// Category rollup uses the resolved category (user override aware)
			const catData = getAppCategory(appName, appData.category);
			const cat = catData.type || 'Général';
			const catSlot =
				r.by_category[cat] || (r.by_category[cat] = { time_ms: 0, chars: 0, active_ms: 0 });
			const appMs = Number(appData.app_time_ms) || 0;
			byDate.by_category[cat] = (byDate.by_category[cat] || 0) + appMs;
			// First / last typed minute on this day across apps
			const _ftmDay = appData.first_typed_min;
			const _ltmDay = appData.last_typed_min;
			if (typeof _ftmDay === 'string' && /^\d{2}:\d{2}$/.test(_ftmDay)) {
				const _m = +_ftmDay.slice(0, 2) * 60 + +_ftmDay.slice(3, 5);
				if (byDate.first_min == null || _m < byDate.first_min) byDate.first_min = _m;
			}
			if (typeof _ltmDay === 'string' && /^\d{2}:\d{2}$/.test(_ltmDay)) {
				const _m = +_ltmDay.slice(0, 2) * 60 + +_ltmDay.slice(3, 5);
				if (byDate.last_min == null || _m > byDate.last_min) byDate.last_min = _m;
			}
			catSlot.time_ms += appMs;
			catSlot.chars += Number(appData.chars) || 0;
			catSlot.active_ms += Number(appData.time) || 0;

			// #20 productivity split (sign of score)
			if ((catData.score || 0) > 0) r.prod_split.positive_ms += appMs;
			else if ((catData.score || 0) < 0) r.prod_split.negative_ms += appMs;
			else r.prod_split.neutral_ms += appMs;

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
