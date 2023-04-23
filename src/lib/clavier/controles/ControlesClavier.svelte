<script>
	import ChangementType from '$lib/clavier/controles/ChangementType.svelte';
	import ChangementCouleur from '$lib/clavier/controles/ChangementCouleur.svelte';
	import ChangementPlus from '$lib/clavier/controles/ChangementPlus.svelte';
	import ChangementCouche from '$lib/clavier/controles/ChangementCouche.svelte';

	import { majClavier } from '$lib/clavier/FonctionsClavier.js';
	export let clavier;

	import * as data_clavier from '$lib/clavier/stores.js';
	let claviersStores = {};
	for (const clavier in Object.keys(data_clavier)) {
		claviersStores[clavier] = data_clavier[clavier];
	}

	let infos_clavier;
	data_clavier[clavier].subscribe((value) => {
		infos_clavier = value;
	});

	function handleMessage(event) {
		data_clavier[clavier].update((currentData) => {
			currentData['type'] = event.detail.type;
			currentData['couleur'] = event.detail.couleur;
			currentData['plus'] = event.detail.plus;
			currentData['couche'] = event.detail.couche;
			return currentData;
		});
		majClavier(clavier);
	}
</script>

<controles-clavier id={'controles_' + clavier}>
	<ChangementType
		on:message={handleMessage}
		coucheValue={infos_clavier.couche}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
	<ChangementPlus
		on:message={handleMessage}
		coucheValue={infos_clavier.couche}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
	<ChangementCouleur
		on:message={handleMessage}
		coucheValue={infos_clavier.couche}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
	<ChangementCouche
		on:message={handleMessage}
		coucheValue={infos_clavier.couche}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
</controles-clavier>
<!-- {#if controles === 'roulements'}
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
{/if} -->
