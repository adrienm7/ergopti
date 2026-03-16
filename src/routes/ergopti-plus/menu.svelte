<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<section>
	<h2 class="first-h2">Menu de gestion des fonctionnalités</h2>

	<p>
		Sur Windows et macOS, les versions <ErgoptiPlus></ErgoptiPlus> possèdent même désormais un menu de
		gestion de chacune des fonctionnalités implémentées :
	</p>
	<enhanced:img
		src="$lib/images/menu_ergopti_plus.jpg"
		alt="Screenshot du menu du script Ergopti+"
	/>
	<tiny-space></tiny-space>
	<enhanced:img
		src="$lib/images/ergopti_plus_macos.png"
		alt="Screenshot du menu du script Ergopti+ sur macOS"
	/>

	<p>
		Un clic droit sur l’icône du script dans la barre des tâches permet d’ouvrir le menu du script.
		Chaque fonctionnalité y est visible et peut être activée ou désactivée, avec toutes les autres
		features activées qui restent fonctionnelles. Ce menu permet de voir rapidement toutes les
		possibilités d’<ErgoptiPlus></ErgoptiPlus> et de désactiver les fonctionnalités dont vous ne voulez
		pas.
	</p>
</section>
