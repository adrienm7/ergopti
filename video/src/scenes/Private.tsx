// video/src/scenes/Private.tsx
//
// The privacy promises of the sales page, and how far the settings go.

import React from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { FACTS } from '../lib/data';
import { pop, progress, rise } from '../lib/motion';

const CARDS = [
	{
		icon: '🔒',
		title: 'Local by default',
		text: 'Typing, hotstrings and metrics never leave your machine. AI runs locally, or through the API you pick.'
	},
	{
		icon: '🚫',
		title: 'No telemetry',
		text: 'No account, no tracking, no “anonymous statistics”.'
	},
	{ icon: '🙈', title: 'Passwords ignored', text: 'Secure fields are never captured or logged.' },
	{
		icon: '🔑',
		title: 'Encrypted API keys',
		text: 'Optional remote models use keys encrypted by the OS.'
	},
	{
		icon: '🗄️',
		title: 'Your data',
		text: 'Metrics live in a local SQLite file you can read or delete.'
	},
	{ icon: '👁️', title: 'Open source', text: 'Anyone can check what the driver really does.' }
];

export const Private: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 100 }}>
				<Caption chapter="Privacy" icon="🔐" title="Your typing stays yours." size={70} />
			</div>
			<div
				style={{
					position: 'absolute',
					left: 120,
					right: 120,
					top: 330,
					display: 'grid',
					gridTemplateColumns: 'repeat(3, 1fr)',
					gap: 26
				}}
			>
				{CARDS.map((c, i) => {
					const p = pop(frame, fps, 14 + i * 6);
					return (
						<div
							key={c.title}
							style={{
								opacity: Math.min(1, p),
								transform: `translateY(${(1 - Math.min(1, p)) * 40}px)`,
								padding: '30px 32px',
								borderRadius: 20,
								background: 'var(--surface-strong)',
								border: '1px solid var(--border)'
							}}
						>
							<div style={{ fontSize: 46 }}>{c.icon}</div>
							<div style={{ fontSize: 34, fontWeight: 700, marginTop: 12 }}>{c.title}</div>
							<div
								style={{ fontSize: 24, color: 'var(--ink-soft)', marginTop: 8, lineHeight: 1.4 }}
							>
								{c.text}
							</div>
						</div>
					);
				})}
			</div>
			<div
				style={{
					position: 'absolute',
					left: 0,
					right: 0,
					top: 900,
					textAlign: 'center',
					fontSize: 32,
					color: 'var(--ink-soft)',
					...rise(progress(frame, 80, 20), 20)
				}}
			>
				Every feature optional · {FACTS.locales} interface languages · free, no account
			</div>
		</AbsoluteFill>
	);
};
