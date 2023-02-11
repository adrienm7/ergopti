<script>
	import Nom from '../../composants/Nom.svelte';
	import Nom_Plus from '../../composants/Nom_Plus.svelte';
</script>

<h2>Abréviations</h2>
<h3>Ajout des suffixes les plus communs en <kbd>,</kbd></h3>
<p>
	Il y a toujours un espace après la virgule (sauf si l’on écrit des nombres). Par conséquent, toute
	combinaison de type <kbd>,s</kbd> ou <kbd>,c</kbd> n’est jamais tapée. Cela donne une opportunité
	extraordinaire de raccourcis pour augmenter sa vitesse et son confort de frappe. Par exemple, au
	lieu de taper 5 lettres pour écrire le suffixe <kbd>EMENT</kbd>, très souvent utilisé en français,
	deux frappes suffisent : <kbd>,S</kbd>. Ces raccourcis vont diviser par deux le nombre de touches
	nécessaires pour écrire les suffixes les plus communs, entrainant une petite augmentation de
	vitesse.
</p>
<p>
	Le confort est aussi visé, par exemple pour la combinaison <em>GHT</em> qui est un peu
	inconfortable à faire en <Nom />, car il faut frapper de l’annulaire droit, du majeur droit, puis
	encore de l’annulaire droit. Ce n’est pas un beau roulement, alors qu’au contraire <kbd>,I</kbd>
	écrira <em>IGHT</em> et <kbd>,O</kbd> écrira <em>OUGH</em>.
</p>

<h3>Remplacement de texte avec <kbd>"</kbd></h3>
<p>
	La touche <kbd>"</kbd> est surtout utilisée pour entourer du texte. Dans la plupart des éditeurs,
	l’appui sur cette touche va directement écrire <kbd>""</kbd>. Il est toutefois tout à fait
	possible de l’utiliser comme touche de raccourci, car là encore les mots <em>c"</em> et
	<em>gt"</em> n’existent pas. Ainsi, l’écriture de l’abréviation puis du guillemet ne va pas écrire
	de guillemet mais plutôt transformer le texte écrit.
</p>

<ul class="margin-top-2">
	<li><kbd>A"</kbd> ➜ <em>Ainsi</em></li>
	<li><kbd>C"</kbd> ➜ <em>C’est</em></li>
	<li><kbd>Ct"</kbd> ➜ <em>C’était</em></li>
	<li><kbd>D"</kbd> ➜ <em>Donc</em></li>
	<li><kbd>Dé"</kbd> ➜ <em>Déjà</em></li>
	<li><kbd>Ê"</kbd> ➜ <em>Être</em></li>
	<li><kbd>Eef"</kbd> ➜ <em>En effet</em></li>
	<li><kbd>F"</kbd> ➜ <em>Faire</em></li>
	<li><kbd>G"</kbd> ➜ <em>J’ai</em></li>
	<li><kbd>Gt"</kbd> ➜ <em>J’étais</em></li>
	<li><kbd>M"</kbd> ➜ <em>Mais</em></li>
	<li><kbd>Pê"</kbd> ➜ <em>Peut-être</em></li>
	<li><kbd>Pex"</kbd> ➜ <em>Par exemple</em></li>
	<li><kbd>R"</kbd> ➜ <em>Rien</em></li>
</ul>

<p>
	Ici aussi, dans des cas rares cela ne peut pas fonctionner. Peut-être que vous voudrez réellement
	écrire <em>"ê"</em> dans un texte, ce qui activera malencontrueusement le remplacement en
	<em>"être</em>. Cela ne devrait presque jamais arriver, car écrire ce genre de texte arrive
	surtout pour tester des conditions en programmation notamment, et dans les IDE l’ajout automatique
	des deux guillemets fait tout fonctionner comme il le faut.
</p>
