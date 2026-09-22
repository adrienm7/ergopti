// _shared/ui/markdown.js

/**
 * ==============================================================================
 * MODULE: Safe Markdown Renderer
 * DESCRIPTION:
 * Renders the GitHub-flavoured Markdown subset used in release notes into DOM
 * nodes for the shared WebView pages. Release bodies are remote content, so the
 * renderer never hands a string to an HTML parser: every character of the
 * source reaches the page through createElement() and createTextNode() only.
 *
 * FEATURES & RATIONALE:
 * 1. Inert by construction: raw HTML in the source is shown as literal text, so
 *    a <script> or an onerror attribute can never become live markup.
 * 2. Caller-owned link policy: anchors carry no href, so the WebView cannot
 *    navigate. A link becomes clickable only when its absolute https: URL passes
 *    the caller's allow() predicate; the click is then handed to open(), which
 *    routes it through the host's native open_url bridge.
 * 3. Offline and dependency-free: CSP-compatible (script-src 'self'), no CDN.
 * 4. Supported subset: ATX headings, paragraphs with hard line breaks, nested
 *    bullet/ordered/task lists, blockquotes, fenced code, tables, thematic
 *    breaks, emphasis, strong, strikethrough, inline code, links and autolinks.
 *    Images render as their alt text (the pages' CSP forbids remote images).
 * ==============================================================================
 */

(function (global) {
	'use strict';

	var FENCE = /^ {0,3}(`{3,}|~{3,})/;
	var HEADING = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/;
	var THEMATIC_BREAK = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
	var BLOCKQUOTE = /^ {0,3}> ?(.*)$/;
	var LIST_ITEM = /^( *)([-*+]|\d{1,9}[.)])([ \t]+(.*))?$/;
	var TABLE_SEPARATOR = /^ *\|? *:?-+:? *(\| *:?-+:? *)*\|? *$/;
	var BARE_URL = /^https?:\/\/[^\s<>]+/;
	var ESCAPABLE = '\\`*_{}[]()#+-.!|~<>"\'';

	// =========================================
	// =========================================
	// ======= 1/ Link Policy ==================
	// =========================================
	// =========================================

	/**
	 * Returns the URL when it is an absolute https: URL the caller allows.
	 * @param {string} raw - Link destination from the source.
	 * @param {Object} options - Renderer options.
	 * @return {string|null}
	 */
	function _allowedUrl(raw, options) {
		if (typeof raw !== 'string' || raw === '') return null;
		var parsed;
		try {
			parsed = new URL(raw);
		} catch (error) {
			return null;
		}
		if (parsed.protocol !== 'https:') return null;
		if (typeof options.allow !== 'function' || !options.allow(raw)) return null;
		return raw;
	}

	/**
	 * Appends a link: an actionable anchor for an allowed URL, plain text otherwise.
	 * @param {Node} parent
	 * @param {string} label - Link label source (inline Markdown).
	 * @param {string} url - Link destination.
	 * @param {Object} options
	 */
	function _appendLink(parent, label, url, options) {
		var allowed = _allowedUrl(url, options);
		if (!allowed || typeof options.open !== 'function') {
			var span = document.createElement('span');
			span.className = 'md-link-refused';
			_parseInline(label, span, options, true);
			parent.appendChild(span);
			return;
		}
		var anchor = document.createElement('a');
		anchor.setAttribute('data-url', allowed);
		anchor.setAttribute('title', allowed);
		anchor.setAttribute('role', 'link');
		anchor.setAttribute('tabindex', '0');
		anchor.addEventListener('click', function (event) {
			if (event && typeof event.preventDefault === 'function') event.preventDefault();
			options.open(allowed);
		});
		anchor.addEventListener('keydown', function (event) {
			if (!event || event.key !== 'Enter') return;
			if (typeof event.preventDefault === 'function') event.preventDefault();
			options.open(allowed);
		});
		_parseInline(label, anchor, options, true);
		parent.appendChild(anchor);
	}

	// =========================================
	// =========================================
	// ======= 2/ Inline Parsing ===============
	// =========================================
	// =========================================

	function _isWordChar(ch) {
		return !!ch && /[0-9A-Za-z\u00C0-\uFFFF]/.test(ch);
	}

	/**
	 * Finds the closing delimiter of an emphasis run, or -1.
	 * @param {string} text
	 * @param {string} delim - Delimiter string ("**", "*", "__", "_", "~~").
	 * @param {number} from - Index just after the opener.
	 * @return {number}
	 */
	function _findCloser(text, delim, from) {
		var inner = text.charAt(from);
		if (inner === '' || /\s/.test(inner)) return -1;
		var idx = from;
		while ((idx = text.indexOf(delim, idx + 1)) !== -1) {
			if (/\s/.test(text.charAt(idx - 1))) continue;
			// A single-char delimiter must not be half of a doubled one.
			if (delim.length === 1 && text.charAt(idx + 1) === delim) {
				idx += 1;
				continue;
			}
			// Underscores only close at a word boundary (spares snake_case).
			if (delim.charAt(0) === '_' && _isWordChar(text.charAt(idx + delim.length))) continue;
			return idx;
		}
		return -1;
	}

	/**
	 * Parses a link destination "(url "title")" starting at an opening parenthesis.
	 * @return {{url: string, end: number}|null} end is the index after ")".
	 */
	function _parseDestination(text, open) {
		if (text.charAt(open) !== '(') return null;
		var depth = 0;
		for (var i = open; i < text.length; i++) {
			var ch = text.charAt(i);
			if (ch === '\\') {
				i++;
				continue;
			}
			if (ch === '(') depth++;
			else if (ch === ')') {
				depth--;
				if (depth === 0) {
					var inside = text.slice(open + 1, i).trim();
					var url = inside.split(/\s+/)[0] || '';
					if (url.charAt(0) === '<' && url.charAt(url.length - 1) === '>') url = url.slice(1, -1);
					return { url: url, end: i + 1 };
				}
			}
		}
		return null;
	}

	/** Finds the "]" that closes a bracket opened at index open, or -1. */
	function _findBracketClose(text, open) {
		var depth = 0;
		for (var i = open; i < text.length; i++) {
			var ch = text.charAt(i);
			if (ch === '\\') {
				i++;
				continue;
			}
			if (ch === '[') depth++;
			else if (ch === ']') {
				depth--;
				if (depth === 0) return i;
			}
		}
		return -1;
	}

	/**
	 * Appends inline Markdown as DOM nodes.
	 * @param {string} text - Inline source.
	 * @param {Node} parent - Receiving element.
	 * @param {Object} options - Renderer options.
	 * @param {boolean} inLink - True inside a link label (no nested links).
	 */
	function _parseInline(text, parent, options, inLink) {
		var buffer = '';
		function flush() {
			if (buffer !== '') {
				parent.appendChild(document.createTextNode(buffer));
				buffer = '';
			}
		}
		function wrap(tag, inner) {
			flush();
			var el = document.createElement(tag);
			_parseInline(inner, el, options, inLink);
			parent.appendChild(el);
		}

		var i = 0;
		while (i < text.length) {
			var ch = text.charAt(i);
			var rest = text.slice(i);

			if (ch === '\\' && i + 1 < text.length && ESCAPABLE.indexOf(text.charAt(i + 1)) !== -1) {
				buffer += text.charAt(i + 1);
				i += 2;
				continue;
			}

			if (ch === '`') {
				var run = /^`+/.exec(rest)[0];
				var close = text.indexOf(run, i + run.length);
				while (close !== -1 && text.charAt(close + run.length) === '`') {
					close = text.indexOf(run, close + run.length + 1);
				}
				if (close !== -1) {
					flush();
					var code = document.createElement('code');
					var content = text.slice(i + run.length, close);
					if (/^ .* $/.test(content) && content.trim() !== '') content = content.slice(1, -1);
					code.appendChild(document.createTextNode(content));
					parent.appendChild(code);
					i = close + run.length;
					continue;
				}
				buffer += run;
				i += run.length;
				continue;
			}

			if (ch === '!' && text.charAt(i + 1) === '[') {
				var imgClose = _findBracketClose(text, i + 1);
				var imgDest = imgClose !== -1 ? _parseDestination(text, imgClose + 1) : null;
				if (imgDest) {
					// Remote images are blocked by CSP; show the alt text instead.
					_parseInline(text.slice(i + 2, imgClose), parent, options, inLink);
					i = imgDest.end;
					continue;
				}
			}

			if (ch === '[' && !inLink) {
				var labelClose = _findBracketClose(text, i);
				var dest = labelClose !== -1 ? _parseDestination(text, labelClose + 1) : null;
				if (dest) {
					flush();
					_appendLink(parent, text.slice(i + 1, labelClose), dest.url, options);
					i = dest.end;
					continue;
				}
			}

			if (ch === '<' && !inLink) {
				var auto = /^<(https?:\/\/[^\s<>]+)>/.exec(rest);
				if (auto) {
					flush();
					_appendLink(parent, auto[1], auto[1], options);
					i += auto[0].length;
					continue;
				}
			}

			if ((ch === 'h' || ch === 'H') && !inLink && !_isWordChar(text.charAt(i - 1))) {
				var bare = BARE_URL.exec(rest);
				if (bare) {
					var url = bare[0].replace(/[.,;:!?'")\]]+$/, '');
					flush();
					_appendLink(parent, url.replace(/[\\`*_[\]]/g, '\\$&'), url, options);
					i += url.length;
					continue;
				}
			}

			var delims = ['**', '__', '~~', '*', '_'];
			var matched = false;
			for (var d = 0; d < delims.length; d++) {
				var delim = delims[d];
				if (rest.indexOf(delim) !== 0) continue;
				if (delim.charAt(0) === '_' && _isWordChar(text.charAt(i - 1))) break;
				var closer = _findCloser(text, delim, i + delim.length);
				if (closer === -1) continue;
				var tag = delim === '~~' ? 'del' : delim.length === 2 ? 'strong' : 'em';
				wrap(tag, text.slice(i + delim.length, closer));
				i = closer + delim.length;
				matched = true;
				break;
			}
			if (matched) continue;

			buffer += ch;
			i++;
		}
		flush();
	}

	// =========================================
	// =========================================
	// ======= 3/ Block Parsing ================
	// =========================================
	// =========================================

	function _isBlank(line) {
		return /^\s*$/.test(line);
	}

	function _indentOf(line) {
		return /^ */.exec(line)[0].length;
	}

	/** Splits a table row into trimmed cell sources. */
	function _tableCells(line) {
		var trimmed = line.trim().replace(/^\|/, '').replace(/\|$/, '');
		var cells = [];
		var current = '';
		for (var i = 0; i < trimmed.length; i++) {
			var ch = trimmed.charAt(i);
			if (ch === '\\' && trimmed.charAt(i + 1) === '|') {
				current += '|';
				i++;
			} else if (ch === '|') {
				cells.push(current.trim());
				current = '';
			} else {
				current += ch;
			}
		}
		cells.push(current.trim());
		return cells;
	}

	/** True when a line starts a block other than a paragraph continuation. */
	function _startsBlock(line) {
		return (
			FENCE.test(line) ||
			HEADING.test(line) ||
			THEMATIC_BREAK.test(line) ||
			BLOCKQUOTE.test(line) ||
			LIST_ITEM.test(line)
		);
	}

	/**
	 * Renders block-level Markdown lines into a parent element.
	 * @param {string[]} lines
	 * @param {Node} parent
	 * @param {Object} options
	 * @param {boolean} tight - Inside a tight list item: paragraphs are unwrapped.
	 */
	function _renderBlocks(lines, parent, options, tight) {
		var i = 0;
		while (i < lines.length) {
			var line = lines[i];

			if (_isBlank(line)) {
				i++;
				continue;
			}

			var fence = FENCE.exec(line);
			if (fence) {
				var marker = fence[1];
				var codeLines = [];
				i++;
				while (i < lines.length && lines[i].trim().indexOf(marker) !== 0) {
					codeLines.push(lines[i]);
					i++;
				}
				i++;
				var pre = document.createElement('pre');
				var code = document.createElement('code');
				code.appendChild(document.createTextNode(codeLines.join('\n')));
				pre.appendChild(code);
				parent.appendChild(pre);
				continue;
			}

			var heading = HEADING.exec(line);
			if (heading) {
				var h = document.createElement('h' + heading[1].length);
				_parseInline(heading[2] || '', h, options, false);
				parent.appendChild(h);
				i++;
				continue;
			}

			if (THEMATIC_BREAK.test(line)) {
				parent.appendChild(document.createElement('hr'));
				i++;
				continue;
			}

			if (BLOCKQUOTE.test(line)) {
				var quoted = [];
				while (i < lines.length && BLOCKQUOTE.test(lines[i])) {
					quoted.push(BLOCKQUOTE.exec(lines[i])[1]);
					i++;
				}
				var quote = document.createElement('blockquote');
				_renderBlocks(quoted, quote, options, false);
				parent.appendChild(quote);
				continue;
			}

			if (LIST_ITEM.test(line)) {
				i = _renderList(lines, i, parent, options);
				continue;
			}

			if (
				line.indexOf('|') !== -1 &&
				i + 1 < lines.length &&
				TABLE_SEPARATOR.test(lines[i + 1]) &&
				lines[i + 1].indexOf('-') !== -1
			) {
				var table = document.createElement('table');
				var headRow = document.createElement('tr');
				_tableCells(line).forEach(function (cell) {
					var th = document.createElement('th');
					_parseInline(cell, th, options, false);
					headRow.appendChild(th);
				});
				var thead = document.createElement('thead');
				thead.appendChild(headRow);
				table.appendChild(thead);
				var tbody = document.createElement('tbody');
				i += 2;
				while (i < lines.length && !_isBlank(lines[i]) && lines[i].indexOf('|') !== -1) {
					var row = document.createElement('tr');
					_tableCells(lines[i]).forEach(function (cell) {
						var td = document.createElement('td');
						_parseInline(cell, td, options, false);
						row.appendChild(td);
					});
					tbody.appendChild(row);
					i++;
				}
				table.appendChild(tbody);
				parent.appendChild(table);
				continue;
			}

			// Paragraph: consecutive lines, each newline rendered as a hard break
			// the way GitHub renders release notes.
			var paragraph = [line.trim()];
			i++;
			while (i < lines.length && !_isBlank(lines[i]) && !_startsBlock(lines[i])) {
				paragraph.push(lines[i].trim());
				i++;
			}
			var target = parent;
			if (!tight) {
				target = document.createElement('p');
				parent.appendChild(target);
			}
			paragraph.forEach(function (source, index) {
				if (index > 0) target.appendChild(document.createElement('br'));
				_parseInline(source, target, options, false);
			});
		}
	}

	/**
	 * Renders one list (and its nested content) starting at lines[start].
	 * @return {number} Index of the first line after the list.
	 */
	function _renderList(lines, start, parent, options) {
		var first = LIST_ITEM.exec(lines[start]);
		var baseIndent = first[1].length;
		var ordered = /\d/.test(first[2]);
		var list = document.createElement(ordered ? 'ol' : 'ul');
		if (ordered) {
			var startNumber = parseInt(first[2], 10);
			if (startNumber !== 1) list.setAttribute('start', String(startNumber));
		}
		var items = [];
		var loose = false;
		var i = start;

		while (i < lines.length) {
			var match = LIST_ITEM.exec(lines[i]);
			if (match && match[1].length === baseIndent && /\d/.test(match[2]) === ordered) {
				var contentIndent =
					baseIndent + match[2].length + (match[3] ? match[3].length - (match[4] || '').length : 1);
				var item = { lines: [match[4] || ''], contentIndent: contentIndent };
				items.push(item);
				i++;
				continue;
			}
			var current = items[items.length - 1];
			if (_isBlank(lines[i])) {
				// A blank line continues the item only when indented content follows.
				var next = i + 1 < lines.length ? lines[i + 1] : '';
				var nextMatch = LIST_ITEM.exec(next);
				var continues = !_isBlank(next) && _indentOf(next) > baseIndent;
				var sibling =
					nextMatch && nextMatch[1].length === baseIndent && /\d/.test(nextMatch[2]) === ordered;
				if (!continues && !sibling) break;
				loose = true;
				current.lines.push('');
				i++;
				continue;
			}
			if (_indentOf(lines[i]) > baseIndent) {
				current.lines.push(lines[i].slice(Math.min(_indentOf(lines[i]), current.contentIndent)));
				i++;
				continue;
			}
			// Lazy continuation of the item's paragraph.
			if (!_startsBlock(lines[i])) {
				current.lines.push(lines[i].trim());
				i++;
				continue;
			}
			break;
		}

		items.forEach(function (item) {
			var li = document.createElement('li');
			var task = /^\[([ xX])\][ \t]+/.exec(item.lines[0]);
			if (task) {
				li.className = 'task-list-item';
				li.appendChild(document.createTextNode(task[1] === ' ' ? '\u2610 ' : '\u2611 '));
				item.lines[0] = item.lines[0].slice(task[0].length);
			}
			_renderBlocks(item.lines, li, options, !loose);
			list.appendChild(li);
		});
		parent.appendChild(list);
		return i;
	}

	// =========================================
	// =========================================
	// ======= 4/ Public API ===================
	// =========================================
	// =========================================

	/**
	 * Replaces a container's children with the rendered Markdown.
	 * @param {Element} container - Receiving element.
	 * @param {string} source - Untrusted Markdown source.
	 * @param {{allow: function(string): boolean, open: function(string)}} options
	 *   allow() decides which https: URLs become clickable; open() receives the
	 *   URL of a clicked link. Without them every link renders as plain text.
	 */
	function renderMarkdownInto(container, source, options) {
		if (!container) throw new Error('renderMarkdownInto requires a container element');
		var text = typeof source === 'string' ? source : '';
		// HTML comments are invisible on GitHub; everything else stays literal.
		text = text
			.replace(/\r\n?/g, '\n')
			.replace(/<!--[\s\S]*?-->/g, '')
			.replace(/\t/g, '    ');
		container.replaceChildren();
		_renderBlocks(text.split('\n'), container, options || {}, false);
	}

	global.renderMarkdownInto = renderMarkdownInto;
})(window);
