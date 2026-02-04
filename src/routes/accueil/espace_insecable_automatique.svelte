<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<section>
	<h2>Ponctuations avec espace insécable automatique</h2>
	<p>
		Les signes <kbd>;</kbd>, <kbd>:</kbd>, <kbd>?</kbd> et <kbd>!</kbd> bénéficient d'un traitement
		intelligent. Saisis sur la couche <kbd>Shift</kbd>, ils sont
		<strong>automatiquement insérés précédés d’une espace insécable</strong>. Contrairement à une
		espace classique, ce caractère spécial garantit que la ponctuation reste toujours solidaire du
		mot qui la précède. Résultat : fini les <kbd-output>?</kbd-output> orphelins rejetés seuls en début
		de ligne ! Tous vos documents, e-mails, messages sur les réseaux sociaux et autres textes gagneront
		instantanément en professionnalisme.
	</p>
	<p>
		⚠ <strong>Attention toutefois :</strong> ce raccourci est à réserver uniquement à la rédaction
		de texte courant — et uniquement pour le français d’ailleurs, car en anglais la convention est
		de ne pas mettre d’espace avant les ponctuations. En revanche, lors de l’écriture de code
		informatique, cette espace — souvent non distinguable visuellement d’une espace classique — sera
		considérée comme un caractère invalide et provoquera des erreurs de syntaxe. Pour coder, il
		faudra donc plutôt utiliser la couche
		<kbd>AltGr</kbd>, car celle-ci envoie la
		<strong>ponctuation brute</strong> (sans espace automatique). Cela permet de programmer
		sereinement tout en conservant la possibilité d'écrire un français typographiquement impeccable
		avec <kbd>Shift</kbd>.
	</p>
	<tiny-space></tiny-space>
	<div class="encadre">
		<p class="important margin0">La règle est donc simple à mémoriser :</p>
		<ul class="margin0">
			<li><kbd>Shift</kbd> pour le français (typographie soignée) ;</li>
			<li class="margin0"><kbd>AltGr</kbd> pour la programmation (code brut) et l’anglais.</li>
		</ul>
	</div>
</section>
