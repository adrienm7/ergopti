<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import { discordLink } from '$lib/stores_infos.js';
	const date = new Date().getFullYear();
</script>

<footer>
	<div>— Disposition <Ergopti></Ergopti> —</div>
	<div style="font-size: 0.8rem; margin-top: 0.2rem;">
		<a href="https://github.com/adrienm7/ergopti" target="_blank" class="text-white"
			>Repo GitHub <i class="icon-github"></i></a
		>
		<span style="position:relative; bottom:0.05em;">|</span>
		<a href={discordLink} target="_blank" class="text-white"
			><span class="min-width-600">Serveur</span> Discord <i class="icon-discord"></i></a
		>
	</div>
</footer>

<style>
	footer {
		align-items: center;
		background-color: rgba(0, 0, 0, 0.8);
		border-top: 1px solid rgb(200, 200, 200);
		/* box-shadow: 0 0 3px 2px var(--couleur-ombre); */
		color: white;
		display: flex;
		flex-direction: column;
		font-size: 1.1rem;
		height: 4.5rem;
		justify-content: center;
		text-align: center;
	}
</style>
