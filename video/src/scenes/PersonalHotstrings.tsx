// video/src/scenes/PersonalHotstrings.tsx
//
// Creating a personal hotstring in the real editor: a cursor clicks
// "+ Add a hotstring", the editor's own form fills in, Save adds the row,
// then the new hotstring fires in a document. The window's state is rebuilt
// from the frame alone, since frames are captured out of order.

import React, { useCallback, useMemo, useState } from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { Cursor, type Waypoint } from '../components/Cursor';
import { DriverWindow } from '../components/DriverWindow';
import { OsWindow } from '../components/OsWindow';
import { KeySounds, Sfx } from '../components/Sound';
import { compileTyping, TypedText } from '../components/Typewriter';
import { TOOLTIP } from '../lib/data';
import { pop, progress, rise } from '../lib/motion';

const TRIGGER = 'ty★';
const OUTPUT = 'Thanks a lot, and have a great weekend!';
const CLICK_ADD = 40;
const CLICK_TRIGGER = 58;
const TYPE_TRIGGER = 62;
const CLICK_OUTPUT = 92;
const TYPE_OUTPUT = 96;
const CLICK_SAVE = 176;
const DOC_AT = 222;
/** Characters typed per frame in the form. */
const FORM_CPS = 0.6;
const EDITOR_SCALE = 1.2;

/** The driver's personal-hotstring accent, from the tooltip spec. */
const PERSONAL = (() => {
	const c = TOOLTIP.accent_colors.hotstring_personal;
	return `rgb(${Math.round(c.red * 255)}, ${Math.round(c.green * 255)}, ${Math.round(c.blue * 255)})`;
})();

type Rect = { x: number; y: number };
type Targets = { add: Rect; trigger: Rect; output: Rect; save: Rect };

/** Centre of an element of the editor, in the window's pixels. */
function centre(win: Window, selector: string): Rect {
	const el = win.document.querySelector(selector);
	if (!el) throw new Error(`The hotstring editor has no ${selector}`);
	const r = el.getBoundingClientRect();
	return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
}

type EditorData = { sections: Array<{ entries: Array<{ trigger: string }> }> };
type EditorWindow = Window & {
	eval: (code: string) => unknown;
	showAddEntry: (si: number) => void;
	closeModal: (id: string) => void;
	saveEntry: (andNew: boolean) => void;
	setTrigContent: (el: Element, text: string) => void;
	setEditorContent: (el: Element, text: string) => void;
	render: () => void;
};

const modalOpen = (win: EditorWindow) =>
	win.document.getElementById('entry-modal')?.classList.contains('on') ?? false;

/** Sets both form fields to what has been typed by a frame. */
function fillForm(win: EditorWindow, frame: number): void {
	const trig = win.document.getElementById('e-trig');
	const out = win.document.getElementById('e-out');
	if (!trig || !out) throw new Error('The hotstring editor form is missing its fields');
	const typed = (start: number, text: string) =>
		[...text].slice(0, Math.max(0, Math.floor((frame - start) * FORM_CPS))).join('');
	win.setTrigContent(trig, typed(TYPE_TRIGGER, TRIGGER));
	win.setEditorContent(out, typed(TYPE_OUTPUT, OUTPUT));
}

/** The editor exactly as it stands at a frame. */
function stage(win: EditorWindow, frame: number): void {
	// The editor keeps its data in a top-level `let D`, reachable only from
	// inside its own realm.
	const entries = (win.eval('D') as EditorData).sections[0].entries;
	const at = entries.findIndex((e) => e.trigger === TRIGGER);
	if (frame < CLICK_SAVE) {
		if (at >= 0) {
			entries.splice(at, 1);
			win.render();
		}
		if (frame < CLICK_ADD) {
			if (modalOpen(win)) win.closeModal('entry-modal');
			return;
		}
		if (!modalOpen(win)) win.showAddEntry(0);
		fillForm(win, frame);
		return;
	}
	if (at < 0) {
		if (!modalOpen(win)) win.showAddEntry(0);
		fillForm(win, Number.MAX_SAFE_INTEGER);
		win.saveEntry(false);
	} else if (modalOpen(win)) {
		win.closeModal('entry-modal');
	}
	// Outline the new row: from the trigger chip up to the element that also
	// holds the replacement.
	const chip = [...win.document.querySelectorAll<HTMLElement>('#secs-container *')]
		.filter((el) => el.textContent?.trim() === TRIGGER)
		.pop();
	let row: HTMLElement | null = chip ?? null;
	while (row && !row.textContent?.includes(OUTPUT.slice(0, 12))) row = row.parentElement;
	if (row) {
		row.style.outline = `2px solid ${PERSONAL}`;
		row.style.borderRadius = '8px';
		row.style.background = 'rgba(51,140,255,0.18)';
	}
}

export const PersonalHotstrings: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const [targets, setTargets] = useState<Targets | null>(null);
	const onReady = useCallback((raw: Window) => {
		const win = raw as EditorWindow;
		const add = centre(win, '.btn-add');
		win.showAddEntry(0);
		const measured = {
			add,
			trigger: centre(win, '#e-trig'),
			output: centre(win, '#e-out'),
			save: centre(win, '#entry-modal .foot-btns .btn-p')
		};
		win.closeModal('entry-modal');
		setTargets(measured);
	}, []);
	const script = useCallback((win: Window, f: number) => stage(win as EditorWindow, f), []);
	const typing = useMemo(
		() =>
			compileTyping(
				[
					{ type: 'Great working with you all this week.\n\n' },
					{ hotstring: TRIGGER, demo: { output: OUTPUT, color: PERSONAL } }
				],
				fps,
				DOC_AT + 20,
				'personal'
			),
		[fps]
	);
	const waypoints: Waypoint[] | null = targets
		? [
				{ frame: 0, x: targets.add.x + 160, y: targets.add.y + 170 },
				{ frame: CLICK_ADD, ...targets.add, click: true },
				{ frame: CLICK_TRIGGER, ...targets.trigger, click: true },
				{ frame: CLICK_OUTPUT, ...targets.output, click: true },
				{ frame: CLICK_SAVE, ...targets.save, click: true },
				{ frame: CLICK_SAVE + 30, x: targets.save.x + 120, y: targets.save.y + 90 }
			]
		: null;
	const editor = Math.min(1, pop(frame, fps, 4));
	const doc = progress(frame, DOC_AT, 22);
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 110, width: 600 }}>
				<Caption
					chapter="Hotstrings"
					icon="👤"
					title="Create your own hotstrings, in seconds."
					sub="Pick a trigger, write the text, save. Active at once, in every app."
					size={56}
				/>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 760,
					top: 70,
					opacity: editor,
					transform: `translateY(${(1 - editor) * 80}px) scale(${1 - doc * 0.05})`,
					transformOrigin: 'top right'
				}}
			>
				<DriverWindow
					id="hotstring_editor"
					title="Personal hotstrings"
					scale={EDITOR_SCALE}
					script={script}
					onReady={onReady}
					overlay={
						waypoints ? (
							<Cursor
								waypoints={waypoints}
								frame={frame}
								opacity={1 - doc}
								scale={1 / EDITOR_SCALE}
							/>
						) : null
					}
				/>
			</div>
			<div style={{ position: 'absolute', left: 120, top: 600, ...rise(doc, 80) }}>
				<OsWindow
					os="windows"
					title="Re: Project update — Outlook"
					width={760}
					height={380}
					bodyStyle={{ padding: '30px 36px' }}
				>
					<TypedText typing={typing} fontSize={30} />
				</OsWindow>
			</div>
			{[CLICK_ADD, CLICK_TRIGGER, CLICK_OUTPUT, CLICK_SAVE].map((f) => (
				<Sfx key={f} name="key" at={f} volume={0.35} />
			))}
			<Sfx name="pop" at={CLICK_SAVE + 2} volume={0.3} />
			<KeySounds keys={typing.keys} />
			{typing.expansions.map((f) => (
				<Sfx key={f} name="pop" at={f} />
			))}
		</AbsoluteFill>
	);
};
