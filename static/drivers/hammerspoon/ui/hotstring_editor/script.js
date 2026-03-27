// ui/hotstring_editor/script.js

// ===========================================================================
// Hotstring Editor UI Script.
//
// Manages the rich-text interface for creating and editing dynamic hotstrings.
// ===========================================================================

// ====================================
// ====================================
// ======= 1/ Globals & State =========
// ====================================
// ====================================

let D = null;
let TRIGGER_CHAR = '★';
let STAR = '★';

let edSec = null;
let edEntry = null;
let dragSrcIdx = null;

let compactView = false;
let autoClose = false;
let defaultSec = null;
let openMode = 'menu';

const TOKEN_NORM = {
	esc: 'Escape',
	escape: 'Escape',
	bs: 'BackSpace',
	backspace: 'BackSpace',
	del: 'Delete',
	delete: 'Delete',
	return: 'Enter',
	enter: 'Enter',
	left: 'Left',
	right: 'Right',
	up: 'Up',
	down: 'Down',
	home: 'Home',
	end: 'End',
	tab: 'Tab'
};

const TOKEN_NAMES = [
	'Left',
	'Right',
	'Up',
	'Down',
	'Home',
	'End',
	'Tab',
	'BackSpace',
	'Delete',
	'Escape',
	'Enter'
];

const CMD_GROUPS = [
	{
		lbl: 'Flèches',
		cmds: [
			{ token: 'Left', sym: '←', desc: 'gauche' },
			{ token: 'Right', sym: '→', desc: 'droite' },
			{ token: 'Up', sym: '↑', desc: 'haut' },
			{ token: 'Down', sym: '↓', desc: 'bas' }
		]
	},
	{
		lbl: 'Navigation',
		cmds: [
			{ token: 'Home', sym: 'Home', desc: 'début ligne' },
			{ token: 'End', sym: 'End', desc: 'fin ligne' },
			{ token: 'Tab', sym: '⇥', desc: 'tabulation' },
			{ token: 'Escape', sym: 'Esc', desc: 'Échap' }
		]
	},
	{
		lbl: 'Édition',
		cmds: [
			{ token: 'BackSpace', sym: '⌫', desc: 'effacer ←' },
			{ token: 'Delete', sym: '⌦', desc: 'effacer →' },
			{ token: 'Enter', sym: '↩', desc: 'saut de ligne' }
		]
	}
];

// ====================================
// ====================================
// ======= 2/ Utility Functions =======
// ====================================
// ====================================

/**
 * Escapes HTML characters in a string to prevent XSS and formatting issues.
 * @param {string} s - The raw string.
 * @returns {string} The escaped string.
 */
function esc(s) {
	return String(s || '')
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

/**
 * Normalizes a raw token name into its canonical PascalCase representation.
 * @param {string} name - The raw token name.
 * @returns {string} The normalized token name.
 */
function normToken(name) {
	const canonical = TOKEN_NORM[name.toLowerCase()];
	if (canonical) return canonical;
	return name.charAt(0).toUpperCase() + name.slice(1);
}

/**
 * Replaces the internal star representation with the user's custom trigger character for UI display.
 * @param {string} s - The internal string containing stars.
 * @returns {string} The formatted string ready for display.
 */
function toDisplay(s) {
	if (!s || TRIGGER_CHAR === STAR) return s || '';
	return String(s).split(STAR).join(TRIGGER_CHAR);
}

/**
 * Replaces the custom trigger character with the internal star representation for backend storage.
 * @param {string} s - The displayed string containing custom triggers.
 * @returns {string} The canonical internal string.
 */
function toCanonical(s) {
	if (!s || TRIGGER_CHAR === STAR) return s || '';
	const regex = new RegExp(TRIGGER_CHAR.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g');
	return String(s).replace(regex, STAR);
}

// ====================================
// ====================================
// ======= 3/ Lua Communication =======
// ====================================
// ====================================

/**
 * Sends a message to the Hammerspoon backend via the webkit message handler.
 * @param {string} action - The action identifier (e.g., 'save', 'close').
 * @param {Object} [data] - The payload to send along with the action.
 */
function toLua(action, data) {
	try {
		window.webkit.messageHandlers.hsEditor.postMessage({ action: action, data: data || {} });
	} catch (e) {
		console.error('[hsEditor]', e);
	}
}

// ====================================
// ====================================
// ======= 4/ Modals & Validation =====
// ====================================
// ====================================

/**
 * Safely adds the 'on' class to display a modal.
 * @param {string} id - The modal container ID.
 */
function openModal(id) {
	document.getElementById(id).classList.add('on');
}

/**
 * Safely removes the 'on' class to hide a modal and resets related form states.
 * @param {string} id - The modal container ID.
 */
function closeModal(id) {
	document.getElementById(id).classList.remove('on');
	if (id === 'entry-modal') clearEntryErrors();
	if (id === 'sec-modal') clearSecErrors();
}

/**
 * Displays a simple blocking alert modal.
 * @param {string} msg - The message to display.
 */
function showAlert(msg) {
	document.getElementById('msg-text').textContent = msg;
	openModal('msg-modal');
}

let _confirmCb = null;

/**
 * Displays a confirmation dialog requiring user approval before executing an action.
 * @param {string} msg - The question/warning to display.
 * @param {function} fn - The function to execute if the user approves.
 * @param {Object} [opts] - Additional UI modifiers for the dialog.
 */
function showConfirm(msg, fn, opts = {}) {
	let titleHtml = '';
	if (opts.isWarning) {
		titleHtml =
			'<div style="display:flex;align-items:center;gap:8px;color:var(--warning);font-weight:600;font-size:15px;margin-bottom:10px;"><span style="font-size:20px;">⚠️</span> Attention</div>';
	}
	document.getElementById('confirm-text').innerHTML =
		titleHtml +
		'<div style="font-size:13px;line-height:1.5;margin-bottom:16px;color:var(--text);">' +
		msg +
		'</div>';

	const okBtn = document.getElementById('confirm-ok');
	okBtn.textContent = opts.okLabel || 'Supprimer';
	okBtn.style.background = opts.okColor || 'var(--danger)';

	_confirmCb = fn;
	openModal('confirm-modal');
}

function setFieldError(fieldId, errId, msg) {
	const field = document.getElementById(fieldId);
	const err = document.getElementById(errId);
	if (field) {
		field.classList.remove('field-error');
		void field.offsetWidth;
		field.classList.add('field-error');
	}
	if (err && msg) {
		err.textContent = msg;
		err.classList.add('on');
	}
}

function clearFieldError(fieldId, errId) {
	const field = document.getElementById(fieldId);
	const err = document.getElementById(errId);
	if (field) field.classList.remove('field-error');
	if (err) {
		err.textContent = '';
		err.classList.remove('on');
	}
}

function clearEntryErrors() {
	clearFieldError('e-trig', 'trig-err');
	clearFieldError('e-out', 'out-err');
}

function clearSecErrors() {
	clearFieldError('sec-id', 'sec-id-err');
}

// ====================================
// ====================================
// ======= 5/ UI State Updaters =======
// ====================================
// ====================================

/**
 * Dynamically updates the textual descriptions below the checkboxes.
 */
function updateCbDescs() {
	const w = document.getElementById('cb-word').checked;
	const a = document.getElementById('cb-auto').checked;
	const c = document.getElementById('cb-case').checked;
	const f = document.getElementById('cb-final').checked;

	document.getElementById('desc-word').innerHTML = w
		? 'Ne se déclenche que si c’est un mot complet.<br>Ex : <em>tel</em>→téléphone mais pas <em>hôtel</em>'
		: 'S’active partout, même comme sous-chaîne.<br>Ex : s’activera à l’intérieur de <em>hôtel</em>';

	document.getElementById('desc-auto').innerHTML = a
		? 'S’expand immédiatement (idéal pour les déclencheurs finissant par ' +
			esc(TRIGGER_CHAR) +
			').'
		: 'Nécessite de taper Espace/Entrée (conseillé pour l’autocorrection).';

	document.getElementById('desc-case').innerHTML = c
		? 'Différencie strictement majuscules/minuscules.<br>Ex : <em>Btw</em> ≠ <em>btw</em>'
		: 'Le moteur générera les versions minuscule, Titlecase et MAJUSCULE.';

	document.getElementById('desc-final').innerHTML = f
		? 'Le résultat ne sera pas re-analysé comme déclencheur.'
		: 'Le résultat pourra déclencher d’autres hotstrings en cascade.';
}

/**
 * Updates visual hints explaining trigger characters.
 */
function updateHints() {
	const hint = document.getElementById('trig-hint');
	if (hint) {
		if (TRIGGER_CHAR !== STAR) {
			hint.innerHTML =
				'<span class="star-badge">' +
				esc(TRIGGER_CHAR) +
				'</span> affiché, stocké en <span class="star-badge">' +
				esc(STAR) +
				'</span>';
		} else {
			hint.textContent = '';
		}
	}
	const mb = document.getElementById('magic-btn');
	if (mb) mb.textContent = TRIGGER_CHAR;
}

function updateCompactBtn() {
	const b = document.getElementById('compact-btn');
	if (b) b.textContent = compactView ? 'Vue développée' : 'Vue compacte';
}

function toggleCompact() {
	compactView = !compactView;
	updateCompactBtn();
	render();
	toLua('save_pref', { key: 'compact_view', value: compactView });
}

function checkPh() {
	const ed = document.getElementById('e-out');
	const ph = document.getElementById('e-out-ph');
	const isEmpty = ed.textContent.length === 0 && ed.innerHTML.indexOf('<span') === -1;
	ph.style.display = isEmpty ? 'block' : 'none';
}

// ====================================
// ====================================
// ======= 6/ Chips & Editors =========
// ====================================
// ====================================

function makeChip(name) {
	const s = document.createElement('span');
	s.className = 'token-chip';
	s.contentEditable = 'false';
	s.dataset.token = name;
	s.textContent = name;
	return s;
}

function makeTrigChip() {
	const s = document.createElement('span');
	s.className = 'token-chip';
	s.contentEditable = 'false';
	s.dataset.trigChar = 'true';
	s.textContent = TRIGGER_CHAR;
	return s;
}

function setTrigContent(el, text) {
	el.innerHTML = '';
	if (!text) return;
	const display = toDisplay(text);
	const parts = display.split(TRIGGER_CHAR);
	parts.forEach((part, i) => {
		if (part) el.appendChild(document.createTextNode(part));
		if (i < parts.length - 1) el.appendChild(makeTrigChip());
	});
}

function serializeTrigEditor(el) {
	let s = '';
	el.childNodes.forEach((n) => {
		if (n.nodeType === 3) s += toCanonical(n.textContent);
		else if (n.nodeType === 1 && n.dataset && n.dataset.trigChar) s += STAR;
		else s += toCanonical(n.textContent || '');
	});
	return s.trim();
}

function parseToNodes(text) {
	if (!text) return [document.createTextNode('')];
	text = toDisplay(text);
	const nodes = [];
	const re = /\{([^}]+)\}/g;
	let last = 0;
	let m;
	while ((m = re.exec(text)) !== null) {
		if (m.index > last) nodes.push(document.createTextNode(text.slice(last, m.index)));
		const tname = normToken(m[1]);
		if (tname === 'Enter') nodes.push(document.createElement('br'));
		else nodes.push(makeChip(tname));
		last = re.lastIndex;
	}
	if (last < text.length) nodes.push(document.createTextNode(text.slice(last)));
	return nodes;
}

function serializeEditor(el) {
	const nodes = Array.from(el.childNodes);
	while (nodes.length > 0) {
		const last = nodes[nodes.length - 1];
		if (last.nodeType === 1 && last.tagName === 'BR' && !last.classList.contains('token-chip')) {
			nodes.pop();
		} else {
			break;
		}
	}
	let s = '';
	nodes.forEach((n) => {
		if (n.nodeType === 3) s += toCanonical(n.textContent);
		else if (n.nodeType === 1 && n.classList.contains('token-chip'))
			s += '{' + n.dataset.token + '}';
		else if (n.nodeType === 1 && n.tagName === 'BR') s += '{Enter}';
		else s += toCanonical(n.textContent || '');
	});
	return s;
}

function setEditorContent(el, text) {
	el.innerHTML = '';
	parseToNodes(text || '').forEach((n) => el.appendChild(n));
	checkPh();
}

// ====================================
// ====================================
// ======= 7/ Editor Interactions =====
// ====================================
// ====================================

function insertBrAtCursor() {
	const ed = document.getElementById('e-out');
	ed.focus();
	let sel = window.getSelection();
	const br = document.createElement('br');
	if (sel && sel.rangeCount) {
		const r = sel.getRangeAt(0);
		if (ed.contains(r.commonAncestorContainer)) {
			r.deleteContents();
			r.insertNode(br);
			if (!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));
			const nr = document.createRange();
			nr.setStartAfter(br);
			nr.collapse(true);
			sel.removeAllRanges();
			sel.addRange(nr);
			checkPh();
			return;
		}
	}
	ed.appendChild(br);
	ed.appendChild(document.createTextNode(''));
	checkPh();
}

function insertChipAtCursor(name) {
	if (name === 'Enter') {
		insertBrAtCursor();
		return;
	}
	const ed = document.getElementById('e-out');
	ed.focus();
	const chip = makeChip(normToken(name));
	let sel = window.getSelection();
	if (sel && sel.rangeCount) {
		const r = sel.getRangeAt(0);
		if (ed.contains(r.commonAncestorContainer)) {
			r.deleteContents();
			r.insertNode(chip);
			const nr = document.createRange();
			nr.setStartAfter(chip);
			nr.collapse(true);
			sel.removeAllRanges();
			sel.addRange(nr);
			checkPh();
			return;
		}
	}
	ed.appendChild(chip);
	const nr = document.createRange();
	nr.setStartAfter(chip);
	nr.collapse(true);
	sel = window.getSelection();
	if (sel) {
		sel.removeAllRanges();
		sel.addRange(nr);
	}
	checkPh();
}

function insertMagicKey() {
	const te = document.getElementById('e-trig');
	te.focus();
	const chip = makeTrigChip();
	let sel = window.getSelection();
	if (sel && sel.rangeCount) {
		const r = sel.getRangeAt(0);
		if (te.contains(r.commonAncestorContainer)) {
			r.deleteContents();
			r.insertNode(chip);
			const nr = document.createRange();
			nr.setStartAfter(chip);
			nr.collapse(true);
			sel.removeAllRanges();
			sel.addRange(nr);
			return;
		}
	}
	te.appendChild(chip);
	const nr = document.createRange();
	nr.setStartAfter(chip);
	nr.collapse(true);
	sel = window.getSelection();
	if (sel) {
		sel.removeAllRanges();
		sel.addRange(nr);
	}
}

function tryConvertToken(editor) {
	const sel = window.getSelection();
	if (!sel || !sel.rangeCount) return;
	const range = sel.getRangeAt(0);
	if (!range.collapsed) return;
	const node = range.startContainer;
	if (node.nodeType !== 3) return;

	const offset = range.startOffset;
	const before = node.textContent.slice(0, offset);
	const m = before.match(/\{(\w+)\}$/);
	if (!m) return;

	const tokenName = normToken(m[1]);
	if (TOKEN_NAMES.indexOf(tokenName) < 0) return;

	const matchStart = offset - m[0].length;
	const r = document.createRange();
	r.setStart(node, matchStart);
	r.setEnd(node, offset);
	r.deleteContents();

	if (tokenName === 'Enter') {
		const anch = sel.getRangeAt(0);
		const br = document.createElement('br');
		anch.insertNode(br);
		if (!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));
		const nr = document.createRange();
		nr.setStartAfter(br);
		nr.collapse(true);
		sel.removeAllRanges();
		sel.addRange(nr);
		checkPh();
		return;
	}
	const chip = makeChip(tokenName);
	const anch = sel.getRangeAt(0);
	anch.insertNode(chip);
	const nr = document.createRange();
	nr.setStartAfter(chip);
	nr.collapse(true);
	sel.removeAllRanges();
	sel.addRange(nr);
	checkPh();
}

let _ejecting = false;
function ejectFromChip() {
	if (_ejecting) return;
	const sel = window.getSelection();
	if (!sel || !sel.rangeCount || !sel.isCollapsed) return;
	const range = sel.getRangeAt(0);
	const node = range.startContainer;
	const el = node.nodeType === 3 ? node.parentElement : node;
	if (el && el.classList && el.classList.contains('token-chip')) {
		_ejecting = true;
		const nr = document.createRange();
		nr.setStartAfter(el);
		nr.collapse(true);
		sel.removeAllRanges();
		sel.addRange(nr);
		_ejecting = false;
	}
}

// ====================================
// ====================================
// ======= 8/ Autocomplete Engine =====
// ====================================
// ====================================

let acItems = [];
let acIdx = 0;

function getAcCtx() {
	const sel = window.getSelection();
	if (!sel || !sel.rangeCount) return null;
	const r = sel.getRangeAt(0);
	if (!r.collapsed) return null;
	const n = r.startContainer;
	if (n.nodeType !== 3) return null;
	const text = n.textContent.slice(0, r.startOffset);
	const m = text.match(/\{(\w*)$/);
	if (!m) return null;
	return { partial: m[1].toLowerCase(), start: r.startOffset - m[0].length, node: n };
}

function showAc(matches) {
	const popup = document.getElementById('ac-popup');
	acItems = matches;
	acIdx = 0;
	popup.innerHTML = '';
	const sel = window.getSelection();
	if (!sel || !sel.rangeCount) {
		hideAc();
		return;
	}
	const rect = sel.getRangeAt(0).getBoundingClientRect();
	matches.forEach((name, i) => {
		const d = document.createElement('div');
		d.className = 'ac-item' + (i === 0 ? ' active' : '');
		d.textContent = name;
		d.addEventListener('mousedown', (e) => {
			e.preventDefault();
			applyAc(name);
		});
		popup.appendChild(d);
	});
	popup.style.left = rect.left + 'px';
	popup.style.top = rect.bottom + 4 + 'px';
	popup.classList.add('on');
}

function hideAc() {
	document.getElementById('ac-popup').classList.remove('on');
	acItems = [];
}

function updateAcSel() {
	document.querySelectorAll('.ac-item').forEach((el, i) => {
		el.classList.toggle('active', i === acIdx);
	});
}

function applyAc(name) {
	hideAc();
	const ctx = getAcCtx();
	if (!ctx) {
		insertChipAtCursor(name);
		return;
	}
	const r = document.createRange();
	r.setStart(ctx.node, ctx.start);
	r.setEnd(ctx.node, ctx.start + ctx.partial.length + 1);
	r.deleteContents();

	if (normToken(name) === 'Enter') {
		const sel2 = window.getSelection();
		const anch = sel2.getRangeAt(0);
		const br = document.createElement('br');
		anch.insertNode(br);
		if (!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));
		const nr = document.createRange();
		nr.setStartAfter(br);
		nr.collapse(true);
		sel2.removeAllRanges();
		sel2.addRange(nr);
		checkPh();
		return;
	}
	const chip = makeChip(normToken(name));
	const sel3 = window.getSelection();
	const anch2 = sel3.getRangeAt(0);
	anch2.insertNode(chip);
	const nr2 = document.createRange();
	nr2.setStartAfter(chip);
	nr2.collapse(true);
	sel3.removeAllRanges();
	sel3.addRange(nr2);
	checkPh();
}

function checkAc() {
	const ctx = getAcCtx();
	if (!ctx) {
		hideAc();
		return;
	}
	const matches = TOKEN_NAMES.filter((n) => n.toLowerCase().startsWith(ctx.partial));
	if (matches.length === 0) {
		hideAc();
		return;
	}
	showAc(matches);
}

// ====================================
// ====================================
// ======= 9/ Drag & Drop Engine ======
// ====================================
// ====================================

function onDragStart(e, si) {
	dragSrcIdx = si;
	e.dataTransfer.effectAllowed = 'move';
	e.dataTransfer.setData('text/plain', String(si));
	setTimeout(() => {
		const c = document.getElementById('sc-' + si);
		if (c) c.classList.add('dragging');
	}, 0);
}

function onDragOver(e, si) {
	e.preventDefault();
	e.dataTransfer.dropEffect = 'move';
	document.querySelectorAll('.sec-card').forEach((c, i) => {
		c.classList.toggle('drag-over', i === si && i !== dragSrcIdx);
	});
}

function onDrop(e, si) {
	e.preventDefault();
	const c = document.getElementById('sc-' + si);
	if (c) c.draggable = false;
	if (dragSrcIdx === null || dragSrcIdx === si) {
		cleanDrag();
		return;
	}
	const moved = D.sections.splice(dragSrcIdx, 1)[0];
	D.sections.splice(si, 0, moved);
	dragSrcIdx = null;
	persist();
}

function onDragEnd() {
	document.querySelectorAll('.sec-card').forEach((c) => (c.draggable = false));
	cleanDrag();
}

function cleanDrag() {
	dragSrcIdx = null;
	document
		.querySelectorAll('.sec-card')
		.forEach((c) => c.classList.remove('drag-over', 'dragging'));
}

// ====================================
// ====================================
// ======= 10/ Main Renderer ==========
// ====================================
// ====================================

function buildCmdGrid() {
	const b = document.getElementById('cmd-block');
	b.innerHTML = '';
	CMD_GROUPS.forEach((g, gi) => {
		if (gi > 0) {
			const s = document.createElement('hr');
			s.className = 'cmd-sep';
			b.appendChild(s);
		}
		const l = document.createElement('div');
		l.className = 'cmd-grp-lbl';
		l.textContent = g.lbl;
		b.appendChild(l);
		g.cmds.forEach((c) => {
			const el = document.createElement('div');
			el.className = 'cmd-ref';
			el.title = '{' + c.token + '} — ' + c.desc;
			el.innerHTML =
				'<span class="cmd-sym">' +
				esc(c.sym) +
				'</span><span class="cmd-lbl">' +
				esc(c.desc) +
				'</span>';
			el.addEventListener('mousedown', (e) => e.preventDefault());
			el.addEventListener('click', () => insertChipAtCursor(c.token));
			b.appendChild(el);
		});
	});
}

function dispTrig(s) {
	if (!s) return '';
	return esc(toDisplay(s))
		.split(esc(TRIGGER_CHAR))
		.join('<span class="trig-star">' + esc(TRIGGER_CHAR) + '</span>');
}

function dispOutput(s) {
	if (!s) return '';
	let out = esc(toDisplay(s));
	out = out.replace(/\{([^}]+)\}/g, function (_, name) {
		const canon = normToken(name);
		return '<span class="tc" data-tok="' + esc(canon) + '">' + esc(canon) + '</span>';
	});
	if (!compactView) {
		out = out.replace(/<span class="tc" data-tok="Enter">Enter<\/span>/g, '<br>');
	}
	return out;
}

let _rowMouseDownX = 0,
	_rowMouseDownY = 0;
function onRowMouseDown(e) {
	_rowMouseDownX = e.clientX;
	_rowMouseDownY = e.clientY;
}

function handleSecTitleClick(e, si) {
	const dx = e.clientX - _rowMouseDownX,
		dy = e.clientY - _rowMouseDownY;
	if (Math.sqrt(dx * dx + dy * dy) > 4) return;
	const sel = window.getSelection();
	if (sel && sel.toString().length > 0) return;
	showEditSec(si);
}

function handleRowClick(e, si, ei) {
	const dx = e.clientX - _rowMouseDownX,
		dy = e.clientY - _rowMouseDownY;
	if (Math.sqrt(dx * dx + dy * dy) > 4) return;
	const sel = window.getSelection();
	if (sel && sel.toString().length > 0) return;

	let target = e.target;
	let field = null;
	while (target && target !== e.currentTarget) {
		if (target.dataset && target.dataset.f) {
			field = target.dataset.f;
			break;
		}
		target = target.parentElement;
	}
	showEditEntry(si, ei, field);
}

function togSec(si) {
	if (D.sections[si]) {
		D.sections[si]._exp = D.sections[si]._exp === false;
		render();
	}
}

function render() {
	const cont = document.getElementById('secs-container');
	const empty = document.getElementById('empty');

	if (!D || !D.sections || !D.sections.length) {
		cont.innerHTML = '';
		empty.style.display = 'block';
		return;
	}

	empty.style.display = 'none';
	let html = '';

	D.sections.forEach((s, si) => {
		const cnt = s.entries ? s.entries.length : 0;
		const exp = s._exp !== false;

		html += '<div class="sec-card" id="sc-' + si + '">';
		html += '<div class="sec-head' + (exp ? ' open' : '') + '">';
		html += '<span class="drag-handle" id="dh-' + si + '" title="Glisser">☰</span>';
		html +=
			'<span class="caret' + (exp ? ' open' : '') + '" onclick="togSec(' + si + ')">▶</span>';
		html +=
			'<span class="sec-title" onmousedown="onRowMouseDown(event)" onclick="handleSecTitleClick(event,' +
			si +
			')">' +
			esc(s.description || s.name) +
			'</span>';
		html += '<span class="sec-cnt">(' + cnt + ')</span>';
		html +=
			'<button class="sec-del" onclick="delSec(' +
			si +
			')" onmousedown="event.stopPropagation()">✕</button>';
		html += '</div>';

		if (exp) {
			html += '<div class="' + (compactView ? 'compact' : 'expanded') + '">';
			(s.entries || []).forEach((e, ei) => {
				html +=
					'<div class="entry-row" onmousedown="onRowMouseDown(event)" onclick="handleRowClick(event,' +
					si +
					',' +
					ei +
					')">';
				html +=
					'<div class="entry-cb-wrap"><input type="checkbox" class="entry-cb" data-si="' +
					si +
					'" data-ei="' +
					ei +
					'" onclick="event.stopPropagation(); updateBulk()" onmousedown="event.stopPropagation()"></div>';
				html +=
					'<div class="e-trig"><span class="trig-lbl" data-f="trig" title="Clic pour modifier">' +
					dispTrig(e.trigger) +
					'</span></div>';
				html += '<span class="e-arrow">→</span>';
				html +=
					'<div class="e-out-cell"><div class="e-out" data-f="out" title="Clic pour modifier">' +
					dispOutput(e.output) +
					'</div></div>';
				html += '<div class="e-tags">';
				if (e.is_word) html += '<span class="tag on" data-f="cb-word">Mot</span>';
				if (e.auto_expand) html += '<span class="tag on" data-f="cb-auto">Auto</span>';
				if (e.is_case_sensitive) html += '<span class="tag on" data-f="cb-case">Casse</span>';
				if (e.final_result) html += '<span class="tag on" data-f="cb-final">Final</span>';
				html += '</div>';
				html += '<span class="e-del" onclick="delEntryStop(event,' + si + ',' + ei + ')">✕</span>';
				html += '</div>';
			});
			html +=
				'<button class="btn-add" onclick="showAddEntry(' +
				si +
				')">＋ Ajouter un hotstring</button>';
			html += '</div>';
		}
		html += '</div>';
	});
	cont.innerHTML = html;

	D.sections.forEach((_, si) => {
		const handle = document.getElementById('dh-' + si);
		const card = document.getElementById('sc-' + si);
		if (!handle || !card) return;

		handle.addEventListener('mousedown', () => {
			card.draggable = true;
		});
		card.addEventListener('dragstart', (e) => onDragStart(e, si));
		card.addEventListener('dragover', (e) => onDragOver(e, si));
		card.addEventListener('drop', (e) => onDrop(e, si));
		card.addEventListener('dragend', onDragEnd);
	});
}

// ====================================
// ====================================
// ======= 11/ Section CRUD ===========
// ====================================
// ====================================

function showAddSec() {
	edSec = null;
	document.getElementById('sec-modal-title').textContent = 'Nouvelle section';
	const idEl = document.getElementById('sec-id');
	idEl.value = '';
	idEl.disabled = false;
	document.getElementById('sec-desc').value = '';
	clearSecErrors();
	openModal('sec-modal');
	setTimeout(() => idEl.focus(), 80);
}

function showEditSec(si) {
	edSec = si;
	const s = D.sections[si];
	document.getElementById('sec-modal-title').textContent = 'Renommer la section';
	const idEl = document.getElementById('sec-id');
	idEl.value = s.name;
	idEl.disabled = true;
	document.getElementById('sec-desc').value = s.description || '';
	clearSecErrors();
	openModal('sec-modal');
	setTimeout(() => document.getElementById('sec-desc').focus(), 80);
}

function saveSec() {
	const id = document.getElementById('sec-id').value.trim();
	const desc = document.getElementById('sec-desc').value.trim();
	clearSecErrors();

	if (edSec === null) {
		if (!id) {
			setFieldError('sec-id', 'sec-id-err', 'L’identifiant est requis.');
			document.getElementById('sec-id').focus();
			return;
		}
		if (!/^[a-z0-9_]+$/.test(id)) {
			setFieldError(
				'sec-id',
				'sec-id-err',
				'Identifiant invalide : uniquement minuscules, chiffres et underscores.'
			);
			document.getElementById('sec-id').focus();
			return;
		}
		if (D.sections.some((s) => s.name === id)) {
			setFieldError('sec-id', 'sec-id-err', '« ' + id + ' » existe déjà.');
			document.getElementById('sec-id').focus();
			return;
		}
		D.sections.push({ name: id, description: desc || id, entries: [], _exp: true });
	} else {
		D.sections[edSec].description = desc || D.sections[edSec].name;
	}

	closeModal('sec-modal');
	persist();
}

function delSec(si) {
	const s = D.sections[si];
	showConfirm(
		'Supprimer « ' + (s.description || s.name) + ' » et tous ses hotstrings ?',
		function () {
			D.sections.splice(si, 1);
			persist();
		}
	);
}

// ====================================
// ====================================
// ======= 12/ Entry CRUD =============
// ====================================
// ====================================

function resetEntryForm() {
	document.getElementById('e-trig').innerHTML = '';
	setEditorContent(document.getElementById('e-out'), '');
	document.getElementById('cb-word').checked = true;
	document.getElementById('cb-auto').checked = true;
	document.getElementById('cb-case').checked = false;
	document.getElementById('cb-final').checked = false;
	clearEntryErrors();
	updateHints();
	updateCbDescs();
	checkPh();
}

function showAddEntry(si) {
	edEntry = { si: si, ei: null };
	const secName = D.sections[si].description || D.sections[si].name;
	document.getElementById('entry-modal-title').textContent =
		'Création d’un hotstring — Section «\xA0' + secName + '\xA0»';
	resetEntryForm();
	openModal('entry-modal');
	setTimeout(() => document.getElementById('e-trig').focus(), 80);
}

function showEditEntry(si, ei, focusField) {
	edEntry = { si: si, ei: ei };
	const e = D.sections[si].entries[ei];
	const secName = D.sections[si].description || D.sections[si].name;
	document.getElementById('entry-modal-title').textContent =
		'Modification d’un hotstring — Section «\xA0' + secName + '\xA0»';

	setTrigContent(document.getElementById('e-trig'), e.trigger || '');
	setEditorContent(document.getElementById('e-out'), e.output || '');

	document.getElementById('cb-word').checked = !!e.is_word;
	document.getElementById('cb-auto').checked = !!e.auto_expand;
	document.getElementById('cb-case').checked = !!e.is_case_sensitive;
	document.getElementById('cb-final').checked = !!e.final_result;

	clearEntryErrors();
	updateHints();
	updateCbDescs();
	checkPh();
	openModal('entry-modal');

	setTimeout(() => {
		let el = null;
		if (focusField === 'out') el = document.getElementById('e-out');
		else if (focusField === 'trig') el = document.getElementById('e-trig');
		else if (focusField && focusField.indexOf('cb-') === 0)
			el = document.getElementById(focusField);
		else el = document.getElementById('e-trig');

		if (el) {
			el.focus();
			if (el.isContentEditable && window.getSelection && document.createRange) {
				const range = document.createRange();
				range.selectNodeContents(el);
				range.collapse(false);
				const sel = window.getSelection();
				sel.removeAllRanges();
				sel.addRange(range);
			}
		}
	}, 80);
}

function saveEntry(andNew) {
	clearEntryErrors();
	const trig = serializeTrigEditor(document.getElementById('e-trig'));
	const out = serializeEditor(document.getElementById('e-out'));

	if (!trig) {
		setFieldError('e-trig', 'trig-err', 'Le déclencheur est requis.');
		setTimeout(() => document.getElementById('e-trig').focus(), 0);
		return;
	}
	if (!out.trim()) {
		setFieldError('e-out', 'out-err', 'Le remplacement est requis.');
		setTimeout(() => document.getElementById('e-out').focus(), 0);
		return;
	}

	let dupSection = null;
	D.sections.forEach((s, si2) => {
		(s.entries || []).forEach((e2, ei2) => {
			if (dupSection) return;
			if (edEntry.ei !== null && edEntry.si === si2 && ei2 === edEntry.ei) return;
			if (e2.trigger === trig) dupSection = s.description || s.name;
		});
	});

	const executeSave = () => {
		const entry = {
			trigger: trig,
			output: out,
			is_word: document.getElementById('cb-word').checked,
			auto_expand: document.getElementById('cb-auto').checked,
			is_case_sensitive: document.getElementById('cb-case').checked,
			final_result: document.getElementById('cb-final').checked
		};

		const si = edEntry.si;
		if (edEntry.ei === null) D.sections[si].entries.push(entry);
		else D.sections[si].entries[edEntry.ei] = entry;

		D.sections[si].entries.sort((a, b) => {
			const ta = (a.trigger || '').toLowerCase().replace(/[^\w]/g, '');
			const tb = (b.trigger || '').toLowerCase().replace(/[^\w]/g, '');
			return ta < tb ? -1 : ta > tb ? 1 : 0;
		});

		persist();

		if (andNew) {
			edEntry = { si: si, ei: null };
			const secName = D.sections[si].description || D.sections[si].name;
			document.getElementById('entry-modal-title').textContent =
				'Création d’un hotstring — Section «\xA0' + secName + '\xA0»';
			resetEntryForm();
			setTimeout(() => document.getElementById('e-trig').focus(), 50);
			return;
		}

		if (openMode === 'shortcut' && autoClose) {
			closeModal('entry-modal');
			toLua('close', {});
			return;
		}
		closeModal('entry-modal');
	};

	if (dupSection) {
		showConfirm(
			'Le déclencheur <strong>' +
				esc(toDisplay(trig)) +
				'</strong> existe déjà dans <em>' +
				esc(dupSection) +
				'</em>.<br><br>Voulez-vous vraiment le redéfinir ?',
			executeSave,
			{ okLabel: 'Redéfinir', okColor: '#ff9500', isWarning: true }
		);
	} else {
		executeSave();
	}
}

function delEntryStop(e, si, ei) {
	e.stopPropagation();
	delEntry(si, ei);
}

function delEntry(si, ei) {
	const trig = toDisplay(D.sections[si].entries[ei].trigger);
	showConfirm('Supprimer « ' + esc(trig) + ' » ?', function () {
		D.sections[si].entries.splice(ei, 1);
		persist();
	});
}

// ====================================
// ====================================
// ======= 13/ Bulk Actions ===========
// ====================================
// ====================================

window.updateBulk = function () {
	const cbs = document.querySelectorAll('.entry-cb:checked');
	const bar = document.getElementById('bulk-bar');
	if (cbs.length > 0) {
		const cnt = cbs.length;
		document.getElementById('bulk-cnt').textContent = cnt + ' sélectionné' + (cnt > 1 ? 's' : '');
		const sel = document.getElementById('bulk-sec-sel');
		sel.innerHTML = '<option value="">Déplacer vers…</option>';
		D.sections.forEach((s, idx) => {
			sel.innerHTML += '<option value="' + idx + '">' + esc(s.description || s.name) + '</option>';
		});
		bar.style.display = 'flex';
	} else {
		bar.style.display = 'none';
	}
};

window.clearBulk = function () {
	document.querySelectorAll('.entry-cb').forEach((cb) => (cb.checked = false));
	window.updateBulk();
};

window.bulkDel = function () {
	const cnt = document.querySelectorAll('.entry-cb:checked').length;
	showConfirm(
		'Supprimer les ' +
			cnt +
			' élément' +
			(cnt > 1 ? 's' : '') +
			' sélectionné' +
			(cnt > 1 ? 's' : '') +
			' ?',
		function () {
			const cbs = Array.from(document.querySelectorAll('.entry-cb:checked'));
			const toDel = cbs.map((cb) => ({ si: parseInt(cb.dataset.si), ei: parseInt(cb.dataset.ei) }));
			toDel.sort((a, b) => (a.si !== b.si ? b.si - a.si : b.ei - a.ei));
			toDel.forEach((item) => D.sections[item.si].entries.splice(item.ei, 1));
			window.clearBulk();
			persist();
		}
	);
};

window.bulkMove = function () {
	const sel = document.getElementById('bulk-sec-sel');
	const destSi = parseInt(sel.value);
	if (isNaN(destSi)) return;

	const cbs = Array.from(document.querySelectorAll('.entry-cb:checked'));
	const toMove = cbs.map((cb) => ({ si: parseInt(cb.dataset.si), ei: parseInt(cb.dataset.ei) }));
	toMove.sort((a, b) => (a.si !== b.si ? b.si - a.si : b.ei - a.ei));

	toMove.forEach((item) => {
		const entry = D.sections[item.si].entries.splice(item.ei, 1)[0];
		D.sections[destSi].entries.push(entry);
	});

	D.sections[destSi].entries.sort((a, b) => {
		const ta = (a.trigger || '').toLowerCase().replace(/[^\w]/g, '');
		const tb = (b.trigger || '').toLowerCase().replace(/[^\w]/g, '');
		return ta < tb ? -1 : ta > tb ? 1 : 0;
	});

	sel.value = '';
	window.clearBulk();
	persist();
};

// ====================================
// ====================================
// ======= 14/ Data Sync & Init =======
// ====================================
// ====================================

function persist() {
	const payload = { sections_order: [], sections: {} };
	D.sections.forEach((s) => {
		payload.sections_order.push(s.name);
		payload.sections[s.name] = {
			description: s.description,
			entries: (s.entries || []).map((e) => ({
				trigger: e.trigger,
				output: e.output,
				is_word: !!e.is_word,
				auto_expand: !!e.auto_expand,
				is_case_sensitive: !!e.is_case_sensitive,
				final_result: !!e.final_result
			}))
		};
	});
	toLua('save', payload);
	render();

	const t = document.getElementById('save-toast');
	t.classList.add('show');
	setTimeout(() => t.classList.remove('show'), 1400);
}

window.initData = function (d) {
	D = d;
	TRIGGER_CHAR = d.trigger_char || '★';
	STAR = d.star || '★';
	compactView = !!d.compact_view;
	autoClose = !!d.auto_close;
	defaultSec = d.default_section || null;
	openMode = d.open_mode || 'menu';

	buildCmdGrid();
	updateHints();
	updateCompactBtn();

	document.getElementById('loading').style.display = 'none';
	document.getElementById('app').style.display = 'flex';
	render();

	if (openMode === 'shortcut' && defaultSec) {
		const si = D.sections.findIndex((s) => s.name === defaultSec);
		if (si >= 0) setTimeout(() => showAddEntry(si), 300);
	}
};

window.updateData = function (d) {
	if (D && D.sections && d && d.sections) {
		const m = {};
		D.sections.forEach((s) => (m[s.name] = s._exp));
		d.sections.forEach((s) => {
			if (m[s.name] !== undefined) s._exp = m[s.name];
		});
	}
	D = d;
	TRIGGER_CHAR = d.trigger_char || TRIGGER_CHAR;
	compactView = !!d.compact_view;
	autoClose = !!d.auto_close;
	defaultSec = d.default_section || null;

	updateHints();
	render();
};

// ====================================
// ====================================
// ======= 15/ Event Wiring ===========
// ====================================
// ====================================

window.addEventListener(
	'focus',
	function (e) {
		if (e.target === window || e.target === document) toLua('window_focus', { focused: true });
	},
	true
);

window.addEventListener(
	'blur',
	function (e) {
		if (e.target === window || e.target === document) toLua('window_focus', { focused: false });
	},
	true
);

document.querySelectorAll('.overlay').forEach((el) => {
	el.addEventListener('click', (e) => {
		if (e.target === el) closeModal(el.id);
	});
});

document.getElementById('msg-modal').addEventListener('keydown', (e) => {
	if (e.key === 'Enter' || e.key === 'Escape') closeModal('msg-modal');
});

document.getElementById('confirm-modal').addEventListener('keydown', (e) => {
	if (e.key === 'Escape') {
		_confirmCb = null;
		closeModal('confirm-modal');
	}
});

document.getElementById('sec-modal').addEventListener('keydown', (e) => {
	if (e.key === 'Enter') {
		e.preventDefault();
		saveSec();
	}
	if (e.key === 'Escape') closeModal('sec-modal');
});

document.getElementById('entry-modal').addEventListener('keydown', (e) => {
	if (e.key === 'Escape') closeModal('entry-modal');
});

document.getElementById('sec-id').addEventListener('input', function () {
	clearFieldError('sec-id', 'sec-id-err');
	const p = this.selectionStart;
	const c = this.value.toLowerCase().replace(/[^a-z0-9_]/g, '');
	if (c !== this.value) {
		this.value = c;
		this.setSelectionRange(Math.max(0, p - 1), Math.max(0, p - 1));
	}
});

document.getElementById('sec-id').addEventListener('keydown', function (e) {
	if (
		[
			'Backspace',
			'Delete',
			'ArrowLeft',
			'ArrowRight',
			'ArrowUp',
			'ArrowDown',
			'Home',
			'End',
			'Tab',
			'Enter',
			'Escape'
		].indexOf(e.key) >= 0
	)
		return;
	if (e.metaKey || e.ctrlKey) return;
	if (!/^[a-z0-9_]$/i.test(e.key)) e.preventDefault();
});

document.addEventListener('selectionchange', ejectFromChip);

// Trigger Editor logic
(function () {
	const te = document.getElementById('e-trig');
	te.addEventListener('input', () => clearFieldError('e-trig', 'trig-err'));

	te.addEventListener('keydown', function (e) {
		if (e.key === 'Enter' || e.key === 'Tab') {
			e.preventDefault();
			document.getElementById('e-out').focus();
			return;
		}
		if (e.key === 'Backspace') {
			const sel = window.getSelection();
			if (!sel || !sel.rangeCount) return;
			const range = sel.getRangeAt(0);
			if (!range.collapsed) return;
			const node = range.startContainer,
				offset = range.startOffset;
			let chip = null;
			if (node === te && offset > 0) {
				const p = te.childNodes[offset - 1];
				if (p && p.nodeType === 1 && p.classList.contains('token-chip')) chip = p;
			} else if (node.nodeType === 3 && offset === 0 && node.previousSibling) {
				const p = node.previousSibling;
				if (p && p.nodeType === 1 && p.classList.contains('token-chip')) chip = p;
			}
			if (chip) {
				e.preventDefault();
				chip.parentNode.removeChild(chip);
				return;
			}
		}
		if ((e.key === 'ArrowRight' || e.key === 'ArrowLeft') && !e.shiftKey) {
			const sel = window.getSelection();
			if (!sel || !sel.rangeCount || !sel.isCollapsed) return;
			const range = sel.getRangeAt(0);
			const node = range.startContainer,
				offset = range.startOffset;
			if (e.key === 'ArrowRight') {
				let next = null;
				if (node.nodeType === 3 && offset === node.length) next = node.nextSibling;
				else if (node.nodeType === 1 && offset < node.childNodes.length)
					next = node.childNodes[offset];
				if (next && next.nodeType === 1 && next.classList.contains('token-chip')) {
					e.preventDefault();
					const nr = document.createRange();
					nr.setStartAfter(next);
					nr.collapse(true);
					sel.removeAllRanges();
					sel.addRange(nr);
				}
			} else {
				let prev = null;
				if (node.nodeType === 3 && offset === 0) prev = node.previousSibling;
				else if (node.nodeType === 1 && offset > 0) prev = node.childNodes[offset - 1];
				if (prev && prev.nodeType === 1 && prev.classList.contains('token-chip')) {
					e.preventDefault();
					const nr = document.createRange();
					nr.setStartBefore(prev);
					nr.collapse(true);
					sel.removeAllRanges();
					sel.addRange(nr);
				}
			}
		}
	});

	te.addEventListener('input', function () {
		const sel = window.getSelection();
		if (!sel || !sel.rangeCount) return;
		const range = sel.getRangeAt(0);
		if (!range.collapsed) return;
		const node = range.startContainer;
		if (node.nodeType !== 3) return;
		const text = node.textContent;
		const idx = text.indexOf(TRIGGER_CHAR);
		if (idx < 0) return;
		const before = text.slice(0, idx);
		const after = text.slice(idx + TRIGGER_CHAR.length);
		node.textContent = before;
		const chip = makeTrigChip();
		const afterNode = document.createTextNode(after);
		const refNode = node.nextSibling;
		if (refNode) {
			node.parentNode.insertBefore(chip, refNode);
			node.parentNode.insertBefore(afterNode, chip.nextSibling);
		} else {
			node.parentNode.appendChild(chip);
			node.parentNode.appendChild(afterNode);
		}
		const nr = document.createRange();
		nr.setStart(afterNode, 0);
		nr.collapse(true);
		sel.removeAllRanges();
		sel.addRange(nr);
	});

	te.addEventListener('paste', function (e) {
		e.preventDefault();
		const text = (e.clipboardData || window.clipboardData).getData('text/plain');
		if (!text) return;
		const sel = window.getSelection();
		if (!sel || !sel.rangeCount) {
			te.appendChild(document.createTextNode(text));
			return;
		}
		const r = sel.getRangeAt(0);
		r.deleteContents();
		const frag = document.createDocumentFragment();
		const parts = text.split(TRIGGER_CHAR);
		parts.forEach((part, i) => {
			if (part) frag.appendChild(document.createTextNode(part));
			if (i < parts.length - 1) frag.appendChild(makeTrigChip());
		});
		r.insertNode(frag);
		r.collapse(false);
		sel.removeAllRanges();
		sel.addRange(r);
	});
})();

// Output Editor logic
(function () {
	const ed = document.getElementById('e-out');

	ed.addEventListener('input', () => clearFieldError('e-out', 'out-err'));

	ed.addEventListener('keydown', function (e) {
		if (acItems.length > 0) {
			if (e.key === 'Tab') {
				e.preventDefault();
				applyAc(acItems[acIdx]);
				return;
			}
			if (e.key === 'ArrowDown' || e.key === 'ArrowRight') {
				e.preventDefault();
				acIdx = (acIdx + 1) % acItems.length;
				updateAcSel();
				return;
			}
			if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') {
				e.preventDefault();
				acIdx = (acIdx - 1 + acItems.length) % acItems.length;
				updateAcSel();
				return;
			}
			if (e.key === 'Enter' && !(e.metaKey || e.ctrlKey)) {
				e.preventDefault();
				applyAc(acItems[acIdx]);
				return;
			}
			if (e.key === 'Escape') {
				e.preventDefault();
				hideAc();
				return;
			}
		} else if (e.key === 'Tab') {
			// Focus on the main validate button in the entry modal
			e.preventDefault();
			var entryModal = document.getElementById('entry-modal');
			if (entryModal) {
				var btns = entryModal.querySelectorAll('.btn.btn-p');
				if (btns.length > 0) btns[0].focus();
			}
			return;
		}

		if (e.key === 'Enter' && e.shiftKey && (e.metaKey || e.ctrlKey)) {
			e.preventDefault();
			saveEntry(true);
			return;
		}
		if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
			e.preventDefault();
			saveEntry(false);
			return;
		}
		if (e.key === 'Enter') {
			e.preventDefault();
			insertBrAtCursor();
			return;
		}

		if (e.key === 'Backspace') {
			const sel = window.getSelection();
			if (!sel || !sel.rangeCount) return;
			const range = sel.getRangeAt(0);
			if (!range.collapsed) return;
			const node = range.startContainer,
				offset = range.startOffset;
			let chip = null;
			if (node === ed && offset > 0) {
				const p = ed.childNodes[offset - 1];
				if (p && p.nodeType === 1 && p.classList.contains('token-chip')) chip = p;
			} else if (node.nodeType === 3 && offset === 0 && node.previousSibling) {
				const p = node.previousSibling;
				if (p && p.nodeType === 1 && p.classList.contains('token-chip')) chip = p;
			}
			if (chip) {
				e.preventDefault();
				chip.parentNode.removeChild(chip);
				checkPh();
				return;
			}
		}

		if ((e.key === 'ArrowRight' || e.key === 'ArrowLeft') && !e.shiftKey) {
			const sel = window.getSelection();
			if (!sel || !sel.rangeCount || !sel.isCollapsed) return;
			const range = sel.getRangeAt(0);
			const node = range.startContainer,
				offset = range.startOffset;
			if (e.key === 'ArrowRight') {
				let next = null;
				if (node.nodeType === 3 && offset === node.length) next = node.nextSibling;
				else if (node.nodeType === 1 && offset < node.childNodes.length)
					next = node.childNodes[offset];
				if (next && next.nodeType === 1 && next.classList.contains('token-chip')) {
					e.preventDefault();
					const nr = document.createRange();
					nr.setStartAfter(next);
					nr.collapse(true);
					sel.removeAllRanges();
					sel.addRange(nr);
				}
			} else {
				let prev = null;
				if (node.nodeType === 3 && offset === 0) prev = node.previousSibling;
				else if (node.nodeType === 1 && offset > 0) prev = node.childNodes[offset - 1];
				if (prev && prev.nodeType === 1 && prev.classList.contains('token-chip')) {
					e.preventDefault();
					const nr = document.createRange();
					nr.setStartBefore(prev);
					nr.collapse(true);
					sel.removeAllRanges();
					sel.addRange(nr);
				}
			}
		}
	});

	ed.addEventListener('input', function () {
		tryConvertToken(ed);
		checkAc();
		checkPh();
	});

	ed.addEventListener('keyup', function (e) {
		if (
			acItems.length > 0 &&
			['Tab', 'ArrowDown', 'ArrowUp', 'ArrowLeft', 'ArrowRight', 'Escape', 'Enter'].indexOf(
				e.key
			) >= 0
		)
			return;
		if (e.key === '}') tryConvertToken(ed);
		checkAc();
		checkPh();
	});

	ed.addEventListener('blur', hideAc);

	ed.addEventListener('paste', function (e) {
		e.preventDefault();
		const text = (e.clipboardData || window.clipboardData).getData('text/plain');
		if (!text) return;
		const sel = window.getSelection();
		if (!sel || !sel.rangeCount) {
			ed.appendChild(document.createTextNode(text));
			checkPh();
			return;
		}
		const r = sel.getRangeAt(0);
		r.deleteContents();
		const frag = document.createDocumentFragment();
		parseToNodes(text).forEach((n) => frag.appendChild(n));
		r.insertNode(frag);
		r.collapse(false);
		sel.removeAllRanges();
		sel.addRange(r);
		checkPh();
	});
})();

document.addEventListener('click', function (e) {
	if (!document.getElementById('ac-popup').contains(e.target)) hideAc();
});

document.addEventListener('DOMContentLoaded', function () {
	toLua('ready', {});
});
