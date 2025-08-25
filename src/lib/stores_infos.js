import { writable } from 'svelte/store';
export const liste_versions = ['1.1', '2.0', '2.1', '2.2'];
export const latestVersion = liste_versions[liste_versions.length - 1];
export let version = writable(latestVersion); // Default value

export const data_disposition = writable();
export const discord_link = 'https://discord.gg/ptxRzBqcQP';

export const presentation = writable({
	emplacement: 'clavier_presentation',
	type: 'iso',
	couche: 'Visuel',
	plus: 'non',
	couleur: 'oui',
	controles: 'oui'
});

export const presentation_plus = writable({
	emplacement: 'clavier_presentation_plus',
	type: 'iso',
	couche: 'Visuel',
	plus: 'oui',
	couleur: 'oui',
	controles: 'oui'
});

export const reference = writable({
	emplacement: 'clavier_reference',
	type: 'ergodox',
	couche: 'Visuel',
	plus: 'oui',
	couleur: 'oui',
	controles: 'oui'
});

export const emulation = writable({
	emplacement: 'clavier_emulation',
	type: 'iso',
	couche: 'Primary',
	plus: 'oui',
	couleur: 'oui',
	controles: 'non'
});

export const frequences = writable({
	emplacement: 'clavier_frequences',
	type: 'iso',
	couche: 'Primary',
	plus: 'non',
	couleur: 'freq',
	controles: 'non'
});

export const roulements = writable({
	emplacement: 'clavier_roulements',
	type: 'iso',
	couche: 'Visuel',
	plus: 'non',
	couleur: 'non',
	controles: 'non'
});

export const controle = writable({
	emplacement: 'clavier_controle',
	type: 'ergodox',
	couche: 'Ctrl',
	plus: 'non',
	couleur: 'oui',
	controles: 'oui'
});

export const raccourcis_ergodox = writable({
	emplacement: 'clavier_raccourcis_ergodox',
	type: 'ergodox',
	couche: 'Ctrl',
	plus: 'non',
	couleur: 'oui',
	controles: 'oui'
});

export const symboles = writable({
	emplacement: 'clavier_symboles',
	type: 'iso',
	couche: 'AltGr',
	plus: 'non',
	couleur: 'non',
	controles: 'oui'
});

export const symboles_plus = writable({
	emplacement: 'clavier_symboles_plus',
	type: 'ergodox',
	couche: 'AltGr',
	plus: 'oui',
	couleur: 'non',
	controles: 'non'
});

export const magique = writable({
	emplacement: 'clavier_magique',
	type: 'iso',
	couche: 'Visuel',
	plus: 'oui',
	couleur: 'non',
	controles: 'non'
});

export const layer = writable({
	emplacement: 'clavier_layer',
	type: 'iso',
	couche: 'Layer',
	plus: 'oui',
	couleur: 'non',
	controles: 'oui'
});

export const a = writable({
	emplacement: 'clavier_a',
	type: 'iso',
	couche: 'À',
	plus: 'oui',
	couleur: 'non',
	controles: 'oui'
});

export const virgule = writable({
	emplacement: 'clavier_virgule',
	type: 'iso',
	couche: ',',
	plus: 'oui',
	couleur: 'non',
	controles: 'oui'
});
