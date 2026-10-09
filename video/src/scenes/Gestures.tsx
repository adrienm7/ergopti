// video/src/scenes/Gestures.tsx
//
// Trackpad gestures: a three-finger tap shows a definition, a three-finger
// swipe changes the volume. The slot count is measured from the menu
// manifest.

import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame } from 'remotion';
import { Caption } from '../components/Caption';
import { OsWindow } from '../components/OsWindow';
import { Sfx } from '../components/Sound';
import { FACTS } from '../lib/data';
import { progress, rise } from '../lib/motion';

const TAP_AT = 40;
const SWIPE_AT = 110;

const Fingers: React.FC<{ x: number; y: number; opacity: number; press: number }> = ({
	x,
	y,
	opacity,
	press
}) => (
	<>
		{[-70, 0, 70].map((dx, i) => (
			<div
				key={i}
				style={{
					position: 'absolute',
					left: x + dx - 28,
					top: y + (i === 1 ? -22 : 0) - 28,
					width: 56,
					height: 56,
					borderRadius: 28,
					background: 'rgba(255,255,255,0.85)',
					opacity,
					transform: `scale(${1 - press * 0.18})`,
					boxShadow: `0 0 ${30 + press * 30}px rgba(49,190,255,${0.4 + press * 0.4})`
				}}
			/>
		))}
	</>
);

export const Gestures: React.FC = () => {
	const frame = useCurrentFrame();
	const tapIn = interpolate(
		frame,
		[TAP_AT - 14, TAP_AT - 4, TAP_AT + 8, TAP_AT + 16],
		[0, 1, 1, 0],
		{ extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }
	);
	const tapPress = Math.max(0, 1 - Math.abs(frame - TAP_AT) / 4);
	const definition = progress(frame, TAP_AT + 2, 14);
	const swipe = progress(frame, SWIPE_AT, 40);
	const swipeIn = interpolate(
		frame,
		[SWIPE_AT - 10, SWIPE_AT, SWIPE_AT + 40, SWIPE_AT + 50],
		[0, 1, 1, 0],
		{ extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }
	);
	const volume = interpolate(swipe, [0, 1], [0.35, 0.85]);
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 110, width: 900 }}>
				<Caption
					chapter="Gestures"
					icon="🖐"
					title={`Up to ${FACTS.gestureSlots} trackpad gestures.`}
					sub="Taps and swipes with 2 to 5 fingers, each mapped to any action. 10 slots on Windows."
					size={64}
				/>
			</div>
			<div style={{ position: 'absolute', left: 120, top: 520 }}>
				<OsWindow
					os="macos"
					title="Article — Safari"
					width={800}
					height={400}
					bodyStyle={{ padding: '40px 46px', fontSize: 32, lineHeight: 1.6, color: '#ddd' }}
				>
					Good keyboard{' '}
					<span style={{ background: `rgba(49,190,255,${definition * 0.35})`, borderRadius: 6 }}>
						ergonomics
					</span>{' '}
					starts with fewer keystrokes.
					<div
						style={{
							position: 'absolute',
							left: 230,
							top: 150,
							width: 520,
							padding: '20px 24px',
							borderRadius: 14,
							background: '#2a2a30',
							border: '1px solid rgba(255,255,255,0.15)',
							boxShadow: '0 24px 50px rgba(0,0,0,0.5)',
							fontSize: 24,
							lineHeight: 1.45,
							...rise(definition, 20)
						}}
					>
						<div style={{ fontWeight: 700, color: '#fff', fontSize: 28 }}>ergonomics</div>
						<div style={{ color: '#bbb' }}>
							The study of people’s efficiency in their working environment.
						</div>
					</div>
				</OsWindow>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 1040,
					top: 470,
					width: 740,
					height: 480,
					borderRadius: 34,
					background: 'linear-gradient(160deg, #2c2f38, #1d1f26)',
					border: '1px solid rgba(255,255,255,0.12)',
					boxShadow: 'inset 0 2px 0 rgba(255,255,255,0.08), 0 40px 80px rgba(0,0,0,0.45)'
				}}
			>
				<Fingers x={370} y={250} opacity={tapIn} press={tapPress} />
				<Fingers x={370} y={330 - swipe * 200} opacity={swipeIn} press={0.3} />
				<div
					style={{
						position: 'absolute',
						right: 30,
						top: 60,
						bottom: 60,
						width: 18,
						borderRadius: 9,
						background: 'rgba(255,255,255,0.1)',
						opacity: swipeIn > 0 || frame > SWIPE_AT ? 1 : 0
					}}
				>
					<div
						style={{
							position: 'absolute',
							bottom: 0,
							width: '100%',
							height: `${volume * 100}%`,
							borderRadius: 9,
							background: 'var(--accent-blue)'
						}}
					/>
				</div>
				<div
					style={{
						position: 'absolute',
						left: 30,
						bottom: 24,
						fontSize: 24,
						color: 'var(--ink-soft)'
					}}
				>
					{frame < SWIPE_AT - 10 ? '3 fingers · tap → definition' : '3 fingers · swipe ↑ → volume'}
				</div>
			</div>
			<Sfx name="key" at={TAP_AT} />
			<Sfx name="pop" at={TAP_AT + 3} volume={0.3} />
			<Sfx name="whoosh" at={SWIPE_AT} volume={0.25} />
		</AbsoluteFill>
	);
};
