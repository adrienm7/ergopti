// video/src/scenes/ShortcutActions.tsx
//
// One slide per shortcut that solves a real annoyance: its keys on Windows
// (and on macOS when the same letter does the same thing), its label from the
// driver's locale, why it matters, and a small demonstration.

import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame } from 'remotion';
import { Cursor } from '../components/Cursor';
import { Keycap } from '../components/Keycap';
import { OsWindow } from '../components/OsWindow';
import { Sfx } from '../components/Sound';
import { bareLabel, shortcut, WRAP_SYMBOLS } from '../lib/data';
import { progress, rise } from '../lib/motion';
import { MONO } from '../styles';

type SlideProps = {
	/** Keys on Windows, and on macOS when they do the same thing. */
	keys: string;
	macKeys?: string;
	title: string;
	lines: string[];
	pressAt: number[];
	demo: React.ReactNode;
};

const Slide: React.FC<SlideProps> = ({ keys, macKeys, title, lines, pressAt, demo }) => {
	const frame = useCurrentFrame();
	const pressed = pressAt.some((f) => frame >= f && frame < f + 8);
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 230, width: 780 }}>
				<div
					style={{
						display: 'flex',
						gap: 16,
						alignItems: 'center',
						...rise(progress(frame, 0, 16), 20)
					}}
				>
					<span
						style={{
							fontFamily: MONO,
							fontSize: 42,
							padding: '12px 26px',
							borderRadius: 16,
							background: pressed ? 'var(--accent-blue)' : 'var(--surface-strong)',
							border: '1px solid var(--accent-blue)',
							color: pressed ? '#04121f' : '#fff',
							transform: `translateY(${pressed ? 4 : 0}px)`
						}}
					>
						{keys}
					</span>
					{macKeys ? (
						<span style={{ fontSize: 24, color: 'var(--ink-faint)' }}>{macKeys} on macOS</span>
					) : null}
				</div>
				<div
					style={{
						fontSize: 68,
						fontWeight: 800,
						marginTop: 32,
						lineHeight: 1.1,
						...rise(progress(frame, 6, 18), 24)
					}}
				>
					{title}
				</div>
				{lines.map((line, i) => (
					<div
						key={i}
						style={{
							fontSize: 30,
							color: i === lines.length - 1 ? '#fff' : 'var(--ink-soft)',
							fontWeight: i === lines.length - 1 ? 600 : 400,
							marginTop: 16,
							lineHeight: 1.35,
							...rise(progress(frame, 12 + i * 10, 18), 20)
						}}
					>
						{line}
					</div>
				))}
			</div>
			<div
				style={{ position: 'absolute', left: 960, top: 200, ...rise(progress(frame, 4, 18), 30) }}
			>
				{demo}
			</div>
			{pressAt.map((f) => (
				<Sfx key={f} name="thock" at={f} volume={0.35} />
			))}
		</AbsoluteFill>
	);
};

// ======= Teleport =======

const SCREENS = [
	{ x: 0, y: 150, w: 330, h: 210, label: 'Laptop' },
	{ x: 350, y: 90, w: 430, h: 270, label: 'Main screen' },
	{ x: 470, y: 380, w: 200, h: 300, label: 'Portrait' }
];
const TELEPORT_PRESS = [96, 140];

const TeleportDemo: React.FC = () => {
	const frame = useCurrentFrame();
	const jumps = TELEPORT_PRESS.filter((f) => frame >= f).length;
	// Before the shortcut: the pointer is lost, wandering on the laptop screen.
	const lost = {
		x: 60 + 120 * (0.5 + 0.5 * Math.sin(frame / 9)),
		y: 200 + 80 * (0.5 + 0.5 * Math.cos(frame / 13))
	};
	const centre = (i: number) => ({
		x: SCREENS[i].x + SCREENS[i].w / 2,
		y: SCREENS[i].y + SCREENS[i].h / 2
	});
	const at = jumps === 0 ? lost : centre(jumps);
	const flash = TELEPORT_PRESS.map((f) =>
		interpolate(frame, [f, f + 12], [1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' })
	);
	return (
		<div style={{ position: 'relative', width: 800, height: 700 }}>
			{SCREENS.map((s, i) => (
				<div
					key={s.label}
					style={{
						position: 'absolute',
						left: s.x,
						top: s.y,
						width: s.w,
						height: s.h,
						borderRadius: 12,
						border: `3px solid ${i === jumps ? 'var(--accent-blue)' : 'rgba(255,255,255,0.3)'}`,
						background: 'rgba(255,255,255,0.05)',
						display: 'grid',
						placeItems: 'end center',
						paddingBottom: 10,
						fontSize: 20,
						color: 'var(--ink-faint)'
					}}
				>
					{s.label}
				</div>
			))}
			{jumps === 0 && frame > 30 ? (
				<div
					style={{
						position: 'absolute',
						left: 40,
						top: 110,
						fontSize: 30,
						color: 'var(--ink-soft)',
						opacity: progress(frame, 30, 12)
					}}
				>
					Where is it? Which edge leads where?
				</div>
			) : null}
			{flash.map((f, i) =>
				f > 0 && jumps > i ? (
					<div
						key={i}
						style={{
							position: 'absolute',
							left: centre(i + 1).x - 60,
							top: centre(i + 1).y - 60,
							width: 120,
							height: 120,
							borderRadius: '50%',
							border: `4px solid rgba(49,190,255,${f})`,
							transform: `scale(${1.6 - f})`
						}}
					/>
				) : null
			)}
			<Cursor waypoints={[{ frame: 0, ...at }]} frame={frame} scale={1.4} />
		</div>
	);
};

export const ShortcutTeleport: React.FC = () => {
	const slot = shortcut('teleport_mouse');
	return (
		<Slide
			keys={slot.windows}
			macKeys={slot.macos?.keys}
			title={bareLabel(slot.label)}
			lines={[
				'With two or three screens, you never know where the mouse is.',
				'Nor which edge of this screen leads to the one you want.',
				'One shortcut: the cursor lands on the next screen.'
			]}
			pressAt={TELEPORT_PRESS}
			demo={<TeleportDemo />}
		/>
	);
};

// ======= Select line =======

const SelectDemo: React.FC = () => {
	const frame = useCurrentFrame();
	const sel = progress(frame, 42, 8);
	return (
		<OsWindow
			os="windows"
			title="Notepad"
			width={820}
			height={300}
			bodyStyle={{ padding: '40px 44px' }}
		>
			<div style={{ fontFamily: MONO, fontSize: 30, lineHeight: 1.7, color: '#ddd' }}>
				<div>First draft of the plan.</div>
				<div style={{ position: 'relative', display: 'inline-block' }}>
					<span
						style={{
							position: 'absolute',
							inset: '0 -6px',
							background: 'rgba(49,190,255,0.4)',
							transformOrigin: 'left',
							transform: `scaleX(${sel})`
						}}
					/>
					<span style={{ position: 'relative' }}>This line goes, whole, in one shortcut.</span>
				</div>
				<div>Last line stays.</div>
			</div>
		</OsWindow>
	);
};

export const ShortcutSelectLine: React.FC = () => {
	const slot = shortcut('select_line');
	return (
		<Slide
			keys={slot.windows}
			macKeys={slot.macos?.keys}
			title={bareLabel(slot.label)}
			lines={['The whole line, wherever the caret is.', 'No triple-click, no aiming.']}
			pressAt={[42]}
			demo={<SelectDemo />}
		/>
	);
};

// ======= Change case =======

const CaseDemo: React.FC = () => {
	const frame = useCurrentFrame();
	const text = 'meeting notes q4 roadmap';
	// Pressed twice: up, then back down.
	const shown = frame >= 42 && frame < 78 ? text.toUpperCase() : text;
	return (
		<OsWindow
			os="macos"
			title="Notes"
			width={820}
			height={240}
			bodyStyle={{ padding: '60px 44px' }}
		>
			<span
				style={{
					fontFamily: MONO,
					fontSize: 38,
					background: 'rgba(49,190,255,0.35)',
					color: '#fff'
				}}
			>
				{shown}
			</span>
		</OsWindow>
	);
};

export const ShortcutCase: React.FC = () => {
	const slot = shortcut('uppercase_selection');
	return (
		<Slide
			keys={slot.windows}
			macKeys={slot.macos?.keys}
			title={bareLabel(slot.label)}
			lines={['Flip the selection to UPPERCASE and back, without retyping a letter.']}
			pressAt={[42, 78]}
			demo={<CaseDemo />}
		/>
	);
};

// ======= Colour under the cursor =======

const COLORS = ['#3088ed', '#02c9db', '#e53935', '#43a047', '#ff9e1a', '#db4bff'];

const ColorDemo: React.FC = () => {
	const frame = useCurrentFrame();
	const chip = progress(frame, 42, 10);
	return (
		<div style={{ position: 'relative', width: 820, height: 360 }}>
			<div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 200px)', gap: 20 }}>
				{COLORS.map((c) => (
					<div key={c} style={{ width: 200, height: 120, borderRadius: 16, background: c }} />
				))}
			</div>
			<Cursor waypoints={[{ frame: 0, x: 300, y: 70 }]} frame={frame} scale={1.3} />
			<div
				style={{
					position: 'absolute',
					left: 330,
					top: 110,
					padding: '10px 18px',
					borderRadius: 12,
					background: '#111',
					border: '1px solid rgba(255,255,255,0.2)',
					fontFamily: MONO,
					fontSize: 26,
					opacity: chip,
					transform: `translateY(${(1 - chip) * 10}px)`
				}}
			>
				{COLORS[1].toUpperCase()} copied
			</div>
		</div>
	);
};

export const ShortcutColor: React.FC = () => {
	const slot = shortcut('pick_color');
	return (
		<Slide
			keys={slot.windows}
			macKeys={slot.macos?.keys}
			title={bareLabel(slot.label)}
			lines={['The colour under the mouse, as a hex code, straight to the clipboard.']}
			pressAt={[42]}
			demo={<ColorDemo />}
		/>
	);
};

// ======= Open or search the selection =======

const SMART_CASES = [
	{ selection: 'D:\\Reports\\Q3 review.pdf', kind: 'file', at: 30 },
	{ selection: 'ergopti.fr', kind: 'site', at: 110 },
	{ selection: 'best ergonomic keyboard', kind: 'search', at: 190 }
] as const;
const DEMO_W = 860;

/** What opens: a PDF viewer, the site in a browser, or web results. */
const Opened: React.FC<{ c: (typeof SMART_CASES)[number] }> = ({ c }) => {
	const bar = (w: string, h = 14, color = 'rgba(0,0,0,0.12)') => (
		<div style={{ width: w, height: h, borderRadius: 4, background: color, marginTop: 12 }} />
	);
	if (c.kind === 'file') {
		return (
			<OsWindow os="windows" title="Q3 review.pdf" width={DEMO_W} height={440}>
				<div style={{ background: '#3a3a3f', height: '100%', padding: '24px 0' }}>
					<div
						style={{
							width: 520,
							height: 380,
							margin: '0 auto',
							background: '#fff',
							borderRadius: 4,
							padding: '30px 40px',
							color: '#222'
						}}
					>
						<div style={{ fontSize: 30, fontWeight: 800 }}>Q3 review</div>
						{bar('90%')}
						{bar('75%')}
						<div
							style={{
								display: 'flex',
								alignItems: 'flex-end',
								gap: 18,
								height: 150,
								marginTop: 26
							}}
						>
							{[50, 80, 65, 120, 140].map((h, i) => (
								<div
									key={i}
									style={{ width: 50, height: h, borderRadius: 4, background: '#3088ed' }}
								/>
							))}
						</div>
						{bar('60%')}
					</div>
				</div>
			</OsWindow>
		);
	}
	const url = c.kind === 'site' ? 'https://ergopti.fr' : `search: ${c.selection}`;
	return (
		<OsWindow os="windows" title="Browser" width={DEMO_W} height={440}>
			<div style={{ background: '#202124', height: '100%' }}>
				<div
					style={{
						margin: '12px 16px',
						padding: '8px 18px',
						borderRadius: 18,
						background: '#35363a',
						fontSize: 20,
						color: '#ddd',
						fontFamily: MONO
					}}
				>
					{url}
				</div>
				{c.kind === 'site' ? (
					<Img
						src={staticFile('img/og_image.jpg')}
						style={{ width: '100%', height: 360, objectFit: 'cover', objectPosition: 'top' }}
					/>
				) : (
					<div style={{ padding: '6px 34px' }}>
						{[
							'The 10 best ergonomic keyboards of the year',
							'Split keyboards: a buyer’s guide',
							'Ergonomic keyboard layouts compared'
						].map((t) => (
							<div key={t} style={{ marginTop: 18 }}>
								<div style={{ fontSize: 24, color: '#8ab4f8' }}>{t}</div>
								{bar('85%', 10, 'rgba(255,255,255,0.14)')}
								{bar('60%', 10, 'rgba(255,255,255,0.14)')}
							</div>
						))}
					</div>
				)}
			</div>
		</OsWindow>
	);
};

const SmartDemo: React.FC = () => {
	const frame = useCurrentFrame();
	const current = [...SMART_CASES].reverse().find((c) => frame >= c.at - 30) ?? SMART_CASES[0];
	const selected = progress(frame, current.at - 30, 10);
	const open = progress(frame, current.at + 6, 14);
	return (
		<div style={{ width: DEMO_W }}>
			<OsWindow
				os="windows"
				title="Notes"
				width={DEMO_W}
				height={150}
				bodyStyle={{ padding: '30px 34px' }}
			>
				<span style={{ fontFamily: MONO, fontSize: 32, color: '#eee' }}>
					<span style={{ background: `rgba(49,190,255,${0.45 * selected})` }}>
						{current.selection}
					</span>
				</span>
			</OsWindow>
			<div
				style={{
					marginTop: 30,
					opacity: open,
					transform: `translateY(${(1 - open) * 40}px) scale(${0.94 + 0.06 * open})`,
					transformOrigin: 'top center'
				}}
			>
				<Opened c={current} />
			</div>
		</div>
	);
};

export const ShortcutSearch: React.FC = () => {
	// Win + S runs the selection-aware search (windows/modules/shortcuts/win.ahk).
	const slot = shortcut('search_web');
	return (
		<Slide
			keys={slot.windows}
			macKeys={slot.macos?.keys}
			title="Open anything you select."
			lines={[
				'Select a file path: it opens the file. A link: it opens the site. Anything else: it searches the web.',
				'One shortcut that adapts to what you selected.'
			]}
			pressAt={SMART_CASES.map((c) => c.at)}
			demo={<SmartDemo />}
		/>
	);
};

// ======= Wrap the selection =======

/** Which pairs of the shared catalogue the demo types, by group and index. */
const WRAP_STEPS = [
	{ group: 0, pair: 0, at: 40 },
	{ group: 0, pair: 1, at: 80 },
	{ group: 1, pair: 6, at: 120 },
	{ group: 5, pair: 0, at: 160 }
];

const pairOf = (step: (typeof WRAP_STEPS)[number]) => {
	const pair = WRAP_SYMBOLS.groups[step.group]?.pairs[step.pair];
	if (!pair) throw new Error(`No wrap pair at group ${step.group}, pair ${step.pair}`);
	return pair;
};

const WrapDemo: React.FC = () => {
	const frame = useCurrentFrame();
	// Each symbol wraps the original selection, one after the other.
	const last = [...WRAP_STEPS].reverse().find((s) => frame >= s.at);
	const pair = last ? pairOf(last) : null;
	const text = pair ? `${pair.left}ergonomic layouts${pair.right}` : 'ergonomic layouts';
	const typing = WRAP_STEPS.find((s) => frame >= s.at - 6 && frame < s.at + 6);
	return (
		<div style={{ display: 'flex', flexDirection: 'column', gap: 30, width: 820 }}>
			<OsWindow
				os="windows"
				title="Microsoft Teams"
				width={820}
				height={220}
				bodyStyle={{ padding: '60px 44px' }}
			>
				<span style={{ fontSize: 40, color: '#ddd' }}>
					Read about{' '}
					<span style={{ background: 'rgba(49,190,255,0.4)', color: '#fff' }}>{text}</span>
				</span>
			</OsWindow>
			<div style={{ display: 'flex', gap: 18, alignItems: 'center' }}>
				{WRAP_STEPS.map((s) => (
					<Keycap
						key={s.at}
						label={pairOf(s).left.trim()}
						width={96}
						height={90}
						fontSize={36}
						press={typing === s ? 1 : 0}
						lit={frame >= s.at ? 0.5 : 0}
					/>
				))}
			</div>
			<div style={{ fontSize: 24, color: 'var(--ink-faint)' }}>
				{WRAP_SYMBOLS.groups.map((g) => g.label).join(' · ')}
			</div>
		</div>
	);
};

export const ShortcutWrap: React.FC = () => (
	<Slide
		keys="Select, then type ( [ « …"
		title={WRAP_SYMBOLS.label}
		lines={[
			'Brackets, quotes, Markdown emphasis… around the selection.',
			'In any app, not just your code editor.'
		]}
		pressAt={WRAP_STEPS.map((s) => s.at)}
		demo={<WrapDemo />}
	/>
);
