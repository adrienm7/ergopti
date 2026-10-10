// video/src/components/Tooltips.tsx
//
// The driver's caret tooltips, drawn from its own spec
// (_shared/modules/tooltip/constants.toml): panel colour and tint, radius,
// padding, border, and the LLM line colours.

import React from 'react';
import { TOOLTIP } from '../lib/data';
import { SANS } from '../styles';

/** Visual scale from the driver's 11 pt tooltip to the video frame. */
const SCALE = 2;
const { layout, colors, tint, llm_colors: llm, llm_ui: llmUi, positioning } = TOOLTIP;

/**
 * Panel colour tinted by a category colour, as the driver does: the
 * category hue at the spec's saturation and lightness.
 * @param hex - Category colour.
 */
function tinted(hex: string): string {
	const n = parseInt(hex.slice(1), 16);
	const r = (n >> 16) / 255;
	const g = ((n >> 8) & 255) / 255;
	const b = (n & 255) / 255;
	const max = Math.max(r, g, b);
	const min = Math.min(r, g, b);
	let h = 0;
	if (max !== min) {
		const d = max - min;
		if (max === r) h = ((g - b) / d) % 6;
		else if (max === g) h = (b - r) / d + 2;
		else h = (r - g) / d + 4;
	}
	return `hsl(${(h * 60 + 360) % 360}, ${tint.saturation * 100}%, ${tint.lightness * 100}%)`;
}

const panel = (background: string): React.CSSProperties => ({
	position: 'absolute',
	left: positioning.caret_offset_x * SCALE * 0.5,
	top: positioning.caret_offset_y * SCALE + 20,
	background,
	border: `1px solid rgba(255,255,255,${colors.border_alpha_ahk})`,
	borderRadius: layout.corner_radius * SCALE * 0.75,
	padding: `${layout.pad_y * SCALE * 0.8}px ${layout.pad_x * SCALE * 0.8}px`,
	fontFamily: SANS,
	whiteSpace: 'pre',
	boxShadow: '0 18px 40px rgba(0,0,0,0.45)',
	zIndex: 10
});

/** Fade in fast, fade out over the last frames. */
const presence = (age: number, remaining: number) => Math.min(1, age / 5, remaining / 6);

export const DriverTooltip: React.FC<{
	text: string;
	color: string;
	age: number;
	remaining: number;
}> = ({ text, color, age, remaining }) => {
	const p = presence(age, remaining);
	return (
		<span
			style={{
				...panel(tinted(color)),
				opacity: p,
				transform: `translateY(${(1 - Math.min(1, age / 6)) * 8}px)`,
				color: '#fff',
				fontSize: 24,
				fontWeight: 500,
				display: 'flex',
				alignItems: 'center',
				gap: 12
			}}
		>
			<span
				style={{
					width: 10,
					height: 10,
					borderRadius: 5,
					background: color,
					boxShadow: `0 0 12px ${color}`
				}}
			/>
			{text.replace(/\n/g, ' ⏎ ')}
		</span>
	);
};

export type PredictionLine = { correction?: string; continuation: string };

type PredictionProps = {
	context: string;
	lines: PredictionLine[];
	active: number;
	/** Characters revealed so far per line, to show streaming. */
	revealed: number;
	hint: string;
	info: string;
	opacity: number;
};

export const PredictionTooltip: React.FC<PredictionProps> = ({
	context,
	lines,
	active,
	revealed,
	hint,
	info,
	opacity
}) => (
	<span
		style={{
			...panel(colors.bg_hex),
			opacity,
			transform: `translateY(${(1 - opacity) * 10}px)`,
			display: 'flex',
			flexDirection: 'column',
			gap: layout.line_spacing,
			fontSize: 23,
			minWidth: 760
		}}
	>
		{lines.map((line, i) => {
			const full = `${line.correction ?? ''}${line.continuation}`;
			const shown = full.slice(0, revealed);
			const corrLen = Math.min(shown.length, (line.correction ?? '').length);
			const sel = i === active;
			return (
				<span key={i} style={{ color: sel ? '#fff' : llm.unsel_gray_hex }}>
					<span style={{ color: llm.cursor_hex, opacity: sel ? 1 : 0 }}>{llmUi.active_prefix}</span>
					<span style={{ color: colors.dim_hex }}>{context}</span>
					<span style={{ color: sel ? llm.corr_sel_hex : llm.unsel_gray_hex }}>
						{shown.slice(0, corrLen)}
					</span>
					<span style={{ color: sel ? llm.nw_sel_hex : llm.unsel_gray_hex }}>
						{shown.slice(corrLen)}
					</span>
				</span>
			);
		})}
		<span style={{ height: 1, background: `rgba(255,255,255,${colors.sep_alpha_ahk})` }} />
		<span style={{ color: colors.label_hex, fontSize: 20 }}>{hint}</span>
		<span style={{ color: colors.dim_hex, fontSize: 18 }}>{info}</span>
	</span>
);
