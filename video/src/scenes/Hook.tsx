// video/src/scenes/Hook.tsx
//
// Opening: the sales page's promise in kinetic type, then the name.

import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig } from 'remotion';
import { Pill } from '../components/Keycap';
import { Sfx } from '../components/Sound';
import { pop, progress } from '../lib/motion';
import { NAME_GRADIENT_CLASS } from '../styles';

const Line: React.FC<{ text: string; delay: number; accent?: boolean }> = ({
	text,
	delay,
	accent
}) => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	return (
		<div style={{ display: 'flex', overflow: 'hidden', paddingBottom: 12 }}>
			{[...text].map((ch, i) => {
				const p = pop(frame, fps, delay + i * 1.4);
				return (
					<span
						key={i}
						style={{
							display: 'inline-block',
							whiteSpace: 'pre',
							transform: `translateY(${(1 - Math.min(1, p)) * 120}%)`,
							color: accent ? 'var(--accent-blue)' : 'var(--ink)'
						}}
					>
						{ch}
					</span>
				);
			})}
		</div>
	);
};

export const Hook: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const lift = progress(frame, 62, 26);
	const name = pop(frame, fps, 70);
	return (
		<AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center' }}>
			<div
				style={{
					fontSize: 170,
					fontWeight: 800,
					letterSpacing: '-0.04em',
					lineHeight: 1,
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					transform: `translateY(${-lift * 170}px) scale(${1 - lift * 0.45})`
				}}
			>
				<Line text="Type less." delay={4} />
				<Line text="Write more." delay={22} accent />
			</div>
			<div
				style={{
					position: 'absolute',
					top: 560,
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					gap: 34,
					opacity: Math.min(1, name),
					transform: `scale(${0.8 + 0.2 * Math.min(1, name)})`
				}}
			>
				<div style={{ fontSize: 150, fontWeight: 800, letterSpacing: '-0.03em' }}>
					<span className={NAME_GRADIENT_CLASS}>Ergopti+</span>
				</div>
				<div
					style={{
						display: 'flex',
						gap: 18,
						opacity: interpolate(frame, [95, 110], [0, 1], {
							extrapolateLeft: 'clamp',
							extrapolateRight: 'clamp'
						})
					}}
				>
					<Pill>⚡ Augmented typing</Pill>
					<Pill>🧠 Local or API AI</Pill>
					<Pill>💸 Free & open-source</Pill>
				</div>
			</div>
			<Sfx name="whoosh" at={60} />
			<Sfx name="chime" at={72} volume={0.3} />
		</AbsoluteFill>
	);
};
