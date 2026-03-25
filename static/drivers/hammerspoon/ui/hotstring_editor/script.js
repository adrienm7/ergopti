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

// ── Globals ───────────────────────────────────────────────────────────────────
var D = null,
	TRIGGER_CHAR = '★',
	STAR = '★';
var edSec = null,
	edEntry = null,
	dragSrcIdx = null;
var compactView = false,
	autoClose = false,
	defaultSec = null,
	openMode = 'menu';

// ── Token definitions ─────────────────────────────────────────────────────────
var TOKEN_NORM = {
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
var TOKEN_NAMES = [
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

var CMD_GROUPS = [
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

function normToken(name) {
	var c = TOKEN_NORM[name.toLowerCase()];
	if (c) return c;
	return name.charAt(0).toUpperCase() + name.slice(1);
}

// ── Lua bridge ────────────────────────────────────────────────────────────────
function toLua(action, data) {
	try {
		window.webkit.messageHandlers.hsEditor.postMessage({ action: action, data: data || {} });
	} catch (e) {
		console.error('[hsEditor]', e);
	}
}

// ── Dynamic Descriptions ──────────────────────────────────────────────────────
function updateCbDescs() {
	var w = document.getElementById('cb-word').checked;
	var a = document.getElementById('cb-auto').checked;
	var c = document.getElementById('cb-case').checked;
	var f = document.getElementById('cb-final').checked;

	document.getElementById('desc-word').innerHTML = w
		? 'Ne se déclenche que si c’est un mot complet.<br>Ex : <em>tel</em>→téléphone mais pas <em>hôtel</em>'
		: 'S’active partout, même comme sous-chaîne.<br>Ex : s’activera à l’intérieur de <em>hôtel</em>';

	document.getElementById('desc-auto').innerHTML = a
		? 'S’expand immédiatement (idéal pour les déclencheurs finissant par ' +
			esc(TRIGGER_CHAR) +
			').'
		: 'Nécessite de taper Espace/Entrée (conseillé pour l’autocorrection).';

	document.getElementById('desc-case').innerHTML = c
		? 'Différencie strictement majuscules/minuscules.<br>Ex : <em>Btw</em> ≠ <em>btw</em>'
		: 'Le moteur générera les versions minuscule, Titlecase et MAJUSCULE.';

	document.getElementById('desc-final').innerHTML = f
		? 'Le résultat ne sera pas re-analysé comme déclencheur.'
		: 'Le résultat pourra déclencher d’autres hotstrings en cascade.';
}

// ── Field validation helpers ──────────────────────────────────────────────────
function setFieldError(fieldId, errId, msg) {
	var field = document.getElementById(fieldId);
	var err = document.getElementById(errId);
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
	var field = document.getElementById(fieldId);
	var err = document.getElementById(errId);
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

// ── Dialogs ───────────────────────────────────────────────────────────────────
function showAlert(msg) {
	document.getElementById('msg-text').textContent = msg;
	openModal('msg-modal');
}

var _confirmCb = null;
function showConfirm(msg, fn, opts) {
	opts = opts || {};
	var titleHtml = '';
	if (opts.isWarning) {
		titleHtml =
			'<div style="display:flex;align-items:center;gap:8px;color:var(--warning);font-weight:600;font-size:15px;margin-bottom:10px;"><span style="font-size:20px;">⚠️</span> Attention</div>';
	}
	document.getElementById('confirm-text').innerHTML =
		titleHtml +
		'<div style="font-size:13px;line-height:1.5;margin-bottom:16px;color:var(--text);">' +
		msg +
		'</div>';
	var okBtn = document.getElementById('confirm-ok');
	okBtn.textContent = opts.okLabel || 'Supprimer';
	okBtn.style.background = opts.okColor || 'var(--danger)';
	_confirmCb = fn;
	openModal('confirm-modal');
}
document.getElementById('confirm-ok').addEventListener('click', function () {
	closeModal('confirm-modal');
	if (_confirmCb) {
		var f = _confirmCb;
		_confirmCb = null;
		f();
	}
});
document.getElementById('confirm-cancel').addEventListener('click', function () {
	_confirmCb = null;
	closeModal('confirm-modal');
});

// ── Init ──────────────────────────────────────────────────────────────────────
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
		var si = D.sections.findIndex(function (s) {
			return s.name === defaultSec;
		});
		if (si >= 0)
			setTimeout(function () {
				showAddEntry(si);
			}, 300);
	}
};
window.updateData = function (d) {
	if (D && D.sections && d && d.sections) {
		var m = {};
		D.sections.forEach(function (s) {
			m[s.name] = s._exp;
		});
		d.sections.forEach(function (s) {
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

function buildCmdGrid() {
	var b = document.getElementById('cmd-block');
	b.innerHTML = '';
	CMD_GROUPS.forEach(function (g, gi) {
		if (gi > 0) {
			var s = document.createElement('hr');
			s.className = 'cmd-sep';
			b.appendChild(s);
		}
		var l = document.createElement('div');
		l.className = 'cmd-grp-lbl';
		l.textContent = g.lbl;
		b.appendChild(l);
		g.cmds.forEach(function (c) {
			var el = document.createElement('div');
			el.className = 'cmd-ref';
			el.title = '{' + c.token + '} — ' + c.desc;
			el.innerHTML =
				'<span class="cmd-sym">' +
				esc(c.sym) +
				'</span><span class="cmd-lbl">' +
				esc(c.desc) +
				'</span>';
			el.addEventListener('mousedown', function (e) {
				e.preventDefault();
			});
			el.addEventListener('click', function () {
				insertChipAtCursor(c.token);
			});
			b.appendChild(el);
		});
	});
}

function updateHints() {
	var hint = document.getElementById('trig-hint');
	if (hint) {
		if (TRIGGER_CHAR !== STAR)
			hint.innerHTML =
				'<span class="star-badge">' +
				esc(TRIGGER_CHAR) +
				'</span> affiché, stocké en <span class="star-badge">' +
				esc(STAR) +
				'</span>';
		else hint.textContent = '';
	}
	var mb = document.getElementById('magic-btn');
	if (mb) mb.textContent = TRIGGER_CHAR;
}
function updateCompactBtn() {
	var b = document.getElementById('compact-btn');
	if (b) b.textContent = compactView ? 'Vue développée' : 'Vue compacte';
}
function toggleCompact() {
	compactView = !compactView;
	updateCompactBtn();
	render();
	toLua('save_pref', { key: 'compact_view', value: compactView });
}

// ── ★ normalization ───────────────────────────────────────────────────────────
function toDisplay(s) {
	if (!s || TRIGGER_CHAR === STAR) return s || '';
	return String(s).split(STAR).join(TRIGGER_CHAR);
}
function toCanonical(s) {
	if (!s || TRIGGER_CHAR === STAR) return s || '';
	return String(s).replace(
		new RegExp(TRIGGER_CHAR.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'),
		STAR
	);
}

// ── Output chip factory ───────────────────────────────────────────────────────
function makeChip(name) {
	var s = document.createElement('span');
	s.className = 'token-chip';
	s.contentEditable = 'false';
	s.dataset.token = name;
	s.textContent = name;
	return s;
}

// ── Trig chip factory ─────────────────────────────────────────────────────────
function makeTrigChip() {
	var s = document.createElement('span');
	s.className = 'token-chip';
	s.contentEditable = 'false';
	s.dataset.trigChar = 'true';
	s.textContent = TRIGGER_CHAR;
	return s;
}
function setTrigContent(el, text) {
	el.innerHTML = '';
	if (!text) return;
	var display = toDisplay(text);
	var parts = display.split(TRIGGER_CHAR);
	parts.forEach(function (part, i) {
		if (part) el.appendChild(document.createTextNode(part));
		if (i < parts.length - 1) el.appendChild(makeTrigChip());
	});
}
function serializeTrigEditor(el) {
	var s = '';
	el.childNodes.forEach(function (n) {
		if (n.nodeType === 3) s += toCanonical(n.textContent);
		else if (n.nodeType === 1 && n.dataset && n.dataset.trigChar) s += STAR;
		else s += toCanonical(n.textContent || '');
	});
	return s.trim();
}

// ── Fake Placeholder ─────────────────────────────────────────────────────────
function checkPh() {
	var ed = document.getElementById('e-out');
	var ph = document.getElementById('e-out-ph');
	ph.style.display =
		ed.textContent.length === 0 && ed.innerHTML.indexOf('<span') === -1 ? 'block' : 'none';
}

// ── Parse canonical output string → DOM nodes ─────────────────────────────────
function parseToNodes(text) {
	if (!text) return [document.createTextNode('')];
	text = toDisplay(text);
	var nodes = [],
		re = /\{([^}]+)\}/g,
		last = 0,
		m;
	while ((m = re.exec(text)) !== null) {
		if (m.index > last) nodes.push(document.createTextNode(text.slice(last, m.index)));
		var tname = normToken(m[1]);
		if (tname === 'Enter') nodes.push(document.createElement('br'));
		else nodes.push(makeChip(tname));
		last = re.lastIndex;
	}
	if (last < text.length) nodes.push(document.createTextNode(text.slice(last)));
	return nodes;
}

// ── Serialize output editor DOM → canonical string ────────────────────────────
function serializeEditor(el) {
	var nodes = Array.from(el.childNodes);
	while (nodes.length > 0) {
		var last = nodes[nodes.length - 1];
		if (last.nodeType === 1 && last.tagName === 'BR' && !last.classList.contains('token-chip'))
			nodes.pop();
		else break;
	}
	var s = '';
	nodes.forEach(function (n) {
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
	parseToNodes(text || '').forEach(function (n) {
		el.appendChild(n);
	});
	checkPh();
}

// ── Insert helpers (output editor) ────────────────────────────────────────────
function insertBrAtCursor() {
	var ed = document.getElementById('e-out');
	ed.focus();
	var sel = window.getSelection();
	var br = document.createElement('br');
	if (sel && sel.rangeCount) {
		var r = sel.getRangeAt(0);
		if (ed.contains(r.commonAncestorContainer)) {
			r.deleteContents();
			r.insertNode(br);
			if (!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));
			var nr = document.createRange();
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
	var ed = document.getElementById('e-out');
	ed.focus();
	var chip = makeChip(normToken(name));
	var sel = window.getSelection();
	if (sel && sel.rangeCount) {
		var r = sel.getRangeAt(0);
		if (ed.contains(r.commonAncestorContainer)) {
			r.deleteContents();
			r.insertNode(chip);
			var nr = document.createRange();
			nr.setStartAfter(chip);
			nr.collapse(true);
			sel.removeAllRanges();
			sel.addRange(nr);
			checkPh();
			return;
		}
	}
	ed.appendChild(chip);
	var nr = document.createRange();
	nr.setStartAfter(chip);
	nr.collapse(true);
	sel = window.getSelection();
	if (sel) {
		sel.removeAllRanges();
		sel.addRange(nr);
	}
	checkPh();
}

// ── Insert magic key into trig editor ────────────────────────────────────────
function insertMagicKey() {
	var te = document.getElementById('e-trig');
	te.focus();
	var chip = makeTrigChip();
	var sel = window.getSelection();
	if (sel && sel.rangeCount) {
		var r = sel.getRangeAt(0);
		if (te.contains(r.commonAncestorContainer)) {
			r.deleteContents();
			r.insertNode(chip);
			var nr = document.createRange();
			nr.setStartAfter(chip);
			nr.collapse(true);
			sel.removeAllRanges();
			sel.addRange(nr);
			return;
		}
	}
	te.appendChild(chip);
	var nr = document.createRange();
	nr.setStartAfter(chip);
	nr.collapse(true);
	sel = window.getSelection();
	if (sel) {
		sel.removeAllRanges();
		sel.addRange(nr);
	}
}

// ── Auto-convert {token} in output editor when } is typed ─────────────────────
function tryConvertToken(editor) {
	var sel = window.getSelection();
	if (!sel || !sel.rangeCount) return;
	var range = sel.getRangeAt(0);
	if (!range.collapsed) return;
	var node = range.startContainer;
	if (node.nodeType !== 3) return;
	var offset = range.startOffset;
	var before = node.textContent.slice(0, offset);
	var m = before.match(/\{(\w+)\}$/);
	if (!m) return;
	var tokenName = normToken(m[1]);
	if (TOKEN_NAMES.indexOf(tokenName) < 0) return;
	var matchStart = offset - m[0].length;
	var r = document.createRange();
	r.setStart(node, matchStart);
	r.setEnd(node, offset);
	r.deleteContents();
	if (tokenName === 'Enter') {
		var anch = sel.getRangeAt(0);
		var br = document.createElement('br');
		anch.insertNode(br);
		if (!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));
		var nr = document.createRange();
		nr.setStartAfter(br);
		nr.collapse(true);
		sel.removeAllRanges();
		sel.addRange(nr);
		checkPh();
		return;
	}
	var chip = makeChip(tokenName);
	var anch = sel.getRangeAt(0);
	anch.insertNode(chip);
	var nr = document.createRange();
	nr.setStartAfter(chip);
	nr.collapse(true);
	sel.removeAllRanges();
	sel.addRange(nr);
	checkPh();
}

// ── Cursor ejector ────────────────────────────────────────────────────────────
var _ejecting = false;
function ejectFromChip() {
	if (_ejecting) return;
	var sel = window.getSelection();
	if (!sel || !sel.rangeCount || !sel.isCollapsed) return;
	var range = sel.getRangeAt(0);
	var node = range.startContainer;
	var el = node.nodeType === 3 ? node.parentElement : node;
	if (el && el.classList && el.classList.contains('token-chip')) {
		_ejecting = true;
		var nr = document.createRange();
		nr.setStartAfter(el);
		nr.collapse(true);
		sel.removeAllRanges();
		sel.addRange(nr);
		_ejecting = false;
	}
}
document.addEventListener('selectionchange', ejectFromChip);

// ── Autocomplete ──────────────────────────────────────────────────────────────
var acItems = [],
	acIdx = 0;
function getAcCtx() {
	var sel = window.getSelection();
	if (!sel || !sel.rangeCount) return null;
	var r = sel.getRangeAt(0);
	if (!r.collapsed) return null;
	var n = r.startContainer;
	if (n.nodeType !== 3) return null;
	var text = n.textContent.slice(0, r.startOffset);
	var m = text.match(/\{(\w*)$/);
	if (!m) return null;
	return { partial: m[1].toLowerCase(), start: r.startOffset - m[0].length, node: n };
}
function showAc(matches) {
	var popup = document.getElementById('ac-popup');
	acItems = matches;
	acIdx = 0;
	popup.innerHTML = '';
	var sel = window.getSelection();
	if (!sel || !sel.rangeCount) {
		hideAc();
		return;
	}
	var rect = sel.getRangeAt(0).getBoundingClientRect();
	matches.forEach(function (name, i) {
		var d = document.createElement('div');
		d.className = 'ac-item' + (i === 0 ? ' active' : '');
		d.textContent = name;
		d.addEventListener('mousedown', function (e) {
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
	document.querySelectorAll('.ac-item').forEach(function (el, i) {
		el.classList.toggle('active', i === acIdx);
	});
}
function applyAc(name) {
	hideAc();
	var ctx = getAcCtx();
	if (!ctx) {
		insertChipAtCursor(name);
		return;
	}
	var r = document.createRange();
	r.setStart(ctx.node, ctx.start);
	r.setEnd(ctx.node, ctx.start + ctx.partial.length + 1);
	r.deleteContents();
	if (normToken(name) === 'Enter') {
		var sel2 = window.getSelection();
		var anch = sel2.getRangeAt(0);
		var br = document.createElement('br');
		anch.insertNode(br);
		if (!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));
		var nr = document.createRange();
		nr.setStartAfter(br);
		nr.collapse(true);
		sel2.removeAllRanges();
		sel2.addRange(nr);
		checkPh();
		return;
	}
	var chip = makeChip(normToken(name));
	var sel3 = window.getSelection();
	var anch2 = sel3.getRangeAt(0);
	anch2.insertNode(chip);
	var nr2 = document.createRange();
	nr2.setStartAfter(chip);
	nr2.collapse(true);
	sel3.removeAllRanges();
	sel3.addRange(nr2);
	checkPh();
}
function checkAc() {
	var ctx = getAcCtx();
	if (!ctx) {
		hideAc();
		return;
	}
	var matches = TOKEN_NAMES.filter(function (n) {
		return n.toLowerCase().startsWith(ctx.partial);
	});
	if (matches.length === 0) {
		hideAc();
		return;
	}
	showAc(matches);
}
document.addEventListener('click', function (e) {
	if (!document.getElementById('ac-popup').contains(e.target)) hideAc();
});

// ── Output editor event wiring ────────────────────────────────────────────────
(function () {
	var ed = document.getElementById('e-out');

	ed.addEventListener('input', function () {
		clearFieldError('e-out', 'out-err');
	});

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
			var sel = window.getSelection();
			if (!sel || !sel.rangeCount) return;
			var range = sel.getRangeAt(0);
			if (!range.collapsed) return;
			var node = range.startContainer,
				offset = range.startOffset;
			var chip = null;
			if (node === ed && offset > 0) {
				var p = ed.childNodes[offset - 1];
				if (p && p.nodeType === 1 && p.classList.contains('token-chip')) chip = p;
			} else if (node.nodeType === 3 && offset === 0 && node.previousSibling) {
				var p = node.previousSibling;
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
			var sel = window.getSelection();
			if (!sel || !sel.rangeCount || !sel.isCollapsed) return;
			var range = sel.getRangeAt(0);
			var node = range.startContainer,
				offset = range.startOffset;
			if (e.key === 'ArrowRight') {
				var next = null;
				if (node.nodeType === 3 && offset === node.length) next = node.nextSibling;
				else if (node.nodeType === 1 && offset < node.childNodes.length)
					next = node.childNodes[offset];
				if (next && next.nodeType === 1 && next.classList.contains('token-chip')) {
					e.preventDefault();
					var nr = document.createRange();
					nr.setStartAfter(next);
					nr.collapse(true);
					sel.removeAllRanges();
					sel.addRange(nr);
				}
			} else {
				var prev = null;
				if (node.nodeType === 3 && offset === 0) prev = node.previousSibling;
				else if (node.nodeType === 1 && offset > 0) prev = node.childNodes[offset - 1];
				if (prev && prev.nodeType === 1 && prev.classList.contains('token-chip')) {
					e.preventDefault();
					var nr = document.createRange();
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
		var text = (e.clipboardData || window.clipboardData).getData('text/plain');
		if (!text) return;
		var sel = window.getSelection();
		if (!sel || !sel.rangeCount) {
			ed.appendChild(document.createTextNode(text));
			checkPh();
			return;
		}
		var r = sel.getRangeAt(0);
		r.deleteContents();
		var frag = document.createDocumentFragment();
		parseToNodes(text).forEach(function (n) {
			frag.appendChild(n);
		});
		r.insertNode(frag);
		r.collapse(false);
		sel.removeAllRanges();
		sel.addRange(r);
		checkPh();
	});
})();

// ── Trig editor event wiring ──────────────────────────────────────────────────
(function () {
	var te = document.getElementById('e-trig');

	te.addEventListener('input', function () {
		clearFieldError('e-trig', 'trig-err');
	});

	te.addEventListener('keydown', function (e) {
		if (e.key === 'Enter') {
			e.preventDefault();
			document.getElementById('e-out').focus();
			return;
		}
		if (e.key === 'Tab') {
			e.preventDefault();
			document.getElementById('e-out').focus();
			return;
		}

		if (e.key === 'Backspace') {
			var sel = window.getSelection();
			if (!sel || !sel.rangeCount) return;
			var range = sel.getRangeAt(0);
			if (!range.collapsed) return;
			var node = range.startContainer,
				offset = range.startOffset;
			var chip = null;
			if (node === te && offset > 0) {
				var p = te.childNodes[offset - 1];
				if (p && p.nodeType === 1 && p.classList.contains('token-chip')) chip = p;
			} else if (node.nodeType === 3 && offset === 0 && node.previousSibling) {
				var p = node.previousSibling;
				if (p && p.nodeType === 1 && p.classList.contains('token-chip')) chip = p;
			}
			if (chip) {
				e.preventDefault();
				chip.parentNode.removeChild(chip);
				return;
			}
		}

		if ((e.key === 'ArrowRight' || e.key === 'ArrowLeft') && !e.shiftKey) {
			var sel = window.getSelection();
			if (!sel || !sel.rangeCount || !sel.isCollapsed) return;
			var range = sel.getRangeAt(0);
			var node = range.startContainer,
				offset = range.startOffset;
			if (e.key === 'ArrowRight') {
				var next = null;
				if (node.nodeType === 3 && offset === node.length) next = node.nextSibling;
				else if (node.nodeType === 1 && offset < node.childNodes.length)
					next = node.childNodes[offset];
				if (next && next.nodeType === 1 && next.classList.contains('token-chip')) {
					e.preventDefault();
					var nr = document.createRange();
					nr.setStartAfter(next);
					nr.collapse(true);
					sel.removeAllRanges();
					sel.addRange(nr);
				}
			} else {
				var prev = null;
				if (node.nodeType === 3 && offset === 0) prev = node.previousSibling;
				else if (node.nodeType === 1 && offset > 0) prev = node.childNodes[offset - 1];
				if (prev && prev.nodeType === 1 && prev.classList.contains('token-chip')) {
					e.preventDefault();
					var nr = document.createRange();
					nr.setStartBefore(prev);
					nr.collapse(true);
					sel.removeAllRanges();
					sel.addRange(nr);
				}
			}
		}
	});

	te.addEventListener('input', function () {
		var sel = window.getSelection();
		if (!sel || !sel.rangeCount) return;
		var range = sel.getRangeAt(0);
		if (!range.collapsed) return;
		var node = range.startContainer;
		if (node.nodeType !== 3) return;
		var text = node.textContent;
		var idx = text.indexOf(TRIGGER_CHAR);
		if (idx < 0) return;
		var before = text.slice(0, idx);
		var after = text.slice(idx + TRIGGER_CHAR.length);
		node.textContent = before;
		var chip = makeTrigChip();
		var afterNode = document.createTextNode(after);
		var refNode = node.nextSibling;
		if (refNode) {
			node.parentNode.insertBefore(chip, refNode);
			node.parentNode.insertBefore(afterNode, chip.nextSibling);
		} else {
			node.parentNode.appendChild(chip);
			node.parentNode.appendChild(afterNode);
		}
		var nr = document.createRange();
		nr.setStart(afterNode, 0);
		nr.collapse(true);
		sel.removeAllRanges();
		sel.addRange(nr);
	});

	te.addEventListener('paste', function (e) {
		e.preventDefault();
		var text = (e.clipboardData || window.clipboardData).getData('text/plain');
		if (!text) return;
		var sel = window.getSelection();
		if (!sel || !sel.rangeCount) {
			te.appendChild(document.createTextNode(text));
			return;
		}
		var r = sel.getRangeAt(0);
		r.deleteContents();
		var frag = document.createDocumentFragment();
		var parts = text.split(TRIGGER_CHAR);
		parts.forEach(function (part, i) {
			if (part) frag.appendChild(document.createTextNode(part));
			if (i < parts.length - 1) frag.appendChild(makeTrigChip());
		});
		r.insertNode(frag);
		r.collapse(false);
		sel.removeAllRanges();
		sel.addRange(r);
	});
})();

// ── Bulk actions ──────────────────────────────────────────────────────────────
window.updateBulk = function () {
	var cbs = document.querySelectorAll('.entry-cb:checked');
	var bar = document.getElementById('bulk-bar');
	if (cbs.length > 0) {
		var cnt = cbs.length;
		document.getElementById('bulk-cnt').textContent = cnt + ' sélectionné' + (cnt > 1 ? 's' : '');
		var sel = document.getElementById('bulk-sec-sel');
		sel.innerHTML = '<option value="">Déplacer vers…</option>';
		D.sections.forEach(function (s, idx) {
			sel.innerHTML += '<option value="' + idx + '">' + esc(s.description || s.name) + '</option>';
		});
		bar.style.display = 'flex';
	} else {
		bar.style.display = 'none';
	}
};
window.clearBulk = function () {
	document.querySelectorAll('.entry-cb').forEach(function (cb) {
		cb.checked = false;
	});
	updateBulk();
};
window.bulkDel = function () {
	var cnt = document.querySelectorAll('.entry-cb:checked').length;
	showConfirm(
		'Supprimer les ' +
			cnt +
			' élément' +
			(cnt > 1 ? 's' : '') +
			' sélectionné' +
			(cnt > 1 ? 's' : '') +
			' ?',
		function () {
			var cbs = Array.from(document.querySelectorAll('.entry-cb:checked'));
			var toDel = cbs.map(function (cb) {
				return { si: parseInt(cb.dataset.si), ei: parseInt(cb.dataset.ei) };
			});
			toDel.sort(function (a, b) {
				return a.si !== b.si ? b.si - a.si : b.ei - a.ei;
			});
			toDel.forEach(function (item) {
				D.sections[item.si].entries.splice(item.ei, 1);
			});
			clearBulk();
			persist();
		}
	);
};
window.bulkMove = function () {
	var sel = document.getElementById('bulk-sec-sel');
	var destSi = parseInt(sel.value);
	if (isNaN(destSi)) return;
	var cbs = Array.from(document.querySelectorAll('.entry-cb:checked'));
	var toMove = cbs.map(function (cb) {
		return { si: parseInt(cb.dataset.si), ei: parseInt(cb.dataset.ei) };
	});
	toMove.sort(function (a, b) {
		return a.si !== b.si ? b.si - a.si : b.ei - a.ei;
	});
	toMove.forEach(function (item) {
		var entry = D.sections[item.si].entries.splice(item.ei, 1)[0];
		D.sections[destSi].entries.push(entry);
	});
	D.sections[destSi].entries.sort(function (a, b) {
		var ta = (a.trigger || '').toLowerCase().replace(/[^\w]/g, '');
		var tb = (b.trigger || '').toLowerCase().replace(/[^\w]/g, '');
		return ta < tb ? -1 : ta > tb ? 1 : 0;
	});
	sel.value = '';
	clearBulk();
	persist();
};

// ── Render ────────────────────────────────────────────────────────────────────
function esc(s) {
	return String(s || '')
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

function dispTrig(s) {
	if (!s) return '';
	var d = esc(toDisplay(s));
	return d
		.split(esc(TRIGGER_CHAR))
		.join('<span class="trig-star">' + esc(TRIGGER_CHAR) + '</span>');
}

function dispOutput(s) {
	if (!s) return '';
	var out = esc(toDisplay(s));
	out = out.replace(/\{([^}]+)\}/g, function (_, name) {
		var canon = normToken(name);
		return '<span class="tc" data-tok="' + esc(canon) + '">' + esc(canon) + '</span>';
	});
	if (!compactView) {
		out = out.replace(/<span class="tc" data-tok="Enter">Enter<\/span>/g, '<br>');
	}
	return out;
}

var _rowMouseDownX = 0,
	_rowMouseDownY = 0;
function onRowMouseDown(e) {
	_rowMouseDownX = e.clientX;
	_rowMouseDownY = e.clientY;
}

function handleSecTitleClick(e, si) {
	var dx = e.clientX - _rowMouseDownX,
		dy = e.clientY - _rowMouseDownY;
	if (Math.sqrt(dx * dx + dy * dy) > 4) return;
	var sel = window.getSelection();
	if (sel && sel.toString().length > 0) return;
	showEditSec(si);
}

function render() {
	var cont = document.getElementById('secs-container');
	var empty = document.getElementById('empty');
	if (!D || !D.sections || !D.sections.length) {
		cont.innerHTML = '';
		empty.style.display = 'block';
		return;
	}
	empty.style.display = 'none';
	var html = '';
	D.sections.forEach(function (s, si) {
		var cnt = s.entries ? s.entries.length : 0;
		var exp = s._exp !== false;
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
			(s.entries || []).forEach(function (e, ei) {
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

	D.sections.forEach(function (_, si) {
		var handle = document.getElementById('dh-' + si);
		var card = document.getElementById('sc-' + si);
		if (!handle || !card) return;
		handle.addEventListener('mousedown', function () {
			card.draggable = true;
		});
		card.addEventListener('dragstart', function (e) {
			onDragStart(e, si);
		});
		card.addEventListener('dragover', function (e) {
			onDragOver(e, si);
		});
		card.addEventListener('drop', function (e) {
			onDrop(e, si);
		});
		card.addEventListener('dragend', function () {
			onDragEnd();
		});
	});
}

function handleRowClick(e, si, ei) {
	var dx = e.clientX - _rowMouseDownX,
		dy = e.clientY - _rowMouseDownY;
	if (Math.sqrt(dx * dx + dy * dy) > 4) return;
	var sel = window.getSelection();
	if (sel && sel.toString().length > 0) return;
	var target = e.target,
		field = null;
	while (target && target !== e.currentTarget) {
		if (target.dataset && target.dataset.f) {
			field = target.dataset.f;
			break;
		}
		target = target.parentElement;
	}
	showEditEntry(si, ei, field);
}

// ── Drag & drop ───────────────────────────────────────────────────────────────
function onDragStart(e, si) {
	dragSrcIdx = si;
	e.dataTransfer.effectAllowed = 'move';
	e.dataTransfer.setData('text/plain', String(si));
	setTimeout(function () {
		var c = document.getElementById('sc-' + si);
		if (c) c.classList.add('dragging');
	}, 0);
}
function onDragOver(e, si) {
	e.preventDefault();
	e.dataTransfer.dropEffect = 'move';
	document.querySelectorAll('.sec-card').forEach(function (c, i) {
		c.classList.toggle('drag-over', i === si && i !== dragSrcIdx);
	});
}
function onDrop(e, si) {
	e.preventDefault();
	var c = document.getElementById('sc-' + si);
	if (c) c.draggable = false;
	if (dragSrcIdx === null || dragSrcIdx === si) {
		cleanDrag();
		return;
	}
	var moved = D.sections.splice(dragSrcIdx, 1)[0];
	D.sections.splice(si, 0, moved);
	dragSrcIdx = null;
	persist();
}
function onDragEnd() {
	document.querySelectorAll('.sec-card').forEach(function (c) {
		c.draggable = false;
	});
	cleanDrag();
}
function cleanDrag() {
	dragSrcIdx = null;
	document.querySelectorAll('.sec-card').forEach(function (c) {
		c.classList.remove('drag-over', 'dragging');
	});
}
function togSec(si) {
	if (D.sections[si]) {
		D.sections[si]._exp = D.sections[si]._exp === false;
		render();
	}
}

// ── Section CRUD ──────────────────────────────────────────────────────────────
function showAddSec() {
	edSec = null;
	document.getElementById('sec-modal-title').textContent = 'Nouvelle section';
	var idEl = document.getElementById('sec-id');
	idEl.value = '';
	idEl.disabled = false;
	document.getElementById('sec-desc').value = '';
	clearSecErrors();
	openModal('sec-modal');
	setTimeout(function () {
		idEl.focus();
	}, 80);
}
function showEditSec(si) {
	edSec = si;
	var s = D.sections[si];
	document.getElementById('sec-modal-title').textContent = 'Renommer la section';
	var idEl = document.getElementById('sec-id');
	idEl.value = s.name;
	idEl.disabled = true;
	document.getElementById('sec-desc').value = s.description || '';
	clearSecErrors();
	openModal('sec-modal');
	setTimeout(function () {
		document.getElementById('sec-desc').focus();
	}, 80);
}
document.getElementById('sec-id').addEventListener('input', function () {
	clearFieldError('sec-id', 'sec-id-err');
	var p = this.selectionStart;
	var c = this.value.toLowerCase().replace(/[^a-z0-9_]/g, '');
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
function saveSec() {
	var id = document.getElementById('sec-id').value.trim();
	var desc = document.getElementById('sec-desc').value.trim();
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
				'Identifiant invalide : uniquement minuscules, chiffres et underscores.'
			);
			document.getElementById('sec-id').focus();
			return;
		}
		if (
			D.sections.some(function (s) {
				return s.name === id;
			})
		) {
			setFieldError('sec-id', 'sec-id-err', '\u00ab ' + id + ' \u00bb existe déjà.');
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
	var s = D.sections[si];
	showConfirm(
		'Supprimer \u00ab ' + (s.description || s.name) + ' \u00bb et tous ses hotstrings ?',
		function () {
			D.sections.splice(si, 1);
			persist();
		}
	);
}

// ── Entry CRUD ────────────────────────────────────────────────────────────────
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
	var secName = D.sections[si].description || D.sections[si].name;
	document.getElementById('entry-modal-title').textContent =
		'Création d’un hotstring — Section «\xA0' + secName + '\xA0»';
	resetEntryForm();
	openModal('entry-modal');
	setTimeout(function () {
		document.getElementById('e-trig').focus();
	}, 80);
}
function showEditEntry(si, ei, focusField) {
	edEntry = { si: si, ei: ei };
	var e = D.sections[si].entries[ei];
	var secName = D.sections[si].description || D.sections[si].name;
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

	setTimeout(function () {
		var el = null;
		if (focusField === 'out') {
			el = document.getElementById('e-out');
		} else if (focusField === 'trig') {
			el = document.getElementById('e-trig');
		} else if (focusField && focusField.indexOf('cb-') === 0) {
			el = document.getElementById(focusField);
		} else {
			el = document.getElementById('e-trig');
		}

		if (el) {
			el.focus();
			if (
				el.isContentEditable &&
				typeof window.getSelection !== 'undefined' &&
				typeof document.createRange !== 'undefined'
			) {
				var range = document.createRange();
				range.selectNodeContents(el);
				range.collapse(false);
				var sel = window.getSelection();
				sel.removeAllRanges();
				sel.addRange(range);
			}
		}
	}, 80);
}

function saveEntry(andNew) {
	clearEntryErrors();
	var trig = serializeTrigEditor(document.getElementById('e-trig'));
	var out = serializeEditor(document.getElementById('e-out'));

	// Blocking: empty trigger
	if (!trig) {
		setFieldError('e-trig', 'trig-err', 'Le déclencheur est requis.');
		setTimeout(function () {
			document.getElementById('e-trig').focus();
		}, 0);
		return;
	}
	// Blocking: empty output
	if (!out.trim()) {
		setFieldError('e-out', 'out-err', 'Le remplacement est requis.');
		setTimeout(function () {
			document.getElementById('e-out').focus();
		}, 0);
		return;
	}

	// Non-blocking: duplicate trigger warning (uses confirm dialog)
	var dupSection = null;
	D.sections.forEach(function (s, si2) {
		(s.entries || []).forEach(function (e2, ei2) {
			if (dupSection) return;
			if (edEntry.ei !== null && edEntry.si === si2 && ei2 === edEntry.ei) return;
			if (e2.trigger === trig) dupSection = s.description || s.name;
		});
	});

	function doSave() {
		var entry = {
			trigger: trig,
			output: out,
			is_word: document.getElementById('cb-word').checked,
			auto_expand: document.getElementById('cb-auto').checked,
			is_case_sensitive: document.getElementById('cb-case').checked,
			final_result: document.getElementById('cb-final').checked
		};
		var si = edEntry.si;
		if (edEntry.ei === null) D.sections[si].entries.push(entry);
		else D.sections[si].entries[edEntry.ei] = entry;
		D.sections[si].entries.sort(function (a, b) {
			var ta = (a.trigger || '').toLowerCase().replace(/[^\w]/g, '');
			var tb = (b.trigger || '').toLowerCase().replace(/[^\w]/g, '');
			return ta < tb ? -1 : ta > tb ? 1 : 0;
		});
		persist();
		if (andNew) {
			edEntry = { si: si, ei: null };
			var secName = D.sections[si].description || D.sections[si].name;
			document.getElementById('entry-modal-title').textContent =
				'Création d’un hotstring — Section «\xA0' + secName + '\xA0»';
			resetEntryForm();
			setTimeout(function () {
				document.getElementById('e-trig').focus();
			}, 50);
			return;
		}
		// Auto-close only when opened via shortcut
		if (openMode === 'shortcut' && autoClose) {
			closeModal('entry-modal');
			toLua('close', {});
			return;
		}
		closeModal('entry-modal');
	}

	if (dupSection) {
		showConfirm(
			'Le déclencheur <strong>' +
				esc(toDisplay(trig)) +
				'</strong> existe déjà dans <em>' +
				esc(dupSection) +
				'</em>.<br><br>Voulez-vous vraiment le redéfinir ?',
			doSave,
			{ okLabel: 'Redéfinir', okColor: '#ff9500', isWarning: true }
		);
	} else {
		doSave();
	}
}

function delEntryStop(e, si, ei) {
	e.stopPropagation();
	delEntry(si, ei);
}
function delEntry(si, ei) {
	var trig = toDisplay(D.sections[si].entries[ei].trigger);
	showConfirm('Supprimer \u00ab ' + trig + ' \u00bb ?', function () {
		D.sections[si].entries.splice(ei, 1);
		persist();
	});
}

// ── Persist ───────────────────────────────────────────────────────────────────
function persist() {
	var payload = { sections_order: [], sections: {} };
	D.sections.forEach(function (s) {
		payload.sections_order.push(s.name);
		payload.sections[s.name] = {
			description: s.description,
			entries: (s.entries || []).map(function (e) {
				return {
					trigger: e.trigger,
					output: e.output,
					is_word: !!e.is_word,
					auto_expand: !!e.auto_expand,
					is_case_sensitive: !!e.is_case_sensitive,
					final_result: !!e.final_result
				};
			})
		};
	});
	toLua('save', payload);
	render();
	var t = document.getElementById('save-toast');
	t.classList.add('show');
	setTimeout(function () {
		t.classList.remove('show');
	}, 1400);
}

// ── Modal helpers ─────────────────────────────────────────────────────────────
function openModal(id) {
	document.getElementById(id).classList.add('on');
}
function closeModal(id) {
	document.getElementById(id).classList.remove('on');
	if (id === 'entry-modal') clearEntryErrors();
	if (id === 'sec-modal') clearSecErrors();
}
document.querySelectorAll('.overlay').forEach(function (el) {
	el.addEventListener('click', function (e) {
		if (e.target === el) closeModal(el.id);
	});
});
document.getElementById('msg-modal').addEventListener('keydown', function (e) {
	if (e.key === 'Enter' || e.key === 'Escape') closeModal('msg-modal');
});
document.getElementById('confirm-modal').addEventListener('keydown', function (e) {
	if (e.key === 'Escape') {
		_confirmCb = null;
		closeModal('confirm-modal');
	}
});
document.getElementById('sec-modal').addEventListener('keydown', function (e) {
	if (e.key === 'Enter') {
		e.preventDefault();
		saveSec();
	}
	if (e.key === 'Escape') closeModal('sec-modal');
});
document.getElementById('entry-modal').addEventListener('keydown', function (e) {
	if (e.key === 'Escape') {
		closeModal('entry-modal');
		return;
	}
});

document.addEventListener('DOMContentLoaded', function () {
	toLua('ready', {});
});
