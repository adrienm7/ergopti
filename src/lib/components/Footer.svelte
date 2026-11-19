<script>
	import Ergopti from '#lib/components/Ergopti.svelte';
	import { discordLink } from '#lib/stores_infos.js';
	import { resolve } from '$app/paths';
	const date = new Date().getFullYear();
</script>

<footer lang="fr">
	<div>— <Ergopti></Ergopti> —</div>
	<nav aria-label="Liens du pied de page" style="font-size: 0.8rem; margin-top: 0.2rem;">
		<a href="https://github.com/adrienm7/ergopti" target="_blank" class="text-white"
			>Repo GitHub <i class="icon-github" aria-hidden="true"></i></a
		>
		<span style="position:relative; bottom:0.05em;" aria-hidden="true">|</span>
		<a href={discordLink} target="_blank" class="text-white"
			><span class="min-width-600">Serveur</span> Discord
			<i class="icon-discord" aria-hidden="true"></i></a
		>
		<span style="position:relative; bottom:0.05em;" aria-hidden="true">|</span>
		<a href={resolve('/accessibilite')} class="text-white">Accessibilité</a>
	</nav>
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
