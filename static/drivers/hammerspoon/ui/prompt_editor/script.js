// ui/prompt_editor/script.js

/**
 * ==============================================================================
 * MODULE: Prompt Editor UI Script
 * DESCRIPTION:
 * Handles the interactive rich-text editor for LLM prompts.
 * Supports visual "chips" for tokens like {context} and custom serialization
 * to convert the DOM state back into raw prompt text.
 * ==============================================================================
 */

// ===============================
// ===============================
// ======= 1/ Chips Engine =======
// ===============================
// ===============================

/**
 * Creates a non-editable visual chip element for a specific token.
 * @param {string} name - The token name (e.g., "context").
 * @returns {HTMLElement} The constructed span element representing the chip.
 */
function makeChip(name) {
	var s = document.createElement('span');
	s.className = 'token-chip';
	s.contentEditable = 'false';
	s.dataset.token = name;
	s.textContent = '{' + name + '}';
	return s;
}

/**
 * Parses a raw text string containing tokens into an array of DOM nodes.
 * Converts newlines to <br> elements and {context} markers to visual chips.
 * @param {string} text - The raw text to parse.
 * @returns {Node[]} An array of text nodes and HTMLElements.
 */
function parseToNodes(text) {
	if (!text) return [document.createTextNode('')];

	var nodes = [];
	var normalized = text.replace(/\n/g, '{Enter}');
	var re = /\{([^}]+)\}/gi;
	var last = 0;
	var match;

	while ((match = re.exec(normalized)) !== null) {
		if (match.index > last) {
			nodes.push(document.createTextNode(normalized.slice(last, match.index)));
		}

		var tokenName = match[1].toLowerCase();
		if (tokenName === 'enter') {
			nodes.push(document.createElement('br'));
		} else if (
			tokenName === 'context' ||
			tokenName === 'n' ||
			tokenName === 'min_words' ||
			tokenName === 'max_words'
		) {
			nodes.push(makeChip(tokenName));
		} else {
			nodes.push(document.createTextNode(match[0]));
		}
		last = re.lastIndex;
	}

	if (last < normalized.length) {
		nodes.push(document.createTextNode(normalized.slice(last)));
	}

	return nodes;
}

/**
 * Serializes the editor's DOM state back into a raw text string.
 * @param {HTMLElement} element - The editor container element.
 * @returns {string} The serialized raw prompt string.
 */
function serializeEditor(element) {
	var nodes = Array.from(element.childNodes);

	// Strip trailing breaks that aren't chips
	while (nodes.length > 0) {
		var last = nodes[nodes.length - 1];
		if (last.nodeType === 1 && last.tagName === 'BR' && !last.classList.contains('token-chip')) {
			nodes.pop();
		} else {
			break;
		}
	}

	var serializedString = '';
	nodes.forEach(function (node) {
		if (node.nodeType === 3) {
			serializedString += node.textContent;
		} else if (node.nodeType === 1 && node.classList.contains('token-chip')) {
			serializedString += '{' + node.dataset.token + '}';
		} else if (node.nodeType === 1 && node.tagName === 'BR') {
			serializedString += '\n';
		} else {
			serializedString += node.textContent || '';
		}
	});

	return serializedString;
}

/**
 * Toggles the visibility of the placeholder based on the editor's content.
 */
function checkPlaceholder() {
	var editorElement = document.getElementById('e-out');
	var placeholderElement = document.getElementById('e-out-ph');

	var isEmpty =
		editorElement.textContent.length === 0 && editorElement.innerHTML.indexOf('<span') === -1;
	placeholderElement.style.display = isEmpty ? 'block' : 'none';
}

/**
 * Safely inserts a line break (<br>) at the current cursor position.
 */
function insertBrAtCursor() {
	var editorElement = document.getElementById('e-out');
	editorElement.focus();

	var selection = window.getSelection();
	var br = document.createElement('br');

	if (selection && selection.rangeCount) {
		var range = selection.getRangeAt(0);
		if (editorElement.contains(range.commonAncestorContainer)) {
			range.deleteContents();
			range.insertNode(br);

			// Add an empty text node after the break to allow cursor placement
			if (!br.nextSibling) br.parentNode.appendChild(document.createTextNode(''));

			var newRange = document.createRange();
			newRange.setStartAfter(br);
			newRange.collapse(true);
			selection.removeAllRanges();
			selection.addRange(newRange);
			checkPlaceholder();
			return;
		}
	}

	// Fallback if no valid selection exists inside the editor
	editorElement.appendChild(br);
	editorElement.appendChild(document.createTextNode(''));
	checkPlaceholder();
}

/**
 * Inserts a visual token chip at the current cursor position.
 * @param {string} name - The token name to insert.
 */
function insertChipAtCursor(name) {
	var editorElement = document.getElementById('e-out');
	editorElement.focus();

	var chip = makeChip(name);
	var selection = window.getSelection();

	if (selection && selection.rangeCount) {
		var range = selection.getRangeAt(0);
		if (editorElement.contains(range.commonAncestorContainer)) {
			range.deleteContents();
			range.insertNode(chip);

			var newRange = document.createRange();
			newRange.setStartAfter(chip);
			newRange.collapse(true);
			selection.removeAllRanges();
			selection.addRange(newRange);
			checkPlaceholder();
			return;
		}
	}

	editorElement.appendChild(chip);
	var fallbackRange = document.createRange();
	fallbackRange.setStartAfter(chip);
	fallbackRange.collapse(true);

	selection = window.getSelection();
	if (selection) {
		selection.removeAllRanges();
		selection.addRange(fallbackRange);
	}
	checkPlaceholder();
}

/**
 * Dynamically detects if the user has manually typed a token string (e.g., "{context}")
 * and converts it into a visual chip element.
 * @param {HTMLElement} editorElement - The editor container element.
 */
function tryConvertToken(editorElement) {
	var selection = window.getSelection();
	if (!selection || !selection.rangeCount) return;

	var range = selection.getRangeAt(0);
	if (!range.collapsed) return;

	var node = range.startContainer;
	if (node.nodeType !== 3) return; // Only process text nodes

	var offset = range.startOffset;
	var beforeContent = node.textContent.slice(0, offset);
	var match = beforeContent.match(/\{(context|n|min_words|max_words)\}$/i);
	if (!match) return;

	var matchStart = offset - match[0].length;
	var replaceRange = document.createRange();
	replaceRange.setStart(node, matchStart);
	replaceRange.setEnd(node, offset);
	replaceRange.deleteContents();

	var tokenName = match[1].toLowerCase();
	var chip = makeChip(tokenName);
	var anchorRange = selection.getRangeAt(0);
	anchorRange.insertNode(chip);

	var newRange = document.createRange();
	newRange.setStartAfter(chip);
	newRange.collapse(true);
	selection.removeAllRanges();
	selection.addRange(newRange);

	checkPlaceholder();
}

// ======================================
// ======================================
// ======= 2/ Autocomplete Engine =======
// ======================================
// ======================================

var acItems = [];
var acIdx = 0;
var TOKEN_NAMES = ['context', 'n', 'min_words', 'max_words'];

/**
 * Retrieves the context under the cursor to determine if autocomplete should trigger.
 * @returns {Object|null} Context including the partial match and node references.
 */
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

/**
 * Displays the autocomplete popup with the matching options.
 * @param {string[]} matches - An array of matching token names.
 */
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

/**
 * Hides the autocomplete popup and resets the matches.
 */
function hideAc() {
	var popup = document.getElementById('ac-popup');
	if (popup) popup.classList.remove('on');
	acItems = [];
}

/**
 * Updates the visual selection highlight within the autocomplete dropdown.
 */
function updateAcSel() {
	document.querySelectorAll('.ac-item').forEach(function (el, i) {
		el.classList.toggle('active', i === acIdx);
	});
}

/**
 * Applies the selected token from the autocomplete list.
 * @param {string} name - The token name to insert.
 */
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

	var chip = makeChip(name);
	var sel = window.getSelection();
	var anch = sel.getRangeAt(0);
	anch.insertNode(chip);

	var nr = document.createRange();
	nr.setStartAfter(chip);
	nr.collapse(true);
	sel.removeAllRanges();
	sel.addRange(nr);
	checkPlaceholder();
}

/**
 * Validates the current typing context against the list of available tokens.
 */
function checkAc() {
	var ctx = getAcCtx();
	if (!ctx) {
		hideAc();
		return;
	}
	var matches = TOKEN_NAMES.filter(function (n) {
		return n.toLowerCase().indexOf(ctx.partial) === 0;
	});
	if (matches.length === 0) {
		hideAc();
		return;
	}
	showAc(matches);
}

// ================================
// ================================
// ======= 3/ Events Wiring =======
// ================================
// ================================

var editorElement = document.getElementById('e-out');

// Trigger dynamic token evaluation on text input
editorElement.addEventListener('input', function () {
	tryConvertToken(editorElement);
	checkAc();
	checkPlaceholder();
});

editorElement.addEventListener('keyup', function (e) {
	if (
		acItems.length > 0 &&
		['Tab', 'ArrowDown', 'ArrowUp', 'ArrowLeft', 'ArrowRight', 'Escape', 'Enter'].indexOf(e.key) >=
			0
	) {
		return;
	}
	if (e.key === '}') tryConvertToken(editorElement);
	checkAc();
	checkPlaceholder();
});

editorElement.addEventListener('blur', hideAc);

editorElement.addEventListener('keydown', function (e) {
	// Handling Autocomplete navigation
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

	// Save on Cmd+Enter / Ctrl+Enter
	if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
		e.preventDefault();
		doSave();
		return;
	}

	// Handle standard newlines
	if (e.key === 'Enter') {
		e.preventDefault();
		insertBrAtCursor();
		return;
	}

	// Custom backspace logic to delete full chips as a single entity
	if (e.key === 'Backspace') {
		var selection = window.getSelection();
		if (!selection || !selection.rangeCount) return;

		var range = selection.getRangeAt(0);
		if (!range.collapsed) return;

		var node = range.startContainer;
		var offset = range.startOffset;
		var targetChip = null;

		if (node === editorElement && offset > 0) {
			var prevNode = editorElement.childNodes[offset - 1];
			if (prevNode && prevNode.nodeType === 1 && prevNode.classList.contains('token-chip')) {
				targetChip = prevNode;
			}
		} else if (node.nodeType === 3 && offset === 0 && node.previousSibling) {
			var prevSibling = node.previousSibling;
			if (
				prevSibling &&
				prevSibling.nodeType === 1 &&
				prevSibling.classList.contains('token-chip')
			) {
				targetChip = prevSibling;
			}
		}

		if (targetChip) {
			e.preventDefault();
			targetChip.parentNode.removeChild(targetChip);
			checkPlaceholder();
			return;
		}
	}
});

// Handle text pasting (strip rich formatting, maintain chips)
editorElement.addEventListener('paste', function (e) {
	e.preventDefault();

	var clipboardText = (e.clipboardData || window.clipboardData).getData('text/plain');
	if (!clipboardText) return;

	var selection = window.getSelection();
	if (!selection || !selection.rangeCount) {
		editorElement.appendChild(document.createTextNode(clipboardText));
		checkPlaceholder();
		return;
	}

	var range = selection.getRangeAt(0);
	range.deleteContents();

	var fragment = document.createDocumentFragment();
	parseToNodes(clipboardText).forEach(function (node) {
		fragment.appendChild(node);
	});

	range.insertNode(fragment);
	range.collapse(false);
	selection.removeAllRanges();
	selection.addRange(range);

	checkPlaceholder();
});

// Cursor Ejector: Prevents the caret from getting stuck inside non-editable chips
document.addEventListener('selectionchange', function () {
	var selection = window.getSelection();
	if (!selection || !selection.rangeCount || !selection.isCollapsed) return;

	var range = selection.getRangeAt(0);
	var node = range.startContainer;
	var parentElement = node.nodeType === 3 ? node.parentElement : node;

	if (parentElement && parentElement.classList && parentElement.classList.contains('token-chip')) {
		var newRange = document.createRange();
		newRange.setStartAfter(parentElement);
		newRange.collapse(true);
		selection.removeAllRanges();
		selection.addRange(newRange);
	}
});

// Hide Autocomplete popup when clicking outside
document.addEventListener('click', function (e) {
	var popup = document.getElementById('ac-popup');
	if (popup && !popup.contains(e.target)) hideAc();
});

// ==============================
// ==============================
// ======= 4/ Main UI API =======
// ==============================
// ==============================

/**
 * Initializes the interface with data passed from the Hammerspoon backend.
 * @param {Object} data - The initialization payload.
 */
function init(data) {
	document.getElementById('title').textContent = data.title;
	document.getElementById('p-name').value = data.name;
	document.getElementById('p-mode').value = data.mode;

	var promptValue = data.prompt;
	editorElement.innerHTML = '';

	parseToNodes(promptValue).forEach(function (node) {
		editorElement.appendChild(node);
	});

	checkPlaceholder();

	setTimeout(function () {
		document.getElementById('p-name').focus();
	}, 100);
}

/**
 * Communicates the cancellation request back to Hammerspoon.
 */
function doCancel() {
	window.webkit.messageHandlers.prompt_bridge.postMessage({ action: 'cancel' });
}

/**
 * Serializes the editor and sends the updated configuration back to Hammerspoon.
 */
function doSave() {
	var promptName = document.getElementById('p-name').value.trim();
	var promptMode = document.getElementById('p-mode').value;
	var promptContent = serializeEditor(editorElement).trim();

	// UI text remains in French as requested
	if (!promptName || !promptContent) {
		return alert('Le nom et le prompt sont requis.');
	}

	window.webkit.messageHandlers.prompt_bridge.postMessage({
		action: 'save',
		name: promptName,
		batch: promptMode === 'batch',
		prompt: promptContent
	});
}

// Global hotkey for cancellation
document.addEventListener('keydown', function (e) {
	if (e.key === 'Escape') doCancel();
});
