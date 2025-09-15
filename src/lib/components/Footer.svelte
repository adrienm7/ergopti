<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import { discordLink } from '$lib/stores_infos.js';
	const date = new Date().getFullYear();
</script>

<footer>
	<p>
		Disposition <Ergopti></Ergopti> —
		<a href="https://github.com/adrienm7/ergopti" class="text-white"
			>GitHub <i class="icon-github"></i></a
		>
		|
		<a href={discordLink} class="text-white">Discord <i class="icon-discord"></i></a>
	</p>
</footer>

<style>
	footer {
		align-items: center;
		background-color: rgba(0, 0, 0, 0.8);
		box-shadow: 0 0 3px 2px var(--couleur-ombre);
		color: white;
		display: flex;
		font-size: 0.9rem;
		height: min(calc(5vh + 2vw), 80px);
		justify-content: center;
	}
</style>
