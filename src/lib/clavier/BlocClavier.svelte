<script>
	import BaseClavier from '$lib/clavier/BaseClavier.svelte';
	import { Clavier } from '$lib/clavier/FonctionsClavier.js';
	import { onMount } from 'svelte';

	import * as data_clavier from '$lib/clavier/etat_claviers.js';
	import { version } from '$lib/stores_infos.js';
	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});

	let path = `./data/hypertexte_v${versionValue}.json`;

	async function loadData() {
		try {
			// Utiliser l'importation dynamique avec un chemin variable
			const data = await import(/* @vite-ignore */ path);
			// console.log('Données chargées :', data);
			return data;
		} catch (error) {
			console.error('Erreur lors du chargement des données :', error);
		}
	}

	export let nom;
	onMount(() => {
		loadData(versionValue).then((data) => {
			let clavier = new Clavier(nom, data_clavier, versionValue, data);
			clavier.majClavier();
		});
	});
</script>

<bloc-clavier id={'clavier_' + nom}>
	<BaseClavier />
</bloc-clavier>
