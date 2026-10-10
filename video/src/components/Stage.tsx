// video/src/components/Stage.tsx
//
// The ground every scene stands on: the site's navy gradient, the Ergopti+
// page tokens, and two slow light blooms that keep a still frame alive.

import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame } from 'remotion';
import { BG_CLASS, SANS, TOKENS_CLASS } from '../styles';

export const Stage: React.FC<{ children: React.ReactNode; bloom?: string }> = ({
	children,
	bloom = 'var(--accent-blue)'
}) => {
	const frame = useCurrentFrame();
	const drift = interpolate(frame, [0, 600], [0, 1], { extrapolateRight: 'extend' });
	return (
		<AbsoluteFill
			className={`${BG_CLASS} ${TOKENS_CLASS}`}
			style={{ fontFamily: SANS, overflow: 'hidden' }}
		>
			<AbsoluteFill
				style={{
					background: `radial-gradient(40% 50% at ${30 + Math.sin(drift * 3) * 8}% ${35 + Math.cos(drift * 2) * 6}%, color-mix(in srgb, ${bloom} 22%, transparent), transparent 70%)`
				}}
			/>
			<AbsoluteFill
				style={{
					background: `radial-gradient(35% 45% at ${75 + Math.cos(drift * 2.5) * 6}% ${70 + Math.sin(drift * 2) * 6}%, color-mix(in srgb, var(--accent-cyan) 14%, transparent), transparent 70%)`
				}}
			/>
			{children}
		</AbsoluteFill>
	);
};
