<script>
	import BaseClavier from '$lib/clavier/BaseClavier.svelte';
	import { onMount } from 'svelte';
	import { majClavier } from '$lib/clavier/FonctionsClavier.js';
	export let clavier;

	onMount(() => {
		majClavier(clavier);
	});
</script>

<bloc-clavier id={'clavier_' + clavier}>
	<BaseClavier />
</bloc-clavier>
