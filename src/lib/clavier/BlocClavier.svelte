<script>
	import BaseClavier from '$lib/clavier/BaseClavier.svelte';
	import { Clavier } from '$lib/clavier/Clavier.js';
	import { onMount } from 'svelte';

	export let nom;
	let clavier = new Clavier(nom);
</script>

<bloc-clavier id={'clavier_' + nom}>
	<BaseClavier />
</bloc-clavier>
