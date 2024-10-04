<script>
	import BaseClavier from '$lib/clavier/BaseClavier.svelte';
	import { Clavier } from '$lib/clavier/FonctionsClavier.js';
	import { onMount } from 'svelte';

	import * as data_clavier from '$lib/clavier/etat_claviers.js';
	import data from '$lib/clavier/data/hypertexte_v1.1.2.json';
	import { version } from '$lib/stores_infos.js';
	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});

	export let nom;
	onMount(() => {
		// data = import(/* @vite-ignore */ `./data/hypertexte_v${versionValue}.json`);
		let clavier = new Clavier(nom, data_clavier, versionValue, data);
		clavier.majClavier();
	});
</script>

<bloc-clavier id={'clavier_' + nom}>
	<BaseClavier />
</bloc-clavier>
