// _shared/ui/action_picker/script.js

/**
 * ==============================================================================
 * MODULE: Action Picker UI Script
 * DESCRIPTION:
 * Renders a searchable, categorised list of actions and reports the chosen one
 * back to the native host. The host (AHK WebView2 or macOS WKWebView) pushes the
 * catalogue + current selection via init(); the page posts {action:'confirm',id}
 * on a pick and {action:'cancel'} on dismiss. The page keeps no truth of its own
 * beyond the transient search/highlight state.
 *
 * UX: type to filter, ↑/↓ to move the highlight, Enter to confirm, Esc to cancel,
 * click a row to pick it immediately. The currently-assigned action carries a
 * check mark so the live selection is always visible.
 * ==============================================================================
 */

// ============================================================
// 1/ Host-agnostic bridge
// ============================================================

// Windows WebView2 takes a JSON string over window.chrome.webview; macOS
// WKWebView takes a structured object over the action_picker_bridge handler.
function post(payload) {
	if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function') {
		window.chrome.webview.postMessage(JSON.stringify(payload));
		return;
	}
	if (
		window.webkit &&
		window.webkit.messageHandlers &&
		window.webkit.messageHandlers.action_picker_bridge
	) {
		window.webkit.messageHandlers.action_picker_bridge.postMessage(payload);
	}
}

function doConfirm(id) {
	if (id === '' || id === undefined || id === null) return;
	post({ action: 'confirm', id: id });
}

function doCancel() {
	post({ action: 'cancel' });
}

// ============================================================
// 2/ State
// ============================================================

// Full ordered entry list: [native?, none, ...actions]. Each entry is
// { id, label, category, special }.
let entries = [];

// The visible (post-filter) item rows in display order: { id, el }.
let visible = [];
let activeIndex = 0;

// The currently-assigned action id (for the persistent check mark).
let currentId = 'none';

let strings = { noResults: 'No matching action' };

function el(id) {
	return document.getElementById(id);
}

// ============================================================
// 3/ Init (host -> page)
// ============================================================

/**
 * Initialise the picker with the host-provided catalogue.
 * @param {Object} data - { title, label, current, allowNative, nativeLabel,
 *   noneLabel, searchPlaceholder, noResults, cancelLabel, actions:[{id,label,category}] }.
 */
function init(data) {
	data = data || {};
	strings.noResults = data.noResults || 'No matching action';

	el('title').textContent = data.title || '';
	el('subtitle').textContent = data.label || '';
	el('search').placeholder = data.searchPlaceholder || '';
	el('btn-cancel').textContent = data.cancelLabel || 'Cancel';

	// The host sends "" for the synthetic "native" / unset selection.
	currentId = data.current;
	if (currentId === '' || currentId === undefined || currentId === null) {
		currentId = data.allowNative ? '__native__' : 'none';
	}

	entries = [];
	if (data.allowNative) {
		entries.push({ id: '__native__', label: data.nativeLabel || '', category: '', special: true });
	}
	entries.push({ id: 'none', label: data.noneLabel || '', category: '', special: true });
	(data.actions || []).forEach(function (a) {
		entries.push({ id: a.id, label: a.label, category: a.category || '', special: false });
	});

	render('');
	focusSearch();
}

function focusSearch() {
	const s = el('search');
	if (!s) return;
	s.focus();
	// A couple of delayed retries — WKWebView occasionally drops the first focus.
	setTimeout(function () { s.focus(); }, 60);
}

// ============================================================
// 4/ Rendering
// ============================================================

function render(query) {
	const list = el('list');
	const empty = el('empty');
	list.innerHTML = '';
	visible = [];

	const q = (query || '').trim().toLowerCase();
	const matched = entries.filter(function (e) {
		return q === '' || (e.label || '').toLowerCase().indexOf(q) !== -1;
	});

	// Separator between the pinned special rows and the real actions.
	let specialsRendered = false;
	let actionsStarted = false;
	let lastCat = null;

	matched.forEach(function (e) {
		if (!e.special && !actionsStarted) {
			actionsStarted = true;
			if (specialsRendered) {
				const sep = document.createElement('div');
				sep.className = 'sep';
				list.appendChild(sep);
			}
		}
		if (e.special) specialsRendered = true;

		if (!e.special && e.category && e.category !== lastCat) {
			lastCat = e.category;
			const h = document.createElement('div');
			h.className = 'cat-header';
			h.textContent = e.category;
			list.appendChild(h);
		}

		const row = document.createElement('div');
		row.className = 'row' + (e.special ? ' special' : '') + (e.id === currentId ? ' current' : '');
		row.dataset.id = e.id;

		const tick = document.createElement('span');
		tick.className = 'row-tick';
		tick.textContent = '✓';
		const label = document.createElement('span');
		label.className = 'row-label';
		label.textContent = e.label;
		row.appendChild(tick);
		row.appendChild(label);

		const idx = visible.length;
		row.addEventListener('click', function () { doConfirm(e.id); });
		row.addEventListener('mousemove', function () { setActive(idx); });
		list.appendChild(row);
		visible.push({ id: e.id, el: row });
	});

	empty.hidden = visible.length > 0;
	if (!empty.hidden) empty.textContent = strings.noResults;
	el('count').textContent = visible.length ? String(visible.length) : '';

	// Highlight the current selection if it survived the filter, else the first row.
	let start = 0;
	for (let i = 0; i < visible.length; i++) {
		if (visible[i].id === currentId) { start = i; break; }
	}
	setActive(start, true);
}

function setActive(idx, instant) {
	if (idx < 0 || idx >= visible.length) return;
	if (visible[activeIndex] && visible[activeIndex].el) {
		visible[activeIndex].el.classList.remove('active');
	}
	activeIndex = idx;
	const row = visible[activeIndex].el;
	row.classList.add('active');
	row.scrollIntoView({ block: 'nearest', behavior: instant ? 'auto' : 'auto' });
}

// ============================================================
// 5/ Events
// ============================================================

document.addEventListener('DOMContentLoaded', function () {
	el('search').addEventListener('input', function (e) {
		render(e.target.value);
	});

	document.addEventListener('keydown', function (e) {
		if (e.key === 'ArrowDown') {
			e.preventDefault();
			if (visible.length) setActive((activeIndex + 1) % visible.length);
		} else if (e.key === 'ArrowUp') {
			e.preventDefault();
			if (visible.length) setActive((activeIndex - 1 + visible.length) % visible.length);
		} else if (e.key === 'Enter') {
			e.preventDefault();
			if (visible.length && visible[activeIndex]) doConfirm(visible[activeIndex].id);
		} else if (e.key === 'Escape') {
			e.preventDefault();
			doCancel();
		}
	});

	// Best-effort ready ping; the host also pushes init() on navigation-complete.
	post({ action: 'ready' });
});
