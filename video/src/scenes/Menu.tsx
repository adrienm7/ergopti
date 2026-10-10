// video/src/scenes/Menu.tsx
//
// The film's map: the tray menu exactly as menu_manifest.json lays it out
// for Windows, every row in order, opened from its tray icon. The cursor walks
// down the feature rows from top to bottom, leaving the settings alone; a liquid highlight springs to each row,
// stretching with its speed, and each submenu fans out beside it. Rows the
// driver fills at run time stay as dimmed placeholders.

import React from 'react';
import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { Cursor, type Waypoint } from '../components/Cursor';
import { Sfx } from '../components/Sound';
import { MENU, type MenuRow } from '../lib/data';
import { pop, progress } from '../lib/motion';
import { NAME_GRADIENT_CLASS } from '../styles';

const PANEL_X = 1380;
const PANEL_TOP = 70;
const PANEL_W = 460;
const ROW_H = 46;
const SEPARATOR_H = 13;
const SUB_W = 520;
const SUB_MAX_H = 960;
const OPEN_AT = 22;
const FIRST_VISIT = 44;
/** Frames spent on a row with a submenu (time to read it), and on one without. */
const DWELL_SUB = 66;
const DWELL_LEAF = 11;
/** First row of the settings group: the cursor walks the features above it only. */
const SETTINGS_FIRST = 'about';
const SPRING = { damping: 13, stiffness: 170, mass: 0.8 };

type Placed = MenuRow & { y: number };
type Visit = { row: Placed; at: number };

/** Top offsets of the rows inside the panel, separators included. */
function layout(rows: MenuRow[]): Placed[] {
	let y = 8;
	const trimmed = rows[rows.length - 1]?.id === '---' ? rows.slice(0, -1) : rows;
	return trimmed.map((row) => {
		const placed = { ...row, y };
		y += row.id === '---' ? SEPARATOR_H : ROW_H;
		return placed;
	});
}

/** Every feature row, top to bottom, with the frame the cursor reaches it. */
function visits(rows: Placed[]): Visit[] {
	const settings = rows.findIndex((row) => row.id === SETTINGS_FIRST);
	if (settings < 0) throw new Error(`The menu has no ${SETTINGS_FIRST} row`);
	let at = FIRST_VISIT;
	return rows
		.slice(0, settings)
		.filter((row) => row.id !== '---')
		.map((row) => {
			const visit = { row, at };
			at += row.children && row.children.length > 0 ? DWELL_SUB : DWELL_LEAF;
			return visit;
		});
}

/** Splits a leading emoji from a label so it can bounce on its own. */
function splitIcon(label: string): { icon: string; text: string } {
	const match = label.match(/^(\p{Extended_Pictographic}️?)\s*(.*)$/u);
	return match ? { icon: match[1], text: match[2] } : { icon: '', text: label };
}

/** Run-time placeholders in a label ("%s", "{1}") read as an ellipsis. */
const tidy = (label: string): string =>
	label
		.replace(/%s|\{\d+\}|\{[a-z_]+\}/g, '…')
		.trim()
		.replace(/^↳\s*/, '');

const Submenu: React.FC<{ row: Placed; since: number; fps: number }> = ({ row, since, fps }) => {
	const children = row.children ?? [];
	const fan = spring({ frame: since, fps, config: { damping: 16, stiffness: 170 } });
	const separators = children.filter((c) => c.type === '---').length;
	const items = children.length - separators;
	const rowH = Math.min(40, (SUB_MAX_H - 24 - separators * 9) / Math.max(1, items));
	const subH = items * rowH + separators * 9 + 20;
	const top = Math.max(40, Math.min(PANEL_TOP + row.y - 10, 1050 - subH));
	let y = 10;
	return (
		<div
			style={{
				position: 'absolute',
				left: PANEL_X - SUB_W - 16,
				top,
				width: SUB_W,
				height: subH,
				borderRadius: 18,
				background: 'rgba(22, 26, 38, 0.9)',
				border: '1px solid rgba(255,255,255,0.14)',
				boxShadow: '0 40px 90px rgba(0,0,0,0.5)',
				transformOrigin: 'right center',
				transform: `translateX(${(1 - fan) * 40}px) scale(${0.94 + 0.06 * fan})`,
				opacity: Math.min(1, fan * 1.4)
			}}
		>
			{children.map((child, i) => {
				const c = interpolate(since, [2 + i * 0.8, 10 + i * 0.8], [0, 1], {
					extrapolateLeft: 'clamp',
					extrapolateRight: 'clamp'
				});
				const top = y;
				if (child.type === '---') {
					y += 9;
					return (
						<div
							key={i}
							style={{
								position: 'absolute',
								left: 20,
								right: 20,
								top: top + 4,
								height: 1,
								background: 'rgba(255,255,255,0.12)',
								opacity: c
							}}
						/>
					);
				}
				y += rowH;
				const header = child.type === 'section_header';
				const placeholder = child.label === null;
				return (
					<div
						key={i}
						style={{
							position: 'absolute',
							left: 22,
							right: 18,
							top,
							height: rowH,
							display: 'flex',
							alignItems: 'center',
							gap: 10,
							fontSize: Math.min(header ? 15 : 20, rowH * 0.52),
							fontWeight: header ? 700 : 500,
							letterSpacing: header ? '0.08em' : 0,
							textTransform: header ? 'uppercase' : 'none',
							color: header ? 'var(--accent-cyan)' : 'rgba(255,255,255,0.88)',
							opacity: c,
							transform: `translateX(${(1 - c) * 20}px)`
						}}
					>
						{child.type === 'toggle' || child.type === 'check' ? (
							<span style={{ color: 'var(--accent-cyan)' }}>✓</span>
						) : null}
						{placeholder ? (
							<span
								style={{
									height: rowH * 0.28,
									width: `${40 + ((i * 37) % 40)}%`,
									borderRadius: 6,
									background: 'rgba(255,255,255,0.1)'
								}}
							/>
						) : (
							<span
								style={{
									flex: 1,
									whiteSpace: 'nowrap',
									overflow: 'hidden',
									textOverflow: 'ellipsis'
								}}
							>
								{tidy(child.label ?? '')}
							</span>
						)}
						{child.type === 'group' || child.type === 'choice' ? (
							<span style={{ opacity: 0.6 }}>›</span>
						) : null}
					</div>
				);
			})}
		</div>
	);
};

export const Menu: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const rows = layout(MENU);
	const path = visits(rows);
	const panelH = rows[rows.length - 1].y + ROW_H + 8;
	const open = spring({ frame: frame - OPEN_AT, fps, config: { damping: 15, stiffness: 140 } });

	const idx = path.reduce((found, v, i) => (frame >= v.at - 8 ? i : found), -1);
	const current = idx >= 0 ? path[idx] : null;
	const previous = idx > 0 ? path[idx - 1] : current;
	const moveFrame = current ? frame - (current.at - 8) : 0;
	const s = spring({ frame: moveFrame, fps, config: SPRING });
	const sPrev = spring({ frame: moveFrame - 1, fps, config: SPRING });
	const bubbleY = current && previous ? previous.row.y + (current.row.y - previous.row.y) * s : 0;
	// Stretch along the move, squeeze across it: a liquid feel.
	const speed = current && previous ? Math.abs((current.row.y - previous.row.y) * (s - sPrev)) : 0;
	const stretch = 1 + Math.min(0.8, speed / 25);
	const bubbleIn = idx >= 0 ? Math.min(1, (frame - (FIRST_VISIT - 8)) / 6) : 0;

	const tray = { x: 1800, y: 1030 };
	const waypoints: Waypoint[] = [
		{ frame: 0, x: 1560, y: 1070 },
		{ frame: 16, x: tray.x, y: tray.y, click: true },
		...path.map((v) => ({ frame: v.at, x: PANEL_X + 260, y: PANEL_TOP + v.row.y + ROW_H / 2 }))
	];

	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 150, width: 640 }}>
				<Caption
					chapter="Ergopti+"
					icon="★"
					title="Everything in one menu."
					sub="Each feature has its own submenu. Turn on what you want, leave the rest."
					size={66}
				/>
			</div>
			<div
				style={{
					position: 'absolute',
					left: tray.x - 24,
					top: tray.y - 24,
					width: 48,
					height: 48,
					borderRadius: 12,
					display: 'grid',
					placeItems: 'center',
					background: 'rgba(255,255,255,0.08)',
					border: '1px solid var(--border-strong)',
					fontSize: 28,
					fontWeight: 800,
					transform: `scale(${0.9 + 0.1 * pop(frame, fps, 4)})`
				}}
			>
				<span className={NAME_GRADIENT_CLASS}>★</span>
			</div>
			<div
				style={{
					position: 'absolute',
					left: PANEL_X,
					top: PANEL_TOP,
					width: PANEL_W,
					height: panelH,
					borderRadius: 20,
					background: 'rgba(22, 26, 38, 0.8)',
					backdropFilter: 'blur(24px)',
					border: '1px solid rgba(255,255,255,0.14)',
					boxShadow: '0 50px 120px rgba(0,0,0,0.55), inset 0 1px 0 rgba(255,255,255,0.08)',
					transformOrigin: `${tray.x - PANEL_X}px ${tray.y - PANEL_TOP}px`,
					transform: `scale(${0.2 + 0.8 * open})`,
					opacity: Math.min(1, open * 1.5)
				}}
			>
				{bubbleIn > 0 && current ? (
					<div
						style={{
							position: 'absolute',
							left: 8,
							right: 8,
							top: bubbleY + ROW_H / 2 - (ROW_H - 8) / 2,
							height: ROW_H - 8,
							borderRadius: 999,
							background: 'linear-gradient(90deg, #3088ed, #02c9db)',
							boxShadow: '0 0 30px rgba(2,201,219,0.55)',
							opacity: bubbleIn,
							transform: `scale(${1 / Math.sqrt(stretch)}, ${stretch})`
						}}
					/>
				) : null}
				{rows.map((row, i) => {
					if (row.id === '---') {
						return (
							<div
								key={`sep-${i}`}
								style={{
									position: 'absolute',
									left: 22,
									right: 22,
									top: row.y + SEPARATOR_H / 2,
									height: 1,
									background: 'rgba(255,255,255,0.12)'
								}}
							/>
						);
					}
					const hovered = current?.row.id === row.id;
					const enter = progress(frame, OPEN_AT + 4 + i, 12);
					const { icon, text } = splitIcon(row.label ?? '');
					const bounce = hovered ? Math.sin(Math.min(1, moveFrame / 10) * Math.PI) * 0.35 : 0;
					return (
						<div
							key={row.id}
							style={{
								position: 'absolute',
								left: 24,
								right: 20,
								top: row.y,
								height: ROW_H,
								display: 'flex',
								alignItems: 'center',
								gap: 12,
								fontSize: 23,
								fontWeight: hovered ? 700 : 500,
								color: hovered ? '#fff' : 'rgba(255,255,255,0.86)',
								opacity: enter,
								transform: `translateX(${(1 - enter) * 30 + (hovered ? 8 : 0)}px)`
							}}
						>
							<span style={{ width: 30, textAlign: 'center', transform: `scale(${1 + bounce})` }}>
								{icon}
							</span>
							<span style={{ flex: 1 }}>{text}</span>
							{row.children && row.children.length > 0 ? (
								<span style={{ opacity: 0.6 }}>›</span>
							) : null}
						</div>
					);
				})}
			</div>
			{current && current.row.children && current.row.children.length > 0 ? (
				<Submenu row={current.row} since={frame - (current.at - 4)} fps={fps} />
			) : null}
			<Cursor waypoints={waypoints} frame={frame} scale={1.05} />
			<Sfx name="key" at={16} />
			<Sfx name="whoosh" at={OPEN_AT} volume={0.3} />
			{path.map((v) => (
				<Sfx key={v.row.id} name="pop" at={v.at - 6} volume={0.15} />
			))}
		</AbsoluteFill>
	);
};
