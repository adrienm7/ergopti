/**
 * _shared/ui/metrics_calendar.js
 * ==============================================================================
 * MODULE: Metrics Calendar Day Identity
 * DESCRIPTION:
 * Keeps recorded Gregorian days independent of the viewing machine's timezone.
 * Local clock instants cross this boundary once; internal arithmetic stays UTC.
 * ==============================================================================
 */

const METRICS_CALENDAR_YEAR_DAYS = 365;
const METRICS_HOUR_MILLISECONDS = 60 * 60 * 1000;
const METRICS_DAY_MILLISECONDS = 24 * METRICS_HOUR_MILLISECONDS;

// Recorded dates are Gregorian day identities, not instants in the viewer's timezone.
function metricsDayOrdinal(year, month, day) {
	const date = new Date(0);
	date.setUTCFullYear(year, month, day);
	return date.getTime();
}

function metricsLocalDayOrdinal(date) {
	return metricsDayOrdinal(date.getFullYear(), date.getMonth(), date.getDate());
}

function shiftMetricsDay(ordinal, days) {
	const date = new Date(ordinal);
	date.setUTCDate(date.getUTCDate() + days);
	return date.getTime();
}

/** Moves calendar months while clamping to the target month's last valid day. */
function shiftMetricsMonth(ordinal, months) {
	const date = new Date(ordinal);
	const target = new Date(
		metricsDayOrdinal(date.getUTCFullYear(), date.getUTCMonth() + months + 1, 0)
	);
	target.setUTCDate(Math.min(date.getUTCDate(), target.getUTCDate()));
	return target.getTime();
}

function formatMetricsDateKey(ordinal) {
	const date = new Date(ordinal);
	return `${String(date.getUTCFullYear()).padStart(4, '0')}-${String(date.getUTCMonth() + 1).padStart(2, '0')}-${String(date.getUTCDate()).padStart(2, '0')}`;
}

function parseDateKey(dateStr) {
	if (!dateStr || (typeof dateStr !== 'string' && typeof dateStr !== 'number')) return NaN;
	if (/^\d+$/.test(String(dateStr))) {
		const n = Number(dateStr);
		return metricsLocalDayOrdinal(new Date(String(dateStr).length <= 10 ? n * 1000 : n));
	}
	const s = String(dateStr);
	const isoMatch = s.match(/^(\d{4})[-\/](\d{2})[-\/](\d{2})/);
	if (isoMatch)
		return metricsDayOrdinal(Number(isoMatch[1]), Number(isoMatch[2]) - 1, Number(isoMatch[3]));

	const frMatch = s.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
	if (frMatch)
		return metricsDayOrdinal(Number(frMatch[3]), Number(frMatch[2]) - 1, Number(frMatch[1]));

	const t = Date.parse(s);
	return isNaN(t) ? NaN : metricsLocalDayOrdinal(new Date(t));
}

/** Captures the existing current-and-previous-hour chart selection from one clock. */
function createMetricsHourWindow(now) {
	const previous = new Date(now.getTime() - METRICS_HOUR_MILLISECONDS);
	return Object.freeze({
		start_date: formatMetricsDateKey(metricsLocalDayOrdinal(previous)),
		start_hour: previous.getHours(),
		end_date: formatMetricsDateKey(metricsLocalDayOrdinal(now)),
		end_hour: now.getHours()
	});
}

function metricsHourWindowContains(hourWindow, dateKey, hour) {
	if (hourWindow.start_date === hourWindow.end_date)
		return (
			dateKey === hourWindow.start_date &&
			hour >= hourWindow.start_hour &&
			hour <= hourWindow.end_hour
		);
	if (dateKey === hourWindow.start_date) return hour >= hourWindow.start_hour;
	if (dateKey === hourWindow.end_date) return hour <= hourWindow.end_hour;
	return false;
}

/** Keeps the existing extra context hour at the chart's right edge. */
function metricsHourWindowBounds(hourWindow) {
	return {
		start: new Date(
			`${hourWindow.start_date}T${String(hourWindow.start_hour).padStart(2, '0')}:00:00`
		),
		end: new Date(
			`${hourWindow.end_date}T${String(Math.min(hourWindow.end_hour + 1, 23)).padStart(2, '0')}:59:59`
		)
	};
}
