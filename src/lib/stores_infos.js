import { writable } from 'svelte/store';
let valeurversion = '1.1.2';

async function loadData(version) {
	try {
		// Utiliser l'importation dynamique avec un chemin variable
		const data = await import(/* @vite-ignore */ `./clavier/data/hypertexte_v${version}.json`);
		// console.log('Données chargées :', data);
		return data;
	} catch (error) {
		console.error('Erreur lors du chargement des données :', error);
	}
}
export let data = writable(await loadData(valeurversion));
export const version = writable(valeurversion);

export const presentation = writable({
	emplacement: 'clavier_presentation',
	type: 'iso',
	couche: 'Visuel',
	plus: 'non',
	couleur: 'non',
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
	couleur: 'non',
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
