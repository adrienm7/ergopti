// video/src/scenes/ScreenTime.tsx
//
// The real screen-time dashboard with the site's demo data, scrolled down to
// what matters most: the time spent in each app over the period, then the
// day's timeline.

import React, { useCallback } from 'react';
import { AbsoluteFill, Easing, interpolate, useCurrentFrame } from 'remotion';
import { Caption } from '../components/Caption';
import { DriverWindow } from '../components/DriverWindow';
import { progress } from '../lib/motion';

/** Scroll stops of the dashboard's .main-content, from its own layout. */
const STOPS: Array<{ at: number; scroll: number; label: string }> = [
	{ at: 0, scroll: 0, label: '⏱ Screen time and productivity' },
	{ at: 50, scroll: 410, label: '📊 Time per app, per category' },
	{ at: 160, scroll: 740, label: '🕘 How the day went' }
];
const SCROLL_FRAMES = 40;
const SCROLL_EASING = Easing.inOut(Easing.cubic);

const stopAt = (frame: number) => STOPS.reduce((found, s, i) => (frame >= s.at ? i : found), 0);

export const ScreenTime: React.FC = () => {
	const frame = useCurrentFrame();
	const enter = progress(frame, 0, 24);
	const script = useCallback((win: Window, f: number) => {
		const main = win.document.querySelector<HTMLElement>('.main-content');
		if (!main) throw new Error('The screen-time dashboard has no .main-content');
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
	}, []);
	const current = stopAt(frame);
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 100, top: 110, width: 520 }}>
				<Caption chapter="Metrics" icon="⏱" title="Where your time goes, app by app." size={54} />
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
			</div>
			<div
				style={{
					position: 'absolute',
					left: 640,
					top: 80,
					opacity: enter,
					transform: `scale(${0.96 + enter * 0.04})`,
					transformOrigin: 'top left'
				}}
			>
				<DriverWindow id="metrics_apps" title="Screen time" scale={1.25} script={script} />
			</div>
		</AbsoluteFill>
	);
};
