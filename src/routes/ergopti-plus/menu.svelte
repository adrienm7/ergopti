<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import img from '$lib/images/menu_ergopti_plus.jpg';
</script>

<h2>Menu de gestion des fonctionnalités</h2>

<img src={img} style="width:100%" />

<p>
	Un clic droit sur l’icône du script dans la barre des tâches permet d’ouvrir le menu du script.
	Chaque feature y est visible et peut être activée ou désactivée, avec toutes les autres features
	activées qui restent fonctionnelles. Ce menu permet de voir rapidement toutes les possibilités d’<NomPlus
	></NomPlus> et de désactiver les fonctionnalités dont vous ne voulez pas.
</p>
