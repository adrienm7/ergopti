// ── Chips Engine ──────────────────────────────────────────────────
function makeChip(name) {
	var s = document.createElement('span');
	s.className = 'token-chip';
	s.contentEditable = 'false';
	s.dataset.token = name;
	s.textContent = '{' + name + '}';
	return s;
}

function parseToNodes(text) {
	if (!text) return [document.createTextNode('')];
	var nodes = [];
	var normalized = text.replace(/\n/g, '{Enter}');
	var re = /\{([^}]+)\}/gi,
		last = 0,
		m;
	while ((m = re.exec(normalized)) !== null) {
		if (m.index > last) nodes.push(document.createTextNode(normalized.slice(last, m.index)));
		var tname = m[1].toLowerCase();
		if (tname === 'enter') {
			nodes.push(document.createElement('br'));
		} else if (tname === 'context') {
			nodes.push(makeChip('context'));
		} else {
			nodes.push(document.createTextNode(m[0]));
		}
		last = re.lastIndex;
	}
	if (last < normalized.length) nodes.push(document.createTextNode(normalized.slice(last)));
	return nodes;
}

function serializeEditor(el) {
	var nodes = Array.from(el.childNodes);
	while (nodes.length > 0) {
		var last = nodes[nodes.length - 1];
		if (last.nodeType === 1 && last.tagName === 'BR' && !last.classList.contains('token-chip')) {
			nodes.pop();
		} else break;
	}
	var s = '';
	nodes.forEach((n) => {
		if (n.nodeType === 3) s += n.textContent;
		else if (n.nodeType === 1 && n.classList.contains('token-chip'))
			s += '{' + n.dataset.token + '}';
		else if (n.nodeType === 1 && n.tagName === 'BR') s += '\n';
		else s += n.textContent || '';
	});
	return s;
}

function checkPh() {
	var ed = document.getElementById('e-out');
	var ph = document.getElementById('e-out-ph');
	ph.style.display =
		ed.textContent.length === 0 && ed.innerHTML.indexOf('<span') === -1 ? 'block' : 'none';
}

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
	var ed = document.getElementById('e-out');
	ed.focus();
	var chip = makeChip(name);
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
	var nr2 = document.createRange();
	nr2.setStartAfter(chip);
	nr2.collapse(true);
	sel = window.getSelection();
	if (sel) {
		sel.removeAllRanges();
		sel.addRange(nr2);
	}
	checkPh();
}

function tryConvertToken(editor) {
	var sel = window.getSelection();
	if (!sel || !sel.rangeCount) return;
	var range = sel.getRangeAt(0);
	if (!range.collapsed) return;
	var node = range.startContainer;
	if (node.nodeType !== 3) return;
	var offset = range.startOffset;
	var before = node.textContent.slice(0, offset);
	var m = before.match(/\{context\}$/i);
	if (!m) return;

	var matchStart = offset - m[0].length;
	var r = document.createRange();
	r.setStart(node, matchStart);
	r.setEnd(node, offset);
	r.deleteContents();

	var chip = makeChip('context');
	var anch = sel.getRangeAt(0);
	anch.insertNode(chip);
	var nr = document.createRange();
	nr.setStartAfter(chip);
	nr.collapse(true);
	sel.removeAllRanges();
	sel.addRange(nr);
	checkPh();
}

// ── Events Wiring ─────────────────────────────────────────────────
var ed = document.getElementById('e-out');
ed.addEventListener('input', function () {
	tryConvertToken(ed);
	checkPh();
});
ed.addEventListener('keyup', function (e) {
	if (e.key === '}') tryConvertToken(ed);
	checkPh();
});

ed.addEventListener('keydown', function (e) {
	if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
		e.preventDefault();
		doSave();
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
			var p1 = ed.childNodes[offset - 1];
			if (p1 && p1.nodeType === 1 && p1.classList.contains('token-chip')) chip = p1;
		} else if (node.nodeType === 3 && offset === 0 && node.previousSibling) {
			var p2 = node.previousSibling;
			if (p2 && p2.nodeType === 1 && p2.classList.contains('token-chip')) chip = p2;
		}
		if (chip) {
			e.preventDefault();
			chip.parentNode.removeChild(chip);
			checkPh();
			return;
		}
	}
});

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

// Cursor Ejector from non-editable chips
document.addEventListener('selectionchange', function () {
	var sel = window.getSelection();
	if (!sel || !sel.rangeCount || !sel.isCollapsed) return;
	var range = sel.getRangeAt(0);
	var node = range.startContainer;
	var el = node.nodeType === 3 ? node.parentElement : node;
	if (el && el.classList && el.classList.contains('token-chip')) {
		var nr = document.createRange();
		nr.setStartAfter(el);
		nr.collapse(true);
		sel.removeAllRanges();
		sel.addRange(nr);
	}
});

// ── Main UI API ───────────────────────────────────────────────────
function init(data) {
	document.getElementById('title').textContent = data.title;
	document.getElementById('p-name').value = data.name;
	document.getElementById('p-mode').value = data.mode;

	var promptVal = data.prompt;
	ed.innerHTML = '';
	parseToNodes(promptVal).forEach(function (n) {
		ed.appendChild(n);
	});
	checkPh();

	setTimeout(function () {
		document.getElementById('p-name').focus();
	}, 100);
}

function doCancel() {
	window.webkit.messageHandlers.prompt_bridge.postMessage({ action: 'cancel' });
}

function doSave() {
	const name = document.getElementById('p-name').value.trim();
	const mode = document.getElementById('p-mode').value;
	const prompt = serializeEditor(ed).trim();

	if (!name || !prompt) return alert('Le nom et le prompt sont requis.');

	window.webkit.messageHandlers.prompt_bridge.postMessage({
		action: 'save',
		name: name,
		batch: mode === 'batch',
		prompt: prompt
	});
}

document.addEventListener('keydown', function (e) {
	if (e.key === 'Escape') doCancel();
});
