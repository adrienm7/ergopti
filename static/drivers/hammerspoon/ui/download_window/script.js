var _logLines = [];

function doCancel() {
	document.getElementById('btn-cancel').disabled = true;
	document.getElementById('btn-cancel').textContent = 'Annulation…';
	if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dl_bridge) {
		window.webkit.messageHandlers.dl_bridge.postMessage('cancel');
	}
}

function doTerm() {
	if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dl_bridge) {
		window.webkit.messageHandlers.dl_bridge.postMessage('terminal');
	}
}

function setModel(n) {
	document.getElementById('model').textContent = n;
}

function update(pct, dl, speed, eta) {
	document.getElementById('bar-fill').style.width = pct + '%';
	document.getElementById('pct').textContent = pct + ' %';

	var s = '';
	if (dl) s += '<b>' + dl + '</b><br>';
	if (speed) s += 'Vitesse : <b>' + speed + '</b>';
	if (eta) s += '  ·  Temps restant : <b>' + eta + '</b>';

	document.getElementById('stats').innerHTML = s || 'Téléchargement en cours…';
}

function addLog(line) {
	_logLines.push(line);
	if (_logLines.length > 200) _logLines.shift();

	var el = document.getElementById('log-area');
	el.textContent = _logLines.join('\n');
	el.scrollTop = el.scrollHeight;
}

function showLog() {
	document.getElementById('log-area').style.display = 'block';
}

function done(ok, msg) {
	document.getElementById('btn-cancel').style.display = 'none';
	document.getElementById('bar-fill').style.width = '100%';
	document.getElementById('pct').textContent = ok ? '100 %' : '—';

	var d = document.getElementById('done-msg');
	d.textContent = msg;
	d.className = ok ? 'ok' : 'error';
	d.style.display = 'block';

	document.getElementById('stats').textContent = '';
}
