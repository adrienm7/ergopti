// _shared/ui/changelog/atom_feed.js

/**
 * ==============================================================================
 * MODULE: Release Atom Feed Reader
 * DESCRIPTION:
 * Converts GitHub's public release feed (https://github.com/<repo>/releases.atom)
 * into the release records the changelog page already renders. The feed is the
 * alternate source used when api.github.com is blocked, rate-limited or slow
 * while github.com itself stays reachable (typical corporate proxy policy).
 *
 * FEATURES & RATIONALE:
 * 1. No HTML or XML parser: the feed and the rendered notes it carries are
 *    remote content, so they are tokenized as plain strings here and never
 *    handed to a document parser, a markup sink or an evaluator.
 * 2. Markdown output: release notes arrive as rendered HTML; they are converted
 *    to the Markdown subset of ../markdown.js, whose DOM-only renderer remains
 *    the single boundary between remote text and the document.
 * 3. Repository-bound entries: an entry whose link is not a release tag of the
 *    expected repository is discarded instead of being trusted.
 * ==============================================================================
 */

(function (global) {
	'use strict';

	// Characters the Markdown renderer treats as syntax; escaping them keeps
	// literal release text literal after the round-trip.
	var MARKDOWN_SPECIALS = /[\\`*_{}[\]()#+\-.!|~<>]/g;
	var VOID_TAGS = {
		br: true,
		hr: true,
		img: true,
		input: true,
		wbr: true,
		meta: true,
		link: true,
		source: true
	};
	var BLOCK_TAGS = {
		address: true,
		article: true,
		aside: true,
		blockquote: true,
		details: true,
		div: true,
		dl: true,
		dd: true,
		dt: true,
		figure: true,
		footer: true,
		h1: true,
		h2: true,
		h3: true,
		h4: true,
		h5: true,
		h6: true,
		header: true,
		hr: true,
		li: true,
		main: true,
		nav: true,
		ol: true,
		p: true,
		pre: true,
		section: true,
		summary: true,
		table: true,
		tbody: true,
		td: true,
		tfoot: true,
		th: true,
		thead: true,
		tr: true,
		ul: true
	};
	// Elements whose text must never reach the notes, even as inert text.
	var DROPPED_TAGS = { script: true, style: true, template: true, noscript: true };
	var NAMED_ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };

	// =========================================
	// =========================================
	// ======= 1/ Entities & Tokens ============
	// =========================================
	// =========================================

	/**
	 * Decodes XML/HTML character references without an HTML parser.
	 * Unknown named references stay literal; invalid code points become U+FFFD.
	 * @param {string} text
	 * @return {string}
	 */
	function decodeEntities(text) {
		return String(text).replace(
			/&(#[xX][0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]{2,8});/g,
			function (whole, ref) {
				if (ref.charAt(0) === '#') {
					var code =
						ref.charAt(1) === 'x' || ref.charAt(1) === 'X'
							? parseInt(ref.slice(2), 16)
							: parseInt(ref.slice(1), 10);
					if (!(code > 0 && code <= 0x10ffff) || (code >= 0xd800 && code <= 0xdfff)) return '�';
					return String.fromCodePoint(code);
				}
				return Object.prototype.hasOwnProperty.call(NAMED_ENTITIES, ref)
					? NAMED_ENTITIES[ref]
					: whole;
			}
		);
	}

	/**
	 * Reads one attribute value from a raw start-tag attribute string.
	 * @param {string} attrs
	 * @param {string} name - Lower-case attribute name.
	 * @return {string|null}
	 */
	function readAttribute(attrs, name) {
		var pattern = /([^\s"'=<>\/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
		var match;
		while ((match = pattern.exec(attrs)) !== null) {
			if (match[1].toLowerCase() !== name) continue;
			var value = match[2] !== undefined ? match[2] : match[3] !== undefined ? match[3] : match[4];
			return value === undefined ? '' : decodeEntities(value);
		}
		return null;
	}

	/**
	 * Builds a lightweight element tree from an HTML fragment.
	 * Tolerates unbalanced markup: a stray end tag closes the nearest matching
	 * open element and an unknown one is ignored.
	 * @param {string} html
	 * @return {{tag: string, attrs: string, children: Array}}
	 */
	function buildTree(html) {
		var root = { tag: '#root', attrs: '', children: [] };
		var stack = [root];
		var token =
			/<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<![^>]*>|<\?[\s\S]*?\?>|<\/\s*([a-zA-Z][a-zA-Z0-9-]*)\s*>|<([a-zA-Z][a-zA-Z0-9-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g;
		var last = 0;
		var match;
		var dropping = null;
		function top() {
			return stack[stack.length - 1];
		}
		function pushText(text) {
			if (text === '' || dropping) return;
			top().children.push({ tag: '#text', text: decodeEntities(text) });
		}
		while ((match = token.exec(html)) !== null) {
			pushText(html.slice(last, match.index));
			last = token.lastIndex;
			if (match[1]) {
				var closing = match[1].toLowerCase();
				if (dropping) {
					if (closing === dropping) dropping = null;
					continue;
				}
				for (var depth = stack.length - 1; depth > 0; depth--) {
					if (stack[depth].tag === closing) {
						stack.length = depth;
						break;
					}
				}
				continue;
			}
			if (!match[2] || dropping) continue;
			var tag = match[2].toLowerCase();
			var attrs = match[3] || '';
			if (DROPPED_TAGS[tag]) {
				if (!/\/\s*$/.test(attrs)) dropping = tag;
				continue;
			}
			var node = { tag: tag, attrs: attrs, children: [] };
			// Implicitly close an open paragraph or list item the way HTML does, so
			// sibling items never nest into one another.
			if (tag === 'li') {
				for (var liDepth = stack.length - 1; liDepth > 0; liDepth--) {
					var open = stack[liDepth].tag;
					if (open === 'ul' || open === 'ol') break;
					if (open === 'li') {
						stack.length = liDepth;
						break;
					}
				}
			}
			if (BLOCK_TAGS[tag] && top().tag === 'p') stack.pop();
			top().children.push(node);
			if (!VOID_TAGS[tag] && !/\/\s*$/.test(attrs)) stack.push(node);
		}
		pushText(html.slice(last));
		return root;
	}

	// =========================================
	// =========================================
	// ======= 2/ HTML to Markdown =============
	// =========================================
	// =========================================

	/** Escapes literal text so the Markdown renderer shows it verbatim. */
	function escapeMarkdown(text) {
		return text.replace(MARKDOWN_SPECIALS, '\\$&');
	}

	/** Concatenates the raw text of a subtree. */
	function textOf(node) {
		if (node.tag === '#text') return node.text;
		if (node.tag === 'br') return '\n';
		return node.children.map(textOf).join('');
	}

	/** Returns an absolute http(s) link destination safe to embed in Markdown. */
	function linkDestination(attrs) {
		var href = readAttribute(attrs, 'href');
		if (!href || !/^https?:\/\//i.test(href.trim())) return null;
		return href.trim().replace(/[\s()<>\\]/g, function (ch) {
			return '%' + ch.charCodeAt(0).toString(16).toUpperCase().padStart(2, '0');
		});
	}

	/** Wraps inline code in a backtick fence longer than any run it contains. */
	function inlineCode(text) {
		var longest = 0;
		(text.match(/`+/g) || []).forEach(function (run) {
			longest = Math.max(longest, run.length);
		});
		var fence = '`'.repeat(longest + 1);
		var padded = /^`|`$/.test(text) ? ' ' + text + ' ' : text;
		return fence + padded + fence;
	}

	/** Renders inline content; hard breaks become newlines. */
	function inline(nodes) {
		return nodes
			.map(function (node) {
				switch (node.tag) {
					case '#text':
						return escapeMarkdown(node.text.replace(/\s+/g, ' '));
					case 'br':
						return '\n';
					case 'strong':
					case 'b':
						return wrapInline('**', inline(node.children));
					case 'em':
					case 'i':
						return wrapInline('*', inline(node.children));
					case 'del':
					case 's':
					case 'strike':
						return wrapInline('~~', inline(node.children));
					case 'code':
					case 'kbd':
					case 'samp':
						return inlineCode(textOf(node).replace(/\s+/g, ' '));
					case 'img':
						return escapeMarkdown(readAttribute(node.attrs, 'alt') || '');
					case 'input':
						return /\bchecked\b/i.test(node.attrs) ? '[x] ' : '[ ] ';
					case 'a': {
						var label = inline(node.children).trim();
						var destination = linkDestination(node.attrs);
						if (!destination) return label;
						return '[' + (label || escapeMarkdown(destination)) + '](' + destination + ')';
					}
					default:
						return inline(node.children);
				}
			})
			.join('');
	}

	/** Applies an emphasis delimiter around trimmed content, keeping outer spaces. */
	function wrapInline(delimiter, content) {
		var trimmed = content.trim();
		if (trimmed === '') return content;
		var lead = /^\s/.test(content) ? ' ' : '';
		var tail = /\s$/.test(content) ? ' ' : '';
		return lead + delimiter + trimmed + delimiter + tail;
	}

	/** Normalizes an inline run into trimmed, non-empty lines. */
	function inlineLines(nodes) {
		return inline(nodes)
			.split('\n')
			.map(function (line) {
				return line.replace(/ {2,}/g, ' ').trim();
			})
			.filter(function (line) {
				return line !== '';
			});
	}

	/** Prefixes the first line and indents the following lines. */
	function prefixLines(lines, first, rest) {
		return lines.map(function (line, index) {
			if (line === '') return '';
			return (index === 0 ? first : rest) + line;
		});
	}

	/** Renders a table element as a Markdown pipe table. */
	function tableLines(node) {
		var rows = [];
		(function collect(parent) {
			parent.children.forEach(function (child) {
				if (child.tag === 'tr') rows.push(child);
				else if (child.tag !== '#text') collect(child);
			});
		})(node);
		if (rows.length === 0) return [];
		var cells = rows.map(function (row) {
			return row.children
				.filter(function (cell) {
					return cell.tag === 'td' || cell.tag === 'th';
				})
				.map(function (cell) {
					return inlineLines(cell.children).join(' ').replace(/\|/g, '\\|');
				});
		});
		var width = Math.max.apply(
			null,
			cells.map(function (row) {
				return row.length;
			})
		);
		if (width === 0) return [];
		var lines = cells.map(function (row) {
			while (row.length < width) row.push('');
			return '| ' + row.join(' | ') + ' |';
		});
		var separator = '|' + new Array(width + 1).join(' --- |');
		lines.splice(1, 0, separator);
		return lines;
	}

	/** Renders one list element; items are tight, nested blocks are indented. */
	function listLines(node, ordered) {
		var out = [];
		var number = parseInt(readAttribute(node.attrs, 'start') || '1', 10);
		if (!(number >= 0)) number = 1;
		node.children.forEach(function (child) {
			if (child.tag !== 'li') return;
			var marker = ordered ? number++ + '. ' : '- ';
			var body = blockLines(child.children, true);
			if (body.length === 0) body = [''];
			var indent = new Array(marker.length + 1).join(' ');
			out = out.concat(
				prefixLines(body, marker, indent).map(function (line, index) {
					return index === 0 && line === '' ? marker.trimEnd() : line;
				})
			);
		});
		return out;
	}

	/**
	 * Renders a node list as Markdown block lines.
	 * @param {Array} nodes
	 * @param {boolean} tight - Inside a list item: no blank line between blocks.
	 * @return {string[]}
	 */
	function blockLines(nodes, tight) {
		var blocks = [];
		var pending = [];
		function flushInline() {
			var lines = inlineLines(pending);
			pending = [];
			if (lines.length > 0) blocks.push(lines);
		}
		nodes.forEach(function (node) {
			if (node.tag === '#text' || !BLOCK_TAGS[node.tag]) {
				pending.push(node);
				return;
			}
			flushInline();
			var lines;
			switch (node.tag) {
				case 'h1':
				case 'h2':
				case 'h3':
				case 'h4':
				case 'h5':
				case 'h6': {
					var title = inlineLines(node.children).join(' ');
					lines = title ? [new Array(Number(node.tag.charAt(1)) + 1).join('#') + ' ' + title] : [];
					break;
				}
				case 'p':
				case 'summary':
				case 'dt':
				case 'dd':
					lines = inlineLines(node.children);
					break;
				case 'ul':
					lines = listLines(node, false);
					break;
				case 'ol':
					lines = listLines(node, true);
					break;
				case 'blockquote':
					lines = blockLines(node.children, false).map(function (line) {
						return line === '' ? '>' : '> ' + line;
					});
					break;
				case 'pre': {
					var code = textOf(node).replace(/\n$/, '');
					var fence = '```';
					while (code.indexOf(fence) !== -1) fence += '`';
					lines = [fence].concat(code.split('\n'), [fence]);
					break;
				}
				case 'hr':
					lines = ['---'];
					break;
				case 'table':
					lines = tableLines(node);
					break;
				default:
					lines = blockLines(node.children, tight);
			}
			if (lines.length > 0) blocks.push(lines);
		});
		flushInline();
		var out = [];
		blocks.forEach(function (lines, index) {
			if (index > 0 && !tight) out.push('');
			out = out.concat(lines);
		});
		return out;
	}

	/**
	 * Converts a rendered release-notes HTML fragment to renderer Markdown.
	 * @param {string} html - Untrusted HTML (already entity-decoded from XML).
	 * @return {string}
	 */
	function releaseNotesHtmlToMarkdown(html) {
		if (typeof html !== 'string' || html === '') return '';
		return blockLines(buildTree(html).children, false).join('\n');
	}

	// =========================================
	// =========================================
	// ======= 3/ Atom Feed ====================
	// =========================================
	// =========================================

	/** Returns the decoded text content of the first matching child element. */
	function elementText(entry, name) {
		var match = new RegExp('<' + name + '\\b([^>]*)>([\\s\\S]*?)<\\/' + name + '\\s*>').exec(entry);
		if (!match) return null;
		var raw = match[2];
		var cdata = /^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/.exec(raw);
		return cdata ? cdata[1] : decodeEntities(raw);
	}

	/** Returns the href of the entry's alternate link. */
	function alternateHref(entry) {
		var links = entry.match(/<link\b[^>]*>/g) || [];
		for (var i = 0; i < links.length; i++) {
			var rel = readAttribute(links[i], 'rel');
			if (rel === null || rel === 'alternate') {
				var href = readAttribute(links[i], 'href');
				if (href) return href;
			}
		}
		return null;
	}

	/**
	 * Parses a GitHub releases Atom feed into changelog release records.
	 * @param {string} xml - Feed document text.
	 * @param {string} owner - Expected repository owner.
	 * @param {string} repo - Expected repository name.
	 * @return {Array<{tag_name: string, body: string, html_url: string, published_at: string, prerelease: boolean}>}
	 * @throws {Error} When the text is not an Atom feed.
	 */
	function parseReleasesAtom(xml, owner, repo) {
		if (typeof xml !== 'string' || !/<feed\b[^>]*>/.test(xml)) {
			throw new Error('release feed is not an Atom document');
		}
		var prefix = 'https://github.com/' + owner + '/' + repo + '/releases/tag/';
		var releases = [];
		var entries = xml.match(/<entry\b[^>]*>[\s\S]*?<\/entry\s*>/g) || [];
		entries.forEach(function (entry) {
			var href = alternateHref(entry);
			if (!href || href.indexOf(prefix) !== 0) return;
			var encodedTag = href.slice(prefix.length);
			var tag;
			try {
				tag = decodeURIComponent(encodedTag);
			} catch (error) {
				return;
			}
			if (!/^[A-Za-z0-9._+-]+$/.test(tag)) return;
			var content = elementText(entry, 'content');
			releases.push({
				tag_name: tag,
				body: releaseNotesHtmlToMarkdown(content || ''),
				html_url: prefix + encodedTag,
				published_at: (elementText(entry, 'updated') || '').trim(),
				// GitHub does not publish the pre-release flag in the feed; the CI tag
				// families encode it (stable = plain semver, dev = semver pre-release).
				prerelease: /^v?\d+\.\d+\.\d+-/.test(tag)
			});
		});
		return releases;
	}

	global.parseReleasesAtom = parseReleasesAtom;
	global.releaseNotesHtmlToMarkdown = releaseNotesHtmlToMarkdown;
})(window);
