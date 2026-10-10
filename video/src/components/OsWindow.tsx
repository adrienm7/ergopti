// video/src/components/OsWindow.tsx
//
// A dark application window in the chrome of one of the three systems the
// drivers support, mirroring the sales page's WindowChrome component.

import React from 'react';
import { SANS } from '../styles';

export type Os = 'windows' | 'macos' | 'linux';

type Props = {
	os: Os;
	title: string;
	width: number;
	height: number;
	children: React.ReactNode;
	style?: React.CSSProperties;
	bodyStyle?: React.CSSProperties;
};

const CHROME_HEIGHT: Record<Os, number> = { windows: 36, macos: 38, linux: 44 };

const Controls: React.FC<{ os: Os }> = ({ os }) => {
	if (os === 'macos') {
		return (
			<span style={{ display: 'flex', gap: 8, position: 'absolute', left: 14 }}>
				{['#ff5f57', '#febc2e', '#28c840'].map((c) => (
					<span key={c} style={{ width: 12, height: 12, borderRadius: 6, background: c }} />
				))}
			</span>
		);
	}
	if (os === 'linux') {
		return (
			<span style={{ display: 'flex', gap: 10, position: 'absolute', right: 12 }}>
				{['─', '▢', '✕'].map((c) => (
					<span
						key={c}
						style={{
							width: 24,
							height: 24,
							borderRadius: 12,
							background: 'rgba(255,255,255,0.1)',
							display: 'grid',
							placeItems: 'center',
							fontSize: 11,
							color: '#ddd'
						}}
					>
						{c}
					</span>
				))}
			</span>
		);
	}
	return (
		<span style={{ display: 'flex', position: 'absolute', right: 0, top: 0, height: '100%' }}>
			{['─', '▢', '✕'].map((c) => (
				<span
					key={c}
					style={{ width: 46, display: 'grid', placeItems: 'center', fontSize: 12, color: '#ccc' }}
				>
					{c}
				</span>
			))}
		</span>
	);
};

export const OsWindow: React.FC<Props> = ({
	os,
	title,
	width,
	height,
	children,
	style,
	bodyStyle
}) => {
	const chrome = CHROME_HEIGHT[os];
	const radius = os === 'windows' ? 8 : 12;
	// The frame does not clip: caret tooltips are separate topmost windows on
	// every system and spill over the edge. Each part rounds its own corners.
	return (
		<div
			style={{
				width,
				height,
				borderRadius: radius,
				background: '#1b1b1f',
				border: '1px solid rgba(255,255,255,0.12)',
				boxShadow: '0 40px 90px rgba(0,0,0,0.55), 0 0 0 1px rgba(0,0,0,0.4)',
				display: 'flex',
				flexDirection: 'column',
				fontFamily: SANS,
				...style
			}}
		>
			<div
				style={{
					height: chrome,
					flex: `0 0 ${chrome}px`,
					position: 'relative',
					borderRadius: `${radius}px ${radius}px 0 0`,
					display: 'flex',
					alignItems: 'center',
					justifyContent: os === 'windows' ? 'flex-start' : 'center',
					paddingLeft: os === 'windows' ? 14 : 0,
					background: os === 'linux' ? '#2b2b2f' : '#242428',
					borderBottom: '1px solid rgba(255,255,255,0.06)',
					color: 'rgba(255,255,255,0.72)',
					fontSize: 14,
					fontWeight: os === 'linux' ? 700 : 500
				}}
			>
				<Controls os={os} />
				<span>{title}</span>
			</div>
			<div
				style={{
					flex: 1,
					position: 'relative',
					borderRadius: `0 0 ${radius}px ${radius}px`,
					...bodyStyle
				}}
			>
				{children}
			</div>
		</div>
	);
};

export const chromeHeight = (os: Os): number => CHROME_HEIGHT[os];
