import { writable } from 'svelte/store';
export const versionsList = ['1.1', '2.0', '2.1', '2.2'].reverse();
export const latestVersion = versionsList[0];
export let version = writable(latestVersion); // Default value

export const layoutData = writable();
export const discordLink = 'https://discord.gg/ptxRzBqcQP';

export const presentation = writable({
	emplacement: 'keyboard_presentation',
	plus: 'no',
	type: 'iso',
	layer: 'Visuel',
	color: 'yes',
	controls: 'yes'
});

export const presentation_plus = writable({
	emplacement: 'keyboard_presentation_plus',
	plus: 'yes',
	type: 'iso',
	layer: 'Visuel',
	color: 'yes',
	controls: 'yes'
});

export const reference = writable({
	emplacement: 'keyboard_reference',
	plus: 'yes',
	type: 'ergodox',
	layer: 'Visuel',
	color: 'yes',
	controls: 'yes'
});

export const emulation = writable({
	emplacement: 'keyboard_emulation',
	plus: 'yes',
	type: 'iso',
	layer: 'Primary',
	color: 'yes',
	controls: 'no'
});

export const frequences = writable({
	emplacement: 'keyboard_frequences',
	plus: 'no',
	type: 'iso',
	layer: 'Primary',
	color: 'freq',
	controls: 'no'
});

export const roulements = writable({
	emplacement: 'keyboard_roulements',
	plus: 'no',
	type: 'iso',
	layer: 'Visuel',
	color: 'no',
	controls: 'no'
});

export const controle = writable({
	emplacement: 'keyboard_controle',
	plus: 'no',
	type: 'ergodox',
	layer: 'Ctrl',
	color: 'yes',
	controls: 'yes'
});

export const raccourcis_ergodox = writable({
	emplacement: 'keyboard_raccourcis_ergodox',
	plus: 'no',
	type: 'ergodox',
	layer: 'Ctrl',
	color: 'yes',
	controls: 'yes'
});

export const symboles = writable({
	emplacement: 'keyboard_symboles',
	plus: 'no',
	type: 'iso',
	layer: 'AltGr',
	color: 'no',
	controls: 'yes'
});

export const symboles_plus = writable({
	emplacement: 'keyboard_symboles_plus',
	plus: 'yes',
	type: 'ergodox',
	layer: 'AltGr',
	color: 'no',
	controls: 'no'
});

export const magique = writable({
	emplacement: 'keyboard_magique',
	plus: 'yes',
	type: 'iso',
	layer: 'Visuel',
	color: 'no',
	controls: 'no'
});

export const layer = writable({
	emplacement: 'keyboard_layer',
	plus: 'yes',
	type: 'iso',
	layer: 'Layer',
	color: 'no',
	controls: 'yes'
});

export const a = writable({
	emplacement: 'keyboard_a',
	plus: 'yes',
	type: 'iso',
	layer: 'À',
	color: 'no',
	controls: 'yes'
});

export const virgule = writable({
	emplacement: 'keyboard_virgule',
	plus: 'yes',
	type: 'iso',
	layer: ',',
	color: 'no',
	controls: 'yes'
});
