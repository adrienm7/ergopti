// _shared/ui/action_picker/script.js

/**
 * ==============================================================================
 * MODULE: Action Picker UI Script
 * DESCRIPTION:
 * Renders a searchable, foldable, multi-level action list and reports the chosen
 * action back to the native host. The host (AHK WebView2 or macOS WKWebView)
 * pushes the catalogue via init() as an ordered `items` list of headings
 * ({type:"heading",level,text}) and actions ({type:"action",id,label}); the page
 * posts {action:'confirm',id} on a pick and {action:'cancel'} on dismiss.
 *
 * UX: type to filter, ↑/↓ to move the highlight, Enter to confirm, Esc to cancel,
 * click a row to pick it. Headings render as h1/h2/h3… by their level, fold their
 * descendants on click, and a table-of-contents button jumps to any heading.
 * ==============================================================================
 */

// ============================================================
// 1/ Host-agnostic bridge
// ============================================================

var post = makeHostBridge('action_picker_bridge');

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

// Ordered entries: specials first ({kind:'action',special:true}), then the
// host's items as {kind:'heading',level,text} / {kind:'action',id,label}.
let entries = [];

// Heading entry-indices the user has collapsed (folded). Survives re-render.
const collapsed = new Set();

// Visible (rendered + focusable) action rows in display order: {id, el}.
let visible = [];
let activeIndex = 0;

let currentId = 'none';
let strings = { noResults: 'No matching action' };

function el(id) {
	return document.getElementById(id);
}

// ============================================================
// 3/ Init (host -> page)
// ============================================================

function init(data) {
	data = data || {};
	strings.noResults = data.noResults || 'No matching action';

	el('title').textContent = data.title || '';
	el('subtitle').textContent = data.label || '';
	el('search').placeholder = data.searchPlaceholder || '';
	el('btn-cancel').textContent = data.cancelLabel || 'Cancel';

	currentId = data.current;
	if (currentId === '' || currentId === undefined || currentId === null) {
		currentId = data.allowNative ? '__native__' : 'none';
	}

	entries = [];
	if (data.allowNative) {
		entries.push({ kind: 'action', id: '__native__', label: data.nativeLabel || '', special: true });
	}
	entries.push({ kind: 'action', id: 'none', label: data.noneLabel || '', special: true });
	(data.items || []).forEach(function (it) {
		if (it.type === 'heading') {
			entries.push({ kind: 'heading', level: it.level || 1, text: it.text || '' });
		} else if (it.type === 'action') {
			entries.push({ kind: 'action', id: it.id, label: it.label, special: false });
		}
	});

	collapsed.clear();
	render();
	focusSearch();
}

function focusSearch() {
	const s = el('search');
	if (!s) return;
	s.focus();
	setTimeout(function () { s.focus(); }, 60);
}

// ============================================================
// 4/ Heading / ancestor helpers
// ============================================================

// Indices (into `entries`) of the heading ancestors enclosing entry `i`: the
// chain of headings with strictly increasing level that contain it.
function ancestorsOf(i) {
	const stack = [];
	for (let j = 0; j < i; j++) {
		const e = entries[j];
		if (e.kind !== 'heading') continue;
		while (stack.length && entries[stack[stack.length - 1]].level >= e.level) stack.pop();
		stack.push(j);
	}
	// Drop any trailing headings that are siblings (level >= entries[i].level when i is a heading).
	if (entries[i] && entries[i].kind === 'heading') {
		while (stack.length && entries[stack[stack.length - 1]].level >= entries[i].level) stack.pop();
	}
	return stack;
}

// Whether any ancestor heading of entry `i` is currently collapsed.
function hiddenByFold(i) {
	const anc = ancestorsOf(i);
	for (const h of anc) if (collapsed.has(h)) return true;
	return false;
}

// ============================================================
// 5/ Rendering
// ============================================================

function render() {
	const list = el('list');
	list.innerHTML = '';
	visible = [];

	const q = el('search').value.trim().toLowerCase();
	const searching = q !== '';

	// When searching, mark headings that have at least one matching descendant.
	const headingHasMatch = new Set();
	if (searching) {
		const stack = [];
		for (let i = 0; i < entries.length; i++) {
			const e = entries[i];
			if (e.kind === 'heading') {
				while (stack.length && entries[stack[stack.length - 1]].level >= e.level) stack.pop();
				stack.push(i);
			} else if (matches(e, q)) {
				for (const h of stack) headingHasMatch.add(h);
			}
		}
	}

	let curLevel = 0; // depth of the last rendered heading → indent of its actions
	for (let i = 0; i < entries.length; i++) {
		const e = entries[i];
		if (e.kind === 'heading') {
			if (searching) {
				if (!headingHasMatch.has(i)) continue;
			} else if (hiddenByFold(i)) {
				continue;
			}
			curLevel = Math.min(e.level, 4);
			list.appendChild(buildHeadingRow(i, e));
		} else {
			if (searching) {
				if (!matches(e, q)) continue;
			} else if (hiddenByFold(i)) {
				continue;
			}
			const row = buildActionRow(e, e.special ? 0 : curLevel);
			list.appendChild(row);
			visible.push({ id: e.id, el: row });
		}
	}

	el('empty').hidden = visible.length > 0;
	if (!el('empty').hidden) el('empty').textContent = strings.noResults;
	el('count').textContent = visible.length ? String(visible.length) : '';

	let start = 0;
	for (let k = 0; k < visible.length; k++) {
		if (visible[k].id === currentId) { start = k; break; }
	}
	if (visible.length) setActive(start, true);
}

function matches(actionEntry, q) {
	return (actionEntry.label || '').toLowerCase().indexOf(q) !== -1;
}

function buildHeadingRow(i, e) {
	const row = document.createElement('div');
	const lvl = Math.min(e.level, 4);
	row.className = 'heading lvl' + lvl + (collapsed.has(i) ? ' collapsed' : '');
	row.style.paddingLeft = 8 + (lvl - 1) * 16 + 'px';

	const caret = document.createElement('span');
	caret.className = 'caret';
	caret.textContent = '▾';
	const txt = document.createElement('span');
	txt.className = 'heading-text';
	txt.textContent = e.text;
	row.appendChild(caret);
	row.appendChild(txt);

	// Folding is a fold of the live tree, so it is disabled while searching
	// (search already expands only the relevant matches).
	const searching = el('search').value.trim() !== '';
	if (!searching) {
		row.addEventListener('click', function () { toggleFold(i); });
	} else {
		row.classList.add('static');
	}
	return row;
}

function buildActionRow(e, depth) {
	const row = document.createElement('div');
	row.className = 'row' + (e.special ? ' special' : '') + (e.id === currentId ? ' current' : '');
	row.dataset.id = e.id;
	row.style.paddingLeft = 12 + (depth || 0) * 16 + 'px';

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
	return row;
}

function setActive(idx, instant) {
	if (idx < 0 || idx >= visible.length) return;
	if (visible[activeIndex] && visible[activeIndex].el) {
		visible[activeIndex].el.classList.remove('active');
	}
	activeIndex = idx;
	const row = visible[activeIndex].el;
	row.classList.add('active');
	row.scrollIntoView({ block: 'nearest' });
}

function toggleFold(i) {
	if (collapsed.has(i)) collapsed.delete(i);
	else collapsed.add(i);
	render();
}

// ============================================================
// 6/ Table of contents
// ============================================================

function toggleToc() {
	const toc = el('toc');
	if (toc.hidden) {
		buildToc();
		toc.hidden = false;
	} else {
		toc.hidden = true;
	}
}

function buildToc() {
	const inner = el('toc-inner');
	inner.innerHTML = '';
	for (let i = 0; i < entries.length; i++) {
		const e = entries[i];
		if (e.kind !== 'heading') continue;
		const lvl = Math.min(e.level, 4);
		const a = document.createElement('div');
		a.className = 'toc-item lvl' + lvl;
		a.style.paddingLeft = 10 + (lvl - 1) * 16 + 'px';
		a.textContent = e.text;
		a.addEventListener('click', function () { tocGoto(i); });
		inner.appendChild(a);
	}
}

function tocGoto(i) {
	// Expand every ancestor so the heading is visible, then scroll to it.
	for (const h of ancestorsOf(i)) collapsed.delete(h);
	el('search').value = '';
	el('toc').hidden = true;
	render();
	// Find the heading row by re-walking; headings carry no id, so match by order.
	const rows = el('list').children;
	let seen = -1;
	for (let r = 0; r < rows.length; r++) {
		if (rows[r].classList.contains('heading')) {
			seen++;
			if (headingDomToEntry(seen) === i) {
				rows[r].scrollIntoView({ block: 'start' });
				break;
			}
		}
	}
}

// Maps the Nth rendered heading (DOM order) back to its entry index. Rebuilt
// each call from the current fold state so it always matches what is on screen.
function headingDomToEntry(nth) {
	let seen = -1;
	for (let i = 0; i < entries.length; i++) {
		if (entries[i].kind !== 'heading') continue;
		if (hiddenByFold(i)) continue;
		seen++;
		if (seen === nth) return i;
	}
	return -1;
}

// ============================================================
// 7/ Events
// ============================================================

document.addEventListener('DOMContentLoaded', function () {
	el('search').addEventListener('input', function () { render(); });

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
			if (!el('toc').hidden) { el('toc').hidden = true; return; }
			doCancel();
		}
	});

	post({ action: 'ready' });
});
