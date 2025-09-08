import { writable } from 'svelte/store';
export const versionsList = ['1.1', '2.0', '2.1', '2.2'];
export const latestVersion = versionsList[versionsList.length - 1];
export let version = writable(latestVersion); // Default value

export const layoutData = writable();
export const discordLink = 'https://discord.gg/ptxRzBqcQP';

export const presentation = writable({
	emplacement: 'clavier_presentation',
	type: 'iso',
	layer: 'Visuel',
	plus: 'no',
	couleur: 'yes',
	controls: 'yes'
});

export const presentation_plus = writable({
	emplacement: 'clavier_presentation_plus',
	type: 'iso',
	layer: 'Visuel',
	plus: 'yes',
	couleur: 'yes',
	controls: 'yes'
});

export const reference = writable({
	emplacement: 'clavier_reference',
	type: 'ergodox',
	layer: 'Visuel',
	plus: 'yes',
	couleur: 'yes',
	controls: 'yes'
});

export const emulation = writable({
	emplacement: 'clavier_emulation',
	type: 'iso',
	layer: 'Primary',
	plus: 'yes',
	couleur: 'yes',
	controls: 'no'
});

export const frequences = writable({
	emplacement: 'clavier_frequences',
	type: 'iso',
	layer: 'Primary',
	plus: 'no',
	couleur: 'freq',
	controls: 'no'
});

export const roulements = writable({
	emplacement: 'clavier_roulements',
	type: 'iso',
	layer: 'Visuel',
	plus: 'no',
	couleur: 'no',
	controls: 'no'
});

export const controle = writable({
	emplacement: 'clavier_controle',
	type: 'ergodox',
	layer: 'Ctrl',
	plus: 'no',
	couleur: 'yes',
	controls: 'yes'
});

export const raccourcis_ergodox = writable({
	emplacement: 'clavier_raccourcis_ergodox',
	type: 'ergodox',
	layer: 'Ctrl',
	plus: 'no',
	couleur: 'yes',
	controls: 'yes'
});

export const symboles = writable({
	emplacement: 'clavier_symboles',
	type: 'iso',
	layer: 'AltGr',
	plus: 'no',
	couleur: 'no',
	controls: 'yes'
});

export const symboles_plus = writable({
	emplacement: 'clavier_symboles_plus',
	type: 'ergodox',
	layer: 'AltGr',
	plus: 'yes',
	couleur: 'no',
	controls: 'no'
});

export const magique = writable({
	emplacement: 'clavier_magique',
	type: 'iso',
	layer: 'Visuel',
	plus: 'yes',
	couleur: 'no',
	controls: 'no'
});

export const layer = writable({
	emplacement: 'clavier_layer',
	type: 'iso',
	layer: 'Layer',
	plus: 'yes',
	couleur: 'no',
	controls: 'yes'
});

export const a = writable({
	emplacement: 'clavier_a',
	type: 'iso',
	layer: 'À',
	plus: 'yes',
	couleur: 'no',
	controls: 'yes'
});

export const virgule = writable({
	emplacement: 'clavier_virgule',
	type: 'iso',
	layer: ',',
	plus: 'yes',
	couleur: 'no',
	controls: 'yes'
});
