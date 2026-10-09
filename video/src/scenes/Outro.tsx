// video/src/scenes/Outro.tsx
//
// Closing card: the sales page's last line, the promise, where to get it.

import React from 'react';
import { AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { Sfx } from '../components/Sound';
import { pop, progress, rise } from '../lib/motion';
import { NAME_GRADIENT_CLASS } from '../styles';

export const Outro: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const logo = pop(frame, fps, 30);
	return (
		<AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', gap: 36 }}>
			<div
				style={{
					fontSize: 54,
					color: 'var(--ink-soft)',
					fontWeight: 600,
					...rise(progress(frame, 2, 18), 20)
				}}
			>
				Your fingers will thank you.
			</div>
			<div
				style={{
					display: 'flex',
					alignItems: 'center',
					gap: 36,
					opacity: Math.min(1, logo),
					transform: `scale(${0.85 + 0.15 * Math.min(1, logo)})`
				}}
			>
				<Img src={staticFile('img/logo/logo_simple.svg')} style={{ width: 150, height: 150 }} />
				<span style={{ fontSize: 150, fontWeight: 800, letterSpacing: '-0.03em' }}>
					<span className={NAME_GRADIENT_CLASS}>Ergopti+</span>
				</span>
			</div>
			<div style={{ fontSize: 40, fontWeight: 700, ...rise(progress(frame, 50, 16), 20) }}>
				Free. Private. Open-source.
			</div>
			<div style={{ fontSize: 30, color: 'var(--ink-soft)', ...rise(progress(frame, 60, 16), 20) }}>
				Windows · macOS · Linux
			</div>
			<div
				style={{
					fontSize: 34,
					color: 'var(--accent-blue)',
					fontWeight: 700,
					...rise(progress(frame, 70, 16), 20)
				}}
			>
				ergopti.fr/ergopti-plus
			</div>
			<Sfx name="chime" at={30} volume={0.35} />
		</AbsoluteFill>
	);
};
