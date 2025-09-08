<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<h2>Ponctuations avec espace insécable automatique</h2>
<p>
	Les ponctuations <kbd>;</kbd>, <kbd>:</kbd>, <kbd>?</kbd> et <kbd>!</kbd> ont une particularité.
	En effet, lors de l’utilisation de <kbd>Shift</kbd>, elles sont
	<span class="important">automatiquement envoyées avec un espace insécable</span> qui les précède. Les
	espaces insécables ne sont pas disponibles en AZERTY, et c’est très dommage. Ce sont des espaces qui
	ont pour comportement de toujours rester collés au texte qui les précède et les suit.
</p>
<p>
	Ainsi, vous n’aurez plus jamais de <kbd-output>?</kbd-output> qui se balade au début d’une ligne
	parce qu’il n’y avait plus de place sur la ligne précédente. Cela donne des documents avec un
	rendu bien plus professionnel. Attention cependant :
	<span class="important">ne les utilisez pas dans d’autres situations que l'écriture de texte</span
	>. Par exemple, en programmation, un espace insécable peut causer des erreurs, sans forcément être
	visible (vous ne verrez qu’un simple espace, qui pourtant sera la cause du problème).
</p>
<p>
	En revanche, en utilisant <kbd>AltGr</kbd>, la ponctuation seule est renvoyée. Cette méthode
	permet d’écrire dans un français impeccable en
	<kbd>Shift</kbd>, tout en programmant normalement avec la couche <kbd>AltGr</kbd>, qui contient
	d’ailleurs tout le reste des symboles nécessaires à l’écriture de code.
</p>
<tiny-space></tiny-space>
<div class="encadre">
	<p class="important margin0">Ainsi, il est facile de se rappeler où est quoi :</p>
	<ul class="margin0">
		<li>le français est en <kbd>Shift</kbd> ;</li>
		<li class="margin0">la programmation est en <kbd>AltGr</kbd>.</li>
	</ul>
</div>
