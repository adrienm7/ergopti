<script>
	import BaseClavier from '$lib/clavier/BaseClavier.svelte';
	import { Clavier } from '$lib/clavier/FonctionsClavier.js';
	import { onMount } from 'svelte';

	import { version } from '$lib/stores_infos.js';
	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});

	import data from '$lib/clavier/data/hypertexte_v1.1.2.json';
	import * as data_clavier from '$lib/clavier/etat_claviers.js';

	let claviersStores = {};
	for (const clavier in Object.keys(data_clavier)) {
		claviersStores[clavier] = data_clavier[clavier];
	}

	export let nom;
	let clavier = new Clavier(nom);
	onMount(() => {
		clavier.majClavier();
	});
</script>

<bloc-clavier id={'clavier_' + nom}>
	<BaseClavier />
</bloc-clavier>
