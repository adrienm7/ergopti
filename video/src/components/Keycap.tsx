// video/src/components/Keycap.tsx
//
// A physical-looking key that can be pressed and lit, plus a small pill used
// for facts and badges.

import React from 'react';
import { MONO } from '../styles';

type KeycapProps = {
	label: React.ReactNode;
	/** 0 = up, 1 = fully pressed. */
	press?: number;
	/** 0..1 glow in the accent colour. */
	lit?: number;
	accent?: string;
	width?: number;
	height?: number;
	fontSize?: number;
	style?: React.CSSProperties;
};

export const Keycap: React.FC<KeycapProps> = ({
	label,
	press = 0,
	lit = 0,
	accent = 'var(--accent-blue)',
	width = 120,
	height = 110,
	fontSize = 30,
	style
}) => (
	<div
		style={{
			width,
			height,
			borderRadius: 18,
			position: 'relative',
			background: 'linear-gradient(180deg, #3a3d46 0%, #23252c 100%)',
			boxShadow: `0 ${10 - press * 7}px 0 #121318, 0 ${18 - press * 10}px 30px rgba(0,0,0,0.45), inset 0 1px 0 rgba(255,255,255,0.18), 0 0 ${lit * 40}px color-mix(in srgb, ${accent} ${Math.round(lit * 80)}%, transparent)`,
			transform: `translateY(${press * 7}px)`,
			border: `2px solid color-mix(in srgb, ${accent} ${Math.round(lit * 100)}%, rgba(255,255,255,0.08))`,
			display: 'grid',
			placeItems: 'center',
			color: lit > 0.5 ? '#fff' : 'rgba(255,255,255,0.86)',
			fontFamily: MONO,
			fontWeight: 500,
			fontSize,
			...style
		}}
	>
		{label}
	</div>
);

export const Pill: React.FC<{
	children: React.ReactNode;
	color?: string;
	style?: React.CSSProperties;
}> = ({ children, color = 'var(--accent-blue)', style }) => (
	<div
		style={{
			display: 'inline-flex',
			alignItems: 'center',
			gap: 12,
			padding: '14px 24px',
			borderRadius: 999,
			background: 'var(--surface-strong)',
			border: `1px solid color-mix(in srgb, ${color} 45%, transparent)`,
			color: 'var(--ink)',
			fontSize: 28,
			fontWeight: 600,
			whiteSpace: 'nowrap',
			...style
		}}
	>
		{children}
	</div>
);
