<script>
	import ChangementType from '$lib/clavier/controles/ChangementType.svelte';
	import ChangementCouleur from '$lib/clavier/controles/ChangementCouleur.svelte';
	import ChangementPlus from '$lib/clavier/controles/ChangementPlus.svelte';
	import ChangementCouche from '$lib/clavier/controles/ChangementCouche.svelte';

	import { Clavier } from '$lib/clavier/FonctionsClavier.js';
	import { onMount } from 'svelte';

	import data from '$lib/clavier/data/hypertexte_v1.1.2.json';
	import * as data_clavier from '$lib/stores_infos.js';
	let versionValue;
	data_clavier.version.subscribe((value) => {
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
	let clavier = new Clavier(nom, versionValue, data);
	onMount(() => {
		clavier.majClavier();
	});

	let texte = '';

	function handleMessage(event) {
		data_clavier[nom].update((currentData) => {
			currentData['type'] = event.detail.type;
			currentData['couleur'] = event.detail.couleur;
			currentData['plus'] = event.detail.plus;
			currentData['couche'] = event.detail.couche;
			return currentData;
		});
		clavier.majClavier();
	}
</script>

<controles-clavier id={'controles_' + nom}>
	<ChangementType
		on:message={handleMessage}
		coucheValue={clavier.infos_clavier.couche}
		typeValue={clavier.infos_clavier.type}
		couleurValue={clavier.infos_clavier.couleur}
		plusValue={clavier.infos_clavier.plus}
	/>
	<ChangementPlus
		on:message={handleMessage}
		coucheValue={clavier.infos_clavier.couche}
		typeValue={clavier.infos_clavier.type}
		couleurValue={clavier.infos_clavier.couleur}
		plusValue={clavier.infos_clavier.plus}
	/>
	<ChangementCouleur
		on:message={handleMessage}
		coucheValue={clavier.infos_clavier.couche}
		typeValue={clavier.infos_clavier.type}
		couleurValue={clavier.infos_clavier.couleur}
		plusValue={clavier.infos_clavier.plus}
	/>
	<ChangementCouche
		on:message={handleMessage}
		coucheValue={clavier.infos_clavier.couche}
		typeValue={clavier.infos_clavier.type}
		couleurValue={clavier.infos_clavier.couleur}
		plusValue={clavier.infos_clavier.plus}
	/>
</controles-clavier>
{#if nom === 'roulements'}
	<controles-clavier class="btn-group">
		<select bind:value={texte} on:change={() => taperTexte(texte, 250, false)}>
			<option value="none" selected disabled hidden>Roulements voyelles</option>
			{#each roulements_voyelles as value}<option {value}>{value.toUpperCase()}</option>{/each}
		</select>
		<select bind:value={texte} on:change={() => taperTexte(texte, 250, false)}>
			<option value="none" selected disabled hidden>Roulements consonnes</option>
			{#each roulements_consonnes as value}<option {value}>{value.toUpperCase()}</option>{/each}
		</select>
	</controles-clavier>
{/if}
