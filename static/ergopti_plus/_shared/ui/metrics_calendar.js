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
