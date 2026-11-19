// _shared/ui/layout_analysis/board/board_image.js

/**
 * ==============================================================================
 * MODULE: Board Images
 * DESCRIPTION:
 * Saves a drawn keyboard (the editor's board, the Comparer's heatmaps) as an
 * SVG or a PNG image, to share a layout or a heatmap outside the Studio. In
 * the app the file goes through the host's download path (the Downloads
 * folder on Windows, macOS and Linux, LAYOUT_ANALYSIS_HOST.saveBinary); on the
 * site the browser downloads it.
 *
 * FEATURES & RATIONALE:
 * 1. Drawn from what the page shows: each key's box, outline, legend and
 *    colour as laid out and styled, read from the page (getBoundingClientRect,
 *    getComputedStyle), so the image matches the screen in either theme.
 * 2. Plain SVG (rectangles, paths, text): no foreignObject, which WebKit
 *    refuses to draw into a canvas, so the PNG is the same SVG rasterised at
 *    twice its size on every OS's WebView.
 * 3. A heat colour is a gradient slid under the key (the boards' scale trick):
 *    its colour is the gradient's at the key's position, every CSS colour
 *    resolved to sRGB by a canvas.
 * 4. Fail fast: a board without keys or a save the host refuses rejects with
 *    a code the page words.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_BOARD_IMAGE = (function () {
	'use strict';

	const SVG_NS = 'http://www.w3.org/2000/svg';
	// The margin around the keys and the title's line, in CSS pixels.
	const PADDING = 16;
	const TITLE_HEIGHT = 30;
	// The PNG's pixels per CSS pixel.
	const PNG_SCALE = 2;
	// A file name the hosts write: ASCII letters, digits, « - », at most this long.
	const MAX_SLUG = 60;
	const FORMATS = Object.freeze({ png: 'image/png', svg: 'image/svg+xml' });

	let probe = null;

	/**
	 * Any CSS colour (rgb, oklab, color-mix already resolved by the page…) as
	 * sRGB components, through a canvas pixel the page drew itself.
	 * @param {string} color
	 * @returns {number[]} [r, g, b, a] with a in 0–1.
	 */
	function rgba(color) {
		if (!probe) {
			const canvas = document.createElement('canvas');
			canvas.width = 1;
			canvas.height = 1;
			probe = canvas.getContext('2d', { willReadFrequently: true });
		}
		probe.clearRect(0, 0, 1, 1);
		probe.fillStyle = 'rgba(0, 0, 0, 0)';
		probe.fillStyle = color;
		probe.fillRect(0, 0, 1, 1);
		const [r, g, b, a] = probe.getImageData(0, 0, 1, 1).data;
		return [r, g, b, a / 255];
	}

	const css = ([r, g, b, a]) => `rgba(${r}, ${g}, ${b}, ${Math.round(a * 1000) / 1000})`;

	/** The top-level comma-separated parts of a CSS function's arguments. */
	function argumentsOf(text) {
		const open = text.indexOf('(');
		const parts = [];
		let depth = 0;
		let start = open + 1;
		for (let i = start; i < text.length; i++) {
			const ch = text[i];
			if (ch === '(') depth++;
			else if (ch === ')') {
				if (depth === 0) {
					parts.push(text.slice(start, i).trim());
					break;
				}
				depth--;
			} else if (ch === ',' && depth === 0) {
				parts.push(text.slice(start, i).trim());
				start = i + 1;
			}
		}
		return parts;
	}

	/**
	 * The colour of a left-to-right linear gradient at a fraction of its length.
	 * @param {string} gradient - A computed linear-gradient().
	 * @param {number} at - 0–1.
	 * @returns {number[]} rgba.
	 */
	function gradientAt(gradient, at) {
		const parts = argumentsOf(gradient).filter((part) => !/^(to |-?[\d.]+deg)/.test(part));
		const stops = parts.map((part, index) => {
			const position = /\s(-?[\d.]+)%$/.exec(part);
			return {
				color: rgba(position ? part.slice(0, position.index) : part),
				at: position ? Number(position[1]) / 100 : index / Math.max(1, parts.length - 1)
			};
		});
		if (stops.length === 0) throw new Error('board_image: a gradient without stops');
		if (at <= stops[0].at) return stops[0].color;
		for (let i = 1; i < stops.length; i++)
			if (at <= stops[i].at) {
				const [a, b] = [stops[i - 1], stops[i]];
				const f = b.at > a.at ? (at - a.at) / (b.at - a.at) : 0;
				return a.color.map((value, k) => value + (b.color[k] - value) * f);
			}
		return stops[stops.length - 1].color;
	}

	/** What an element paints behind itself: its slid gradient's colour, else its colour. */
	function paintOf(style) {
		const image = style.backgroundImage;
		if (image && image.startsWith('linear-gradient')) {
			const position = parseFloat(String(style.backgroundPositionX).split(',')[0]);
			return gradientAt(image, Number.isFinite(position) ? position / 100 : 0);
		}
		return rgba(style.backgroundColor);
	}

	/** The first painted background from an element up, the page's last. */
	function backdropOf(node) {
		for (let n = node; n; n = n.parentElement) {
			const color = rgba(getComputedStyle(n).backgroundColor);
			if (color[3] > 0) return color;
		}
		return rgba(getComputedStyle(document.body).backgroundColor);
	}

	function svgNode(tag, attributes, text) {
		const node = document.createElementNS(SVG_NS, tag);
		for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, String(value));
		if (text !== undefined) node.textContent = text;
		return node;
	}

	const round = (value) => Math.round(value * 100) / 100;

	/**
	 * The SVG of a drawn board.
	 * @param {Element} board - The board: its keys carry data-code.
	 * @param {{title?: string, legend?: string}} [options] - title: a line above
	 *   the keys; legend: the selector of a key's legend elements, the first
	 *   with text drawn (the key's own text when absent or none has text).
	 * @returns {{text: string, width: number, height: number}}
	 * @throws {Error} board_image_empty when no key is drawn.
	 */
	function svgOf(board, options) {
		const opts = options || {};
		const frame = board.getBoundingClientRect();
		const keys = [...board.querySelectorAll('[data-code]')].filter((key) => {
			const box = key.getBoundingClientRect();
			return box.width > 0 && box.height > 0;
		});
		if (keys.length === 0) {
			const error = new Error('board_image: no key is drawn');
			error.code = 'board_image_empty';
			throw error;
		}
		const top = opts.title ? TITLE_HEIGHT : 0;
		const width = Math.ceil(frame.width + 2 * PADDING);
		const height = Math.ceil(frame.height + 2 * PADDING + top);
		const svg = svgNode('svg', {
			xmlns: SVG_NS,
			width,
			height,
			viewBox: `0 0 ${width} ${height}`
		});
		const pageText = getComputedStyle(board).color;
		svg.append(svgNode('rect', { width, height, fill: css(backdropOf(board)) }));
		if (opts.title)
			svg.append(
				svgNode(
					'text',
					{
						x: PADDING,
						y: PADDING + 14,
						'font-family': 'system-ui, sans-serif',
						'font-size': 15,
						'font-weight': 600,
						fill: css(rgba(pageText))
					},
					opts.title
				)
			);
		for (const key of keys) {
			const box = key.getBoundingClientRect();
			const x = round(box.left - frame.left + PADDING);
			const y = round(box.top - frame.top + PADDING + top);
			const style = getComputedStyle(key);
			const group = svgNode('g', {});
			const shape = key.querySelector('svg path');
			const fill = paintOf(style);
			if (shape) {
				// An L-shaped key (the ISO Enter): its own path, scaled to its box.
				const view = shape.ownerSVGElement.viewBox.baseVal;
				const shapeStyle = getComputedStyle(shape);
				const painted = fill[3] > 0 ? fill : rgba(shapeStyle.fill);
				group.append(
					svgNode('path', {
						d: shape.getAttribute('d'),
						transform: `translate(${x} ${y}) scale(${round(box.width / view.width)} ${round(box.height / view.height)})`,
						fill: css(painted[3] > 0 ? painted : backdropOf(key)),
						stroke: css(rgba(shapeStyle.stroke)),
						'stroke-width': 1,
						'vector-effect': 'non-scaling-stroke'
					})
				);
			} else
				group.append(
					svgNode('rect', {
						x,
						y,
						width: round(box.width),
						height: round(box.height),
						rx: parseFloat(style.borderTopLeftRadius) || 0,
						fill: css(fill),
						stroke: css(rgba(style.borderTopColor)),
						'stroke-width': parseFloat(style.borderTopWidth) || 0
					})
				);
			// The first legend with text: a character, else a named key's name (Esc, Shift).
			const legend =
				(opts.legend &&
					[...key.querySelectorAll(opts.legend)].find((node) => node.textContent.trim() !== '')) ||
				key;
			const text = legend.textContent;
			if (text.trim() !== '') {
				const legendStyle = getComputedStyle(legend);
				group.append(
					svgNode(
						'text',
						{
							x: round(x + box.width / 2),
							y: round(y + box.height / 2),
							'text-anchor': 'middle',
							'dominant-baseline': 'central',
							'font-family': 'system-ui, sans-serif',
							'font-size': parseFloat(legendStyle.fontSize) || 14,
							fill: css(rgba(legendStyle.color))
						},
						text.trim()
					)
				);
			}
			svg.append(group);
		}
		return { text: new XMLSerializer().serializeToString(svg), width, height };
	}

	/**
	 * The PNG of an SVG, rasterised at PNG_SCALE.
	 * @param {{text: string, width: number, height: number}} image - From svgOf.
	 * @returns {Promise<Uint8Array>}
	 */
	async function pngOf(image) {
		const url = URL.createObjectURL(new Blob([image.text], { type: FORMATS.svg }));
		try {
			const picture = new Image();
			picture.src = url;
			await picture.decode();
			const canvas = document.createElement('canvas');
			canvas.width = image.width * PNG_SCALE;
			canvas.height = image.height * PNG_SCALE;
			canvas.getContext('2d').drawImage(picture, 0, 0, canvas.width, canvas.height);
			const blob = await new Promise((resolve, reject) =>
				canvas.toBlob(
					(made) => (made ? resolve(made) : reject(new Error('board_image: no PNG'))),
					FORMATS.png
				)
			);
			return new Uint8Array(await blob.arrayBuffer());
		} finally {
			URL.revokeObjectURL(url);
		}
	}

	/**
	 * A file name the hosts write (ASCII letters, digits and dashes).
	 * @param {string[]} words - Its parts (a layout name, « heatmap », a metric).
	 * @param {string} format - 'png' or 'svg'.
	 * @returns {string}
	 */
	function fileName(words, format) {
		const slug = words
			.join('-')
			.normalize('NFKD')
			.replace(/[̀-ͯ]/g, '')
			.toLowerCase()
			.replace(/[^a-z0-9]+/g, '-')
			.replace(/^-+|-+$/g, '')
			.slice(0, MAX_SLUG)
			.replace(/-+$/, '');
		return `${slug || 'keyboard'}.${format}`;
	}

	/** A browser download (the site). */
	function download(name, bytes, mime) {
		const url = URL.createObjectURL(new Blob([bytes], { type: mime }));
		const link = document.createElement('a');
		link.href = url;
		link.download = name;
		document.body.append(link);
		link.click();
		link.remove();
		setTimeout(() => URL.revokeObjectURL(url), 0);
	}

	/**
	 * Draws a board and saves it: through the app host's download path when it
	 * has one (LAYOUT_ANALYSIS_HOST.saveBinary), else as a browser download.
	 * @param {Element} board
	 * @param {'png'|'svg'} format
	 * @param {{title?: string, legend?: string, words: string[]}} options
	 * @returns {Promise<{name: string, path: (string|null)}>} path: where the host wrote it.
	 */
	async function save(board, format, options) {
		if (!FORMATS[format]) throw new Error(`board_image: unknown format ${format}`);
		const image = svgOf(board, options);
		const bytes = format === 'svg' ? new TextEncoder().encode(image.text) : await pngOf(image);
		const name = fileName(options.words, format);
		const host = window.LAYOUT_ANALYSIS_HOST || {};
		if (typeof host.saveBinary === 'function')
			return { name, path: await host.saveBinary(name, bytes, FORMATS[format]) };
		download(name, bytes, FORMATS[format]);
		return { name, path: null };
	}

	/**
	 * Two buttons (PNG, SVG) that save a board, and the status they report in.
	 * @param {{board: function(): Element, options: function(): object, id: string}} spec
	 *   board finds the board when clicked; options gives svgOf's options and
	 *   the file name's words.
	 * @returns {HTMLElement} The group.
	 */
	function buttons(spec) {
		const t = window.LAYOUT_ANALYSIS_INFO.t;
		const group = document.createElement('div');
		group.className = 'la-image-buttons';
		group.setAttribute('role', 'group');
		group.setAttribute('aria-label', t('layout_analysis.image.label'));
		const status = document.createElement('span');
		status.className = 'la-image-status';
		status.setAttribute('role', 'status');
		const label = document.createElement('span');
		label.className = 'la-image-label';
		label.textContent = t('layout_analysis.image.label');
		label.setAttribute('aria-hidden', 'true');
		group.append(label);
		for (const format of Object.keys(FORMATS)) {
			const button = document.createElement('button');
			button.type = 'button';
			button.className = 'la-image-save';
			button.id = `${spec.id}-${format}`;
			button.textContent = t(`layout_analysis.image.${format}`);
			button.addEventListener('click', async () => {
				button.disabled = true;
				try {
					const saved = await save(spec.board(), format, spec.options());
					status.textContent = saved.path
						? t('layout_analysis.image.saved_at', { path: saved.path })
						: t('layout_analysis.image.saved', { name: saved.name });
				} catch (error) {
					status.textContent = t('layout_analysis.image.failed', {
						reason: (error && (error.code || error.message)) || 'error'
					});
				} finally {
					button.disabled = false;
				}
			});
			group.append(button);
		}
		group.append(status);
		return group;
	}

	return { svgOf, pngOf, fileName, save, buttons, gradientAt, FORMATS };
})();
