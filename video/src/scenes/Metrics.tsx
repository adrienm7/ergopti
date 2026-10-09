// video/src/scenes/Metrics.tsx
//
// A guided tour of the real typing dashboard with the site's demo data: the
// scene scrolls the dashboard's own content and switches its n-gram tabs,
// while the caption on the left names what is on screen.

import React, { useCallback } from 'react';
import { AbsoluteFill, Easing, interpolate, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { DriverWindow } from '../components/DriverWindow';
import { Sfx } from '../components/Sound';
import { pop } from '../lib/motion';

/** Stops of the tour: where the dashboard scrolls, which tab it shows. */
const STOPS: Array<{ at: number; scroll: number; tab?: string; label: string }> = [
	{ at: 0, scroll: 0, label: '⚡ Keystrokes saved by AI and hotstrings' },
	{ at: 72, scroll: 590, label: '📈 Typing speed, day after day' },
	{ at: 148, scroll: 8090, tab: 'w', label: '🔤 Your most typed words' },
	{ at: 224, scroll: 8090, tab: 'sc', label: '⌨ Your most used shortcuts' },
	{ at: 300, scroll: 2600, label: '🖐 Distance per finger, ergonomics' }
];
const SCROLL_FRAMES = 40;
const SCROLL_EASING = Easing.inOut(Easing.cubic);
const SCALE = 1.28;

const stopAt = (frame: number) => STOPS.reduce((found, s, i) => (frame >= s.at ? i : found), 0);

type DashboardWindow = Window & { switch_tab: (tab: string) => void };

export const Metrics: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	// Scroll and tab as a pure function of the frame.
	const script = useCallback((raw: Window, f: number) => {
		const win = raw as DashboardWindow;
		const main = win.document.querySelector<HTMLElement>('.main-content');
		if (!main) throw new Error('The typing dashboard has no .main-content');
		const i = stopAt(f);
		const from = STOPS[Math.max(0, i - 1)].scroll;
		main.scrollTop = interpolate(
			f,
			[STOPS[i].at, STOPS[i].at + SCROLL_FRAMES],
			[from, STOPS[i].scroll],
			{
				// Eased at both ends: long jumps glide instead of flashing past.
				easing: SCROLL_EASING,
				extrapolateLeft: 'clamp',
				extrapolateRight: 'clamp'
			}
		);
		const tab = [...STOPS.slice(0, i + 1)].reverse().find((s) => s.tab)?.tab;
		const active = win.document.querySelector('button[data-tab].active') as HTMLElement | null;
		if (tab && active?.dataset.tab !== tab) win.switch_tab(tab);
	}, []);
	const current = stopAt(frame);
	const enter = Math.min(1, pop(frame, fps, 2));
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 100, top: 90, width: 470 }}>
				<Caption chapter="Metrics" icon="📊" title="Know how you type." size={56} />
				<div style={{ display: 'flex', flexDirection: 'column', gap: 14, marginTop: 40 }}>
					{STOPS.map((s, i) => (
						<div
							key={s.label}
							style={{
								fontSize: 26,
								padding: '12px 18px',
								borderRadius: 14,
								background:
									i === current ? 'color-mix(in srgb, #00bfa5 26%, transparent)' : 'transparent',
								border: `1px solid ${i === current ? '#00bfa5' : 'transparent'}`,
								color: i === current ? '#fff' : 'var(--ink-faint)',
								fontWeight: i === current ? 700 : 500
							}}
						>
							{s.label}
						</div>
					))}
				</div>
				<div style={{ fontSize: 22, color: 'var(--ink-faint)', marginTop: 30 }}>
					All stored locally, in a database you own.
				</div>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 560,
					top: 70,
					opacity: enter,
					transform: `translateX(${(1 - enter) * 120}px)`
				}}
			>
				<DriverWindow id="metrics_typing" title="Typing metrics" scale={SCALE} script={script} />
			</div>
			{STOPS.slice(1).map((s) => (
				<Sfx key={s.at} name="whoosh" at={s.at} volume={0.2} />
			))}
		</AbsoluteFill>
	);
};
