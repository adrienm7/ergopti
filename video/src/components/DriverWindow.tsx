// video/src/components/DriverWindow.tsx
//
// One of the driver's real webview windows, live: its own HTML/JS/CSS served
// from static/ through video/public/, populated by the same host module the
// website uses. A UI change in the driver shows up at the next render.

import React, { useCallback, useLayoutEffect, useRef, useState } from 'react';
import {
	cancelRender,
	continueRender,
	delayRender,
	IFrame,
	staticFile,
	useCurrentFrame
} from 'remotion';
import {
	driverWindowSrc,
	hostDriverWindow,
	settleDriverWindow
} from '../../../src/lib/js/driverWindowHost.js';
import { webviewSize } from '../lib/data';
import { OsWindow, chromeHeight, type Os } from './OsWindow';

/**
 * Show a window in its own dark theme. The windows follow
 * prefers-color-scheme, which headless Chrome reports as light; turning the
 * page's dark media rules on keeps its real stylesheet, and the matchMedia
 * answer covers scripts that pick chart colours.
 * @param win - The window's contentWindow.
 */
function forceDarkScheme(win: Window): void {
	const flip = (rules: CSSRuleList) => {
		for (const rule of Array.from(rules)) {
			// Duck-typed: the iframe's CSSMediaRule is another realm's class.
			if (!('media' in rule && 'cssRules' in rule)) continue;
			const media = rule as CSSMediaRule;
			const text = media.media.mediaText;
			if (/prefers-color-scheme:\s*dark/.test(text)) media.media.mediaText = 'all';
			else if (/prefers-color-scheme:\s*light/.test(text)) media.media.mediaText = 'not all';
			flip(media.cssRules);
		}
	};
	for (const sheet of Array.from(win.document.styleSheets)) flip(sheet.cssRules);
	const native = win.matchMedia.bind(win);
	win.matchMedia = (query: string) =>
		/prefers-color-scheme/.test(query)
			? native(/dark/.test(query) ? 'all' : 'not all')
			: native(query);
	win.document.documentElement.style.colorScheme = 'dark';
}

/**
 * Frames are captured out of order, so a window's look must depend on the
 * frame alone: its own CSS transitions and animations, and its charts'
 * animations, are switched off.
 * @param win - The window's contentWindow.
 */
function freezeMotion(win: Window): void {
	const style = win.document.createElement('style');
	style.textContent = '*,*::before,*::after{transition:none!important;animation:none!important}';
	win.document.head.appendChild(style);
	// Chart.js draws on canvas, out of the DOM's sight, and animates every new
	// chart: a tab captured mid-animation shows another curve than its
	// neighbours. Its windows load it before the host fills them.
	const chart = (win as Window & { Chart?: { defaults: { animation: unknown } } }).Chart;
	if (chart) chart.defaults.animation = false;
}

/**
 * One instant for every rendering tab: today at noon. The dashboards place
 * "now" on their time axes, and tabs started milliseconds apart would draw
 * their curves slightly apart.
 */
const FROZEN_NOW = (() => {
	const noon = new Date();
	noon.setHours(12, 0, 0, 0);
	return noon.getTime();
})();

/**
 * Stops the window's clock at FROZEN_NOW, so what it draws from the current
 * time is the same in every tab and at every frame.
 * @param win - The window's contentWindow.
 */
function freezeClock(win: Window): void {
	const Native = (win as Window & { Date: DateConstructor }).Date;
	class FrozenDate extends Native {
		constructor(...args: unknown[]) {
			if (args.length === 0) super(FROZEN_NOW);
			else super(...(args as [string | number | Date]));
		}
		static now() {
			return FROZEN_NOW;
		}
	}
	(win as Window & { Date: DateConstructor }).Date = FrozenDate as unknown as DateConstructor;
}

/** Animation frames of the window to wait after a scripted change. */
const PAINT_FRAMES = 4;
/** DOM silence that counts as "done computing", after loading and after a scripted change. */
const QUIET_AFTER_LOAD_MS = 800;
const QUIET_AFTER_SCRIPT_MS = 150;
/** Longest a window may keep changing before the render fails. */
const QUIET_TIMEOUT_MS = 30000;

/**
 * Resolves once the window's DOM has not changed for `quietMs`. The dashboards
 * keep computing in chunks after their data arrives ("Computing…" blocks,
 * tables filled later); Remotion renders in several tabs at once, so a tab
 * captured before that work ends shows another state than its neighbours and
 * the film flickers between them.
 * @param win - The window's contentWindow.
 * @param quietMs - Silence required.
 * @param label - Names the window in the timeout error.
 */
function whenQuiet(win: Window, quietMs: number, label: string): Promise<void> {
	return new Promise((resolve, reject) => {
		let timer = win.setTimeout(done, quietMs);
		const observer = new MutationObserver(() => {
			win.clearTimeout(timer);
			timer = win.setTimeout(done, quietMs);
		});
		const deadline = win.setTimeout(() => {
			observer.disconnect();
			win.clearTimeout(timer);
			reject(new Error(`${label} kept changing for ${QUIET_TIMEOUT_MS} ms`));
		}, QUIET_TIMEOUT_MS);
		function done() {
			observer.disconnect();
			win.clearTimeout(deadline);
			resolve();
		}
		observer.observe(win.document, {
			subtree: true,
			childList: true,
			attributes: true,
			characterData: true
		});
	});
}

/**
 * Resolves after a few of the window's animation frames, so what changed is painted.
 * @param win - The window's contentWindow.
 */
function whenPainted(win: Window): Promise<void> {
	return new Promise((resolve) => {
		let left = PAINT_FRAMES;
		const tick = () => (--left > 0 ? win.requestAnimationFrame(tick) : resolve());
		win.requestAnimationFrame(tick);
	});
}

/** URL prefix under which video/public/ mirrors static/. */
const STATIC_BASE = staticFile('demo').replace(/\/demo$/, '');

type Props = {
	id: string;
	os?: Os;
	title?: string;
	/** Display scale of the native-size window. */
	scale?: number;
	/** Drives the window from the frame (scroll, highlight); must be a pure function of the frame. */
	script?: (win: Window, frame: number) => void;
	/** Runs once the window shows its data, before the first capture (to measure it). */
	onReady?: (win: Window) => void;
	/** Drawn over the window's content, in the window's own pixels (a cursor). */
	overlay?: React.ReactNode;
	style?: React.CSSProperties;
};

export const DriverWindow: React.FC<Props> = ({
	id,
	os = 'windows',
	title,
	scale = 1,
	script,
	onReady,
	overlay,
	style
}) => {
	const { width, height } = webviewSize(id);
	const frame = useCurrentFrame();
	const ref = useRef<HTMLIFrameElement>(null);
	const [handle] = useState(() => delayRender(`Driver window ${id}`));
	const [ready, setReady] = useState(false);

	const onLoad = useCallback(() => {
		const win = ref.current?.contentWindow;
		if (!win) return cancelRender(new Error(`Driver window ${id} has no content window`));
		forceDarkScheme(win);
		freezeMotion(win);
		freezeClock(win);
		hostDriverWindow(win, id, { base: STATIC_BASE, locale: 'en', animate: false })
			// Let the injected data lay out, the fonts settle and the window
			// finish its own computations before any capture.
			.then(() => win.document.fonts.ready)
			.then(() => whenQuiet(win, QUIET_AFTER_LOAD_MS, `Driver window ${id}`))
			// Idle is not final: charts drawn early on canvas leave no DOM trace.
			// One last idempotent redraw gives every rendering tab the same state.
			.then(() => settleDriverWindow(win, id))
			.then(() => whenQuiet(win, QUIET_AFTER_LOAD_MS, `Driver window ${id}`))
			.then(() => whenPainted(win))
			.then(() => {
				onReady?.(win);
				setReady(true);
				// Release the capture only after React committed what onReady set.
				setTimeout(() => continueRender(handle), 50);
			})
			.catch((e: Error) =>
				cancelRender(new Error(`Driver window ${id} failed to populate: ${e.message}`))
			);
	}, [handle, id, onReady]);

	useLayoutEffect(() => {
		const win = ref.current?.contentWindow;
		if (!ready || !win || !script) return;
		script(win, frame);
		// A scripted change (a tab switch) can start more computation, and the
		// iframe paints on its own schedule: captured at once, a frame can show
		// a half-built table or the previous scroll position.
		const paint = delayRender(`Driver window ${id} frame ${frame}`);
		whenQuiet(win, QUIET_AFTER_SCRIPT_MS, `Driver window ${id} at frame ${frame}`)
			.then(() => whenPainted(win))
			.then(() => continueRender(paint))
			.catch((e: Error) => cancelRender(e));
	}, [frame, id, ready, script]);

	const chrome = chromeHeight(os);
	return (
		<div style={{ width: width * scale, height: (height + chrome) * scale, ...style }}>
			<OsWindow
				os={os}
				title={title ?? id}
				width={width}
				height={height + chrome}
				style={{ transform: `scale(${scale})`, transformOrigin: 'top left' }}
				bodyStyle={{ overflow: 'hidden' }}
			>
				<IFrame
					ref={ref}
					src={driverWindowSrc(id, STATIC_BASE)}
					onLoad={onLoad}
					style={{ width, height, border: 0, display: 'block', background: '#1e1e1e' }}
				/>
				{overlay}
			</OsWindow>
		</div>
	);
};
