// video/src/scenes/Shortcuts.tsx
//
// Every shortcut is the user's: the recommended Win + letter slots from the
// features manifest, each shown as one choice among the catalogue's actions.

import React from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { bareLabel, FACTS, SHORTCUTS } from '../lib/data';
import { pop } from '../lib/motion';
import { MONO } from '../styles';

export const Shortcuts: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 90, width: 1650 }}>
				<Caption
					chapter="Shortcuts"
					icon="🎯"
					title="Every shortcut is yours."
					sub={`Win + letter (Ctrl + letter on macOS), each set to any of ${FACTS.actions.windows} actions. Here are the recommended ones.`}
					size={68}
				/>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 120,
					right: 120,
					top: 420,
					display: 'grid',
					gridTemplateColumns: 'repeat(3, 1fr)',
					gap: 18
				}}
			>
				{SHORTCUTS.map((slot, i) => {
					const p = Math.min(1, pop(frame, fps, 16 + i * 3));
					return (
						<div
							key={slot.action}
							style={{
								display: 'flex',
								alignItems: 'center',
								gap: 18,
								padding: '16px 22px',
								borderRadius: 16,
								background: 'var(--surface-strong)',
								border: '1px solid var(--border)',
								opacity: p,
								transform: `translateY(${(1 - p) * 30}px)`
							}}
						>
							<span
								style={{
									fontFamily: MONO,
									fontSize: 24,
									color: 'var(--accent-blue)',
									minWidth: 120
								}}
							>
								{slot.windows}
							</span>
							<span
								style={{
									fontSize: 26,
									whiteSpace: 'nowrap',
									overflow: 'hidden',
									textOverflow: 'ellipsis'
								}}
							>
								{bareLabel(slot.label)}
							</span>
						</div>
					);
				})}
			</div>
		</AbsoluteFill>
	);
};
