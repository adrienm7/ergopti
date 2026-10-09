// video/src/scenes/Real.tsx
//
// Proof: screen recordings of the installed driver, listed in
// assets/real/clips.json by scripts/record-screen.ps1. Each clip plays its
// recorded segments in order. A clip recorded before predictions were
// accepted on first sight may skip the wait for alternatives, never the wait
// for the prediction itself.

import React from 'react';
import {
	AbsoluteFill,
	OffthreadVideo,
	Sequence,
	staticFile,
	useCurrentFrame,
	useVideoConfig
} from 'remotion';
import clips from '../../assets/real/clips.json';
import { Caption } from '../components/Caption';
import { progress } from '../lib/motion';

type Clip = { file: string; caption: string; segments: Array<[number, number]> };

/** Frames before the first clip, while the title settles. */
export const REAL_LEAD_FRAMES = 20;

/**
 * Total length of the recorded material in frames, so the timeline can be
 * checked against it.
 * @param fps - Composition frame rate.
 */
export function realClipFrames(fps: number): number {
	return (clips.clips as Clip[]).reduce(
		(sum, clip) => sum + clip.segments.reduce((s, [a, b]) => s + Math.round((b - a) * fps), 0),
		0
	);
}

const Badge: React.FC<{ frame: number }> = ({ frame }) => (
	<div
		style={{
			position: 'absolute',
			right: 120,
			top: 92,
			display: 'flex',
			alignItems: 'center',
			gap: 12,
			padding: '12px 22px',
			borderRadius: 999,
			background: 'rgba(229,57,53,0.16)',
			border: '1px solid rgba(229,57,53,0.6)',
			fontSize: 24,
			fontWeight: 700,
			letterSpacing: '0.06em',
			opacity: progress(frame, 10, 12)
		}}
	>
		<span
			style={{
				width: 14,
				height: 14,
				borderRadius: 7,
				background: '#e53935',
				opacity: Math.floor(frame / 15) % 2 ? 0.4 : 1
			}}
		/>
		REAL CAPTURE · {clips.system}
	</div>
);

export const Real: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const list = clips.clips as Clip[];
	if (list.length === 0) throw new Error('No real capture: run npm run capture:screen');
	let from = REAL_LEAD_FRAMES;
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 70 }}>
				<Caption chapter="Not a mockup" icon="●" title="Ergopti+ in real life." size={58} />
			</div>
			<Badge frame={frame} />
			{list.map((clip) =>
				clip.segments.map(([a, b], i) => {
					const duration = Math.round((b - a) * fps);
					const start = from;
					from += duration;
					return (
						<Sequence
							key={`${clip.file}-${i}`}
							from={start}
							durationInFrames={duration}
							layout="none"
						>
							<div
								style={{
									position: 'absolute',
									left: 160,
									right: 160,
									top: 210,
									display: 'flex',
									justifyContent: 'center'
								}}
							>
								<div
									style={{
										position: 'relative',
										borderRadius: 16,
										overflow: 'hidden',
										border: '1px solid var(--border-strong)',
										boxShadow: '0 40px 90px rgba(0,0,0,0.6)',
										height: 760,
										aspectRatio: clips.aspect
									}}
								>
									<OffthreadVideo
										src={staticFile(`real/${clip.file}`)}
										startFrom={Math.round(a * fps)}
										muted
										style={{ width: '100%', height: '100%', objectFit: 'cover' }}
									/>
								</div>
							</div>
							<div
								style={{
									position: 'absolute',
									left: 0,
									right: 0,
									top: 990,
									textAlign: 'center',
									fontSize: 30,
									color: 'var(--ink)'
								}}
							>
								{clip.caption}
							</div>
						</Sequence>
					);
				})
			)}
		</AbsoluteFill>
	);
};
