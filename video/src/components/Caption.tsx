// video/src/components/Caption.tsx
//
// Scene titling: a chapter chip named like the tray menu entry, a headline
// revealed word by word, and an optional supporting line.

import React from 'react';
import { useCurrentFrame, useVideoConfig } from 'remotion';
import { pop, progress, rise } from '../lib/motion';

type Props = {
	chapter?: string;
	icon?: string;
	title: string;
	sub?: string;
	delay?: number;
	align?: 'left' | 'center';
	size?: number;
};

export const Caption: React.FC<Props> = ({
	chapter,
	icon,
	title,
	sub,
	delay = 0,
	align = 'left',
	size = 64
}) => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const words = title.split(' ');
	return (
		<div
			style={{
				textAlign: align,
				display: 'flex',
				flexDirection: 'column',
				gap: 18,
				alignItems: align === 'center' ? 'center' : 'flex-start'
			}}
		>
			{chapter ? (
				<div
					style={{
						...rise(progress(frame, delay, 18), 16),
						display: 'inline-flex',
						alignItems: 'center',
						gap: 10,
						padding: '8px 16px',
						borderRadius: 999,
						border: '1px solid var(--border-strong)',
						background: 'var(--surface-strong)',
						color: 'var(--accent-blue)',
						fontSize: 22,
						fontWeight: 600,
						letterSpacing: '0.08em',
						textTransform: 'uppercase'
					}}
				>
					{icon ? <span>{icon}</span> : null}
					{chapter}
				</div>
			) : null}
			<div
				style={{
					fontSize: size,
					fontWeight: 800,
					lineHeight: 1.08,
					letterSpacing: '-0.02em',
					color: 'var(--ink)'
				}}
			>
				{words.map((w, i) => {
					const p = pop(frame, fps, delay + 6 + i * 3);
					return (
						<span
							key={i}
							style={{
								display: 'inline-block',
								marginRight: '0.26em',
								opacity: Math.min(1, p),
								transform: `translateY(${(1 - p) * 28}px)`
							}}
						>
							{w}
						</span>
					);
				})}
			</div>
			{sub ? (
				<div
					style={{
						...rise(progress(frame, delay + 14 + words.length * 3, 20), 18),
						fontSize: size * 0.42,
						color: 'var(--ink-soft)',
						fontWeight: 500,
						maxWidth: 900
					}}
				>
					{sub}
				</div>
			) : null}
		</div>
	);
};
