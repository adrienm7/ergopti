<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<section>
	<h2 class="first-h2">Comment bien utiliser KLAnext</h2>
	<p>
		Pour bien utiliser des comparateurs de disposition, il faut <strong
			>comparer ce qui est comparable</strong
		>. Ceci est très important, car si vous ne le faites pas, alors vos résultats n’auront aucune
		valeur.
	</p>
	<tiny-space></tiny-space>
	<h3>Comparer le même type de clavier</h3>
	<p>
		Ne comparez pas une disposition ISO avec une disposition Ergodox. Sinon, logiquement la
		disposition Ergodox sera mieux notée. Elle aura en effet une distance aux touches moindre, car
		les pouces seront beaucoup plus mis à contribution. En outre, les <SFB />s seront diminués, car
		<kbd>Shift</kbd>, <kbd>Enter</kbd>, etc. ne seront plus sur les auriculaires mais sur les
		pouces.
	</p>

	<tiny-space></tiny-space>
	<h3>Comparer des claviers possédant une touche pour tous les caractères du corpus</h3>
	<p>
		Un autre point à bien faire attention est de <strong
			>s’assurer que toutes les lettres soient bien dans les dispositions à comparer</strong
		>. Une disposition faite pour la langue anglaise aura de très bons scores pour des textes
		français. Cela s’explique parce que tous les caractères accentués seront "sautés", n’existant
		pas dans la disposition anglophone.
	</p>

	<tiny-space></tiny-space>
	<h3>Conclusion sur la comparaison de dispositions</h3>
	<p>
		Comparer des dispositions n’est pas aussi simple qu’on pourrait de prime abord le penser. Il ne
		suffit pas de balancer son texte et sa disposition dans un comparateur et de le faire tourner.
	</p>

	<p>
		En outre, la philosophie derrière la construction de la disposition doit être prise en compte.
		Certaines dispositions comme Optimot préfèrent mettre l’apostrophe droite en accès direct plutôt
		que celle typographique, partant du principe que la plupart des éditeurs de texte la
		remplaceront de toute manière par l’apostrophe typographique. Dans ce cas précis, le caractère
		faisant office d’"apostrophe" est l’apostrophe droite, alors que d’autres dispositions (comme
		une version précédente d’<Ergopti />) font la distinction entre les deux. Pour comparer avec le
		plus d’exactitude les dispositions, il faudrait alors les modifier pour soit remplacer
		l’apostrophe typographique par une apostrophe droite, soit en ajoutant une apostrophe
		typographique dans la disposition n’en ayant pas.
	</p>
	<p>
		De même, si une disposition part du principe que l’appui sur la touche <kbd>Q</kbd> donne
		<kbd-output>QU</kbd-output>
		comme le proposent Optimot ou <ErgoptiPlus></ErgoptiPlus>, alors il faut s’assurer que le corpus
		reflète aussi cette modification. Pour cela, il convient de remplacer tous les "qu" par des "q"
		dans le corpus. Cela permet alors de placer le <kbd>Q</kbd> sur la colonne du <kbd>U</kbd> sans
		que cela ne génère de <SFB></SFB>s. Oublier de modifier le corpus va entraîner une énorme
		augmentation des <SFB></SFB>s alors que ce n’est pas "mérité".
	</p>
	<p class="important">
		➜ Comparer ce qui est comparable. Si le symbole n’existe pas dans la disposition, la touche ne
		sera pas tapée.
	</p>
</section>
