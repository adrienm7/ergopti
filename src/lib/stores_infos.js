import { writable } from 'svelte/store';
export const versionsList = ['1.1', '2.0', '2.1', '2.2'];
export const latestVersion = versionsList[versionsList.length - 1];
export let version = writable(latestVersion); // Default value

export const layoutData = writable();
export const discordLink = 'https://discord.gg/ptxRzBqcQP';

export const presentation = writable({
	emplacement: 'clavier_presentation',
	plus: 'no',
	type: 'iso',
	layer: 'Visuel',
	color: 'yes',
	controls: 'yes'
});

export const presentation_plus = writable({
	emplacement: 'clavier_presentation_plus',
	plus: 'yes',
	type: 'iso',
	layer: 'Visuel',
	color: 'yes',
	controls: 'yes'
});

export const reference = writable({
	emplacement: 'clavier_reference',
	plus: 'yes',
	type: 'ergodox',
	layer: 'Visuel',
	color: 'yes',
	controls: 'yes'
});

export const emulation = writable({
	emplacement: 'clavier_emulation',
	plus: 'yes',
	type: 'iso',
	layer: 'Primary',
	color: 'yes',
	controls: 'no'
});

export const frequences = writable({
	emplacement: 'clavier_frequences',
	plus: 'no',
	type: 'iso',
	layer: 'Primary',
	color: 'freq',
	controls: 'no'
});

export const roulements = writable({
	emplacement: 'clavier_roulements',
	plus: 'no',
	type: 'iso',
	layer: 'Visuel',
	color: 'no',
	controls: 'no'
});

export const controle = writable({
	emplacement: 'clavier_controle',
	plus: 'no',
	type: 'ergodox',
	layer: 'Ctrl',
	color: 'yes',
	controls: 'yes'
});

export const raccourcis_ergodox = writable({
	emplacement: 'clavier_raccourcis_ergodox',
	plus: 'no',
	type: 'ergodox',
	layer: 'Ctrl',
	color: 'yes',
	controls: 'yes'
});

export const symboles = writable({
	emplacement: 'clavier_symboles',
	plus: 'no',
	type: 'iso',
	layer: 'AltGr',
	color: 'no',
	controls: 'yes'
});

export const symboles_plus = writable({
	emplacement: 'clavier_symboles_plus',
	plus: 'yes',
	type: 'ergodox',
	layer: 'AltGr',
	color: 'no',
	controls: 'no'
});

export const magique = writable({
	emplacement: 'clavier_magique',
	plus: 'yes',
	type: 'iso',
	layer: 'Visuel',
	color: 'no',
	controls: 'no'
});

export const layer = writable({
	emplacement: 'clavier_layer',
	plus: 'yes',
	type: 'iso',
	layer: 'Layer',
	color: 'no',
	controls: 'yes'
});

export const a = writable({
	emplacement: 'clavier_a',
	plus: 'yes',
	type: 'iso',
	layer: 'À',
	color: 'no',
	controls: 'yes'
});

export const virgule = writable({
	emplacement: 'clavier_virgule',
	plus: 'yes',
	type: 'iso',
	layer: ',',
	color: 'no',
	controls: 'yes'
});
