// ui/metrics_typing/format.js

/**
 * ==============================================================================
 * MODULE: Formatting Helpers
 * DESCRIPTION:
 * Pure functions for number formatting, key sequence display, shortcut chip
 * rendering, trend SVG generation, and date utilities. No side effects or
 * DOM writes — all functions return HTML strings or plain values.
 *
 * FEATURES & RATIONALE:
 * 1. Universal Number Formatting: Space-separated thousands, M/Md abbreviation,
 *    hover tooltip showing exact value for abbreviated numbers.
 * 2. Modifier Colors: Each modifier key (Cmd/Ctrl/Option/Shift/Fn) gets a
 *    distinct color to aid at-a-glance pattern recognition.
 * 3. Control Key Red Styling: Escape, arrows, Backspace, Fn keys are rendered
 *    in red to visually separate them from printable characters.
 * ==============================================================================
 */


// ===================================
// ===================================
// ======= 1/ Date & Text Utils =======
// ===================================
// ===================================

/**
 * Returns the current local date formatted as YYYY-MM-DD.
 * @returns {string} The ISO date string for today.
 */
function get_local_date_string() {
	const d    = new Date();
	const yyyy = d.getFullYear();
	const mm   = String(d.getMonth() + 1).padStart(2, "0");
	const dd   = String(d.getDate()).padStart(2, "0");
	return `${yyyy}-${mm}-${dd}`;
}

/**
 * Formats a Date object as YYYY-MM-DD.
 * @param {Date} d - The date to format.
 * @returns {string} The ISO date string.
 */
function format_date_iso(d) {
	const yyyy = d.getFullYear();
	const mm   = String(d.getMonth() + 1).padStart(2, "0");
	const dd   = String(d.getDate()).padStart(2, "0");
	return `${yyyy}-${mm}-${dd}`;
}

/**
 * Escapes HTML special characters to prevent XSS.
 * @param {string} str - The raw string to escape.
 * @returns {string} The escaped string safe for HTML insertion.
 */
function escape_html(str) {
	if (!str) return "";
	return str
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;");
}


// ======================================
// ======================================
// ======= 2/ Number Formatting =======
// ======================================
// ======================================

/**
 * Formats a number with French locale conventions (plain text, no HTML).
 * Identical logic to format_number() but returns a plain string safe for use
 * in Chart.js tooltip callbacks, which render text verbatim and must not
 * receive HTML tags.
 * @param {number|string} num - The number to format.
 * @returns {string} Plain-text formatted number without any HTML markup.
 */
function format_number_plain(num) {
	if (num === null || num === undefined || isNaN(num)) return "0";
	const parsed  = typeof num === "string" ? parseFloat(num) : num;
	const is_neg  = parsed < 0;
	const abs_val = Math.abs(parsed);
	const prefix  = is_neg ? "-" : "";

	if (abs_val >= 1_000_000_000) {
		return prefix + (abs_val / 1_000_000_000).toFixed(1).replace(".0", "").replace(".", ",") + "\u00A0Md";
	}
	if (abs_val >= 1_000_000) {
		return prefix + (abs_val / 1_000_000).toFixed(1).replace(".0", "").replace(".", ",") + "\u00A0M";
	}

	const str   = parsed.toString();
	const parts = str.split(".");
	parts[0]    = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, "\u00A0");
	return prefix + parts.join(",");
}

/**
 * Wraps an abbreviated display value in a tooltip showing the exact number.
 * @param {string} display - The abbreviated text (e.g. "1,2 M").
 * @param {number} exact   - The exact numeric value.
 * @returns {string} HTML span with tooltip.
 */
function wrap_exact_tooltip(display, exact) {
	// Use toLocaleString with 'fr-FR' for native French number formatting in the tooltip
	const exact_str = Number(Math.round(exact)).toLocaleString("fr-FR");
	return `<span class="num-tooltip" title="${exact_str}">${display}</span>`;
}

/**
 * Formats a number with French locale conventions: space-separated thousands,
 * comma decimal point, M/Md abbreviation for large values, exact-value tooltip.
 * @param {number|string} num - The number to format.
 * @returns {string} HTML string with formatted number (may contain a tooltip span).
 */
function format_number(num) {
	if (num === null || num === undefined || isNaN(num)) return "0";
	const parsed     = typeof num === "string" ? parseFloat(num) : num;
	const is_neg     = parsed < 0;
	const abs_val    = Math.abs(parsed);
	const prefix     = is_neg ? "-" : "";

	if (abs_val >= 1_000_000_000) {
		const abbr = (abs_val / 1_000_000_000).toFixed(1).replace(".0", "").replace(".", ",") + "\u00A0Md";
		return wrap_exact_tooltip(prefix + abbr, parsed);
	}
	if (abs_val >= 1_000_000) {
		const abbr = (abs_val / 1_000_000).toFixed(1).replace(".0", "").replace(".", ",") + "\u00A0M";
		return wrap_exact_tooltip(prefix + abbr, parsed);
	}

	// Apply space as thousands separator
	const str   = parsed.toString();
	const parts = str.split(".");
	parts[0]    = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, "\u00A0");
	const formatted = parts.join(",");

	// Tooltip only when a thousands separator was actually inserted
	if (abs_val >= 1000) {
		return wrap_exact_tooltip(prefix + formatted, parsed);
	}
	return prefix + formatted;
}

/**
 * Chart.js tooltip title callback: formats timestamps as "lundi 14/04/2026".
 * @param {Array} context - Chart.js tooltip context array.
 * @returns {string} The French-formatted date string.
 */
const tooltipTitleCallback = (context) => {
	const days    = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"];
	const d       = new Date(context[0].parsed.x);
	const dayName = days[d.getDay()];
	const dd      = String(d.getDate()).padStart(2, "0");
	const mm      = String(d.getMonth() + 1).padStart(2, "0");
	const yyyy    = d.getFullYear();
	return `${dayName} ${dd}/${mm}/${yyyy}`;
};


// ============================================
// ============================================
// ======= 3/ Key Sequence Display =======
// ============================================
// ============================================

/**
 * Converts a raw key sequence string to display HTML. Whitespace characters
 * are replaced with visual badges; [BS] becomes a red backspace icon; NBSP
 * and NNBSP get red control-key styling.
 * @param {string} str - The raw key sequence string.
 * @returns {string} HTML string ready for innerHTML.
 */
function format_display_key(str) {
	let s = escape_html(str);
	// Sentinel substitution prevents partial string replacement conflicts
	s = s.replace(/ /g,       "[[SPACE]]");
	s = s.replace(/\u00A0/g,  "[[NBSP]]");
	s = s.replace(/\u202F/g,  "[[NNBSP]]");
	s = s.replace(/\n/g,      "[[NEWLINE]]");
	s = s.replace(/\[BS\]/gi, "[[BACKSPACE]]");

	s = s.replace(/\[\[SPACE\]\]/g,     "<span class=\"shortcut-chip shortcut-key-control\">Space</span>");
	s = s.replace(/\[\[NBSP\]\]/g,      "<span class=\"key-control space-badge\">NBSP</span>");
	s = s.replace(/\[\[NNBSP\]\]/g,     "<span class=\"key-control space-badge\">NNBSP</span>");
	s = s.replace(/\[\[NEWLINE\]\]/g,   "<span style=\"color:var(--text-muted);\">&#x21B5;</span>");
	s = s.replace(/\[\[BACKSPACE\]\]/g, "<span class=\"shortcut-chip shortcut-key-control\">BackSpace</span>");
	return s;
}

/**
 * Renders a key sequence as a row of individual chips, one per token.
 * Used when the sequence contains special markers ([BS], [ESC], [LEFT]…) or
 * non-breaking spaces, which would otherwise produce ugly nested chips.
 * Regular sequences without special chars still use a single .mono-space chip.
 * @param {string} str - The raw sequence key string.
 * @returns {string} HTML string of adjacent chip spans.
 */
function format_seq_chips(str) {
	// Split on bracketed markers (e.g. "[BS]", "[LEFT]") preserving the delimiters
	const parts = str.split(/(\[[^\]]+\])/i).filter(p => p.length > 0);

	return parts.map(part => {
		const lower = part.toLowerCase();

		// Bracketed special marker → look up in CONTROL_KEY_LABELS for symbol
		if (/^\[[^\]]+\]$/.test(part)) {
			const sym = CONTROL_KEY_SYMBOLS[lower] ?? lower.toUpperCase();
			return `<span class="shortcut-chip shortcut-key-control">${escape_html(sym)}</span>`;
		}

		// Regular character run — split grapheme by grapheme
		return Array.from(part).map(ch => {
			if (ch === "\u00A0") return `<span class="shortcut-chip shortcut-key-control">NBSP</span>`;
			if (ch === "\u202F") return `<span class="shortcut-chip shortcut-key-control">NNBSP</span>`;
			if (ch === " ")      return `<span class="shortcut-chip shortcut-key-control">Space</span>`;
			if (ch === "\n")     return `<span class="mono-space seq-space">&#x21B5;</span>`;
			return `<span class="mono-space">${escape_html(ch)}</span>`;
		}).join("");
	}).join("");
}

/**
 * Returns the parts of a shortcut string sorted in canonical modifier order:
 * Ctrl → Cmd → Option → Shift → Fn, then the non-modifier key last.
 * @param {string[]} parts - Unsorted key parts.
 * @returns {string[]} Sorted parts.
 */
function sort_modifier_parts(parts) {
	const mod_idx = (p) => {
		const i = MODIFIER_ORDER.indexOf(p.toLowerCase());
		return i >= 0 ? i : 999;
	};
	const mods = parts.filter(p =>  MODIFIER_ORDER.includes(p.toLowerCase())).sort((a, b) => mod_idx(a) - mod_idx(b));
	const keys = parts.filter(p => !MODIFIER_ORDER.includes(p.toLowerCase()));
	return [...mods, ...keys];
}

/**
 * Converts a shortcut string (e.g. "cmd+shift+c") into colored chip HTML.
 * Each modifier gets its distinct color; control/special keys are rendered
 * in red; regular keys use the monospace style.
 * @param {string} str - The raw shortcut string.
 * @returns {string} HTML string with styled chip spans.
 */
function format_shortcut_key(str) {
	if (!str) return "";

	const pretty_map = {
		cmd: "⌘", ctrl: "⌃", alt: "⌥", shift: "⇧", fn: "fn",
		left: "←", right: "→", up: "↑", down: "↓",
		enter: "⏎", tab: "⇥", backspace: "⌫",
		escape: "⎋", space: "␣", delete: "⌦",
		home: "⇱", end: "⇲", pageup: "⇞", pagedown: "⇟",
	};

	let parts = String(str).split("+").map(p => p.trim()).filter(p => p.length > 0);
	if (parts.length === 0) return "";

	parts = sort_modifier_parts(parts);

	return parts.map((part, idx) => {
		const lower    = part.toLowerCase();
		const is_mod   = MODIFIER_ORDER.includes(lower);
		const is_ctrl  = !is_mod && CONTROL_KEY_LABELS.has(lower);
		const cfg      = is_mod ? MODIFIER_CONFIG[lower] : null;

		let label = pretty_map[lower] ?? part;
		if (!pretty_map[lower] && part.length === 1) label = part.toUpperCase();

		let cls = "shortcut-chip";
		if (is_mod && cfg) {
			cls += " " + cfg.color_class;
		} else if (is_ctrl) {
			// Red chip identical in structure to modifier chips for visual consistency
			cls += " shortcut-key-control";
		} else {
			cls += " shortcut-key";
		}

		const plus = idx < parts.length - 1 ? "<span class=\"shortcut-plus\">+</span>" : "";
		return `<span class="${cls}">${escape_html(label)}</span>${plus}`;
	}).join("");
}


// ==================================
// ==================================
// ======= 4/ Trend SVG Icons =======
// ==================================
// ==================================

/**
 * Returns an SVG trend icon (up/down/stable) by running a linear regression
 * on the provided data points.
 * @param {number[]} valid_points - Array of numeric data points.
 * @returns {string} SVG HTML string.
 */
function get_trend_svg(valid_points) {
	const stable_svg = "<svg class=\"trend-svg stable\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><line x1=\"5\" y1=\"12\" x2=\"19\" y2=\"12\"></line><polyline points=\"12 5 19 12 12 19\"></polyline></svg>";
	const up_svg     = "<svg class=\"trend-svg up\"     viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><line x1=\"7\" y1=\"17\" x2=\"17\" y2=\"7\"></line><polyline points=\"7 7 17 7 17 17\"></polyline></svg>";
	const down_svg   = "<svg class=\"trend-svg down\"   viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><line x1=\"7\" y1=\"7\" x2=\"17\" y2=\"17\"></line><polyline points=\"17 7 17 17 7 17\"></polyline></svg>";

	if (!valid_points || valid_points.length < 2) return stable_svg;

	const n = valid_points.length;
	let sum_x = 0, sum_y = 0, sum_xy = 0, sum_xx = 0;
	for (let i = 0; i < n; i++) {
		sum_x  += i;
		sum_y  += valid_points[i];
		sum_xy += i * valid_points[i];
		sum_xx += i * i;
	}

	const denom     = n * sum_xx - sum_x * sum_x;
	if (denom === 0) return stable_svg;
	const slope     = (n * sum_xy - sum_x * sum_y) / denom;
	const threshold = Math.max(...valid_points) * 0.01;

	if (slope >  threshold) return up_svg;
	if (slope < -threshold) return down_svg;
	return stable_svg;
}
