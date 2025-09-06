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
	plus: 'non',
	couleur: 'oui',
	controls: 'oui'
});

export const presentation_plus = writable({
	emplacement: 'clavier_presentation_plus',
	type: 'iso',
	layer: 'Visuel',
	plus: 'oui',
	couleur: 'oui',
	controls: 'oui'
});

export const reference = writable({
	emplacement: 'clavier_reference',
	type: 'ergodox',
	layer: 'Visuel',
	plus: 'oui',
	couleur: 'oui',
	controls: 'oui'
});

export const emulation = writable({
	emplacement: 'clavier_emulation',
	type: 'iso',
	layer: 'Primary',
	plus: 'oui',
	couleur: 'oui',
	controls: 'non'
});

export const frequences = writable({
	emplacement: 'clavier_frequences',
	type: 'iso',
	layer: 'Primary',
	plus: 'non',
	couleur: 'freq',
	controls: 'non'
});

export const roulements = writable({
	emplacement: 'clavier_roulements',
	type: 'iso',
	layer: 'Visuel',
	plus: 'non',
	couleur: 'non',
	controls: 'non'
});

export const controle = writable({
	emplacement: 'clavier_controle',
	type: 'ergodox',
	layer: 'Ctrl',
	plus: 'non',
	couleur: 'oui',
	controls: 'oui'
});

export const raccourcis_ergodox = writable({
	emplacement: 'clavier_raccourcis_ergodox',
	type: 'ergodox',
	layer: 'Ctrl',
	plus: 'non',
	couleur: 'oui',
	controls: 'oui'
});

export const symboles = writable({
	emplacement: 'clavier_symboles',
	type: 'iso',
	layer: 'AltGr',
	plus: 'non',
	couleur: 'non',
	controls: 'oui'
});

export const symboles_plus = writable({
	emplacement: 'clavier_symboles_plus',
	type: 'ergodox',
	layer: 'AltGr',
	plus: 'oui',
	couleur: 'non',
	controls: 'non'
});

export const magique = writable({
	emplacement: 'clavier_magique',
	type: 'iso',
	layer: 'Visuel',
	plus: 'oui',
	couleur: 'non',
	controls: 'non'
});

export const layer = writable({
	emplacement: 'clavier_layer',
	type: 'iso',
	layer: 'Layer',
	plus: 'oui',
	couleur: 'non',
	controls: 'oui'
});

export const a = writable({
	emplacement: 'clavier_a',
	type: 'iso',
	layer: 'À',
	plus: 'oui',
	couleur: 'non',
	controls: 'oui'
});

export const virgule = writable({
	emplacement: 'clavier_virgule',
	type: 'iso',
	layer: ',',
	plus: 'oui',
	couleur: 'non',
	controls: 'oui'
});
