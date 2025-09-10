<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
</script>

<section>
	<h2>Diminution des SFBs</h2>
	<p>
		L’un des avantages majeurs de <ErgoptiPlus /> est qu’il réduit presque totalement les <SFB />s.
	</p>
	<p>
		Les <SFB />s les plus fréquents de la disposition sont : <kbd>CT</kbd>,
		<kbd>pt</kbd>, <kbd>eo</kbd>, <kbd>oe</kbd>,
		<kbd>ub</kbd>, <kbd>bu</kbd> et <kbd>ds</kbd>. <kbd>ct</kbd> est de loin le plus fréquent.
		<kbd>eo</kbd> et <kbd>oe</kbd> sont aussi relativement fréquents en anglais (pour écrire
		<kbd-output>does</kbd-output>,
		<kbd-output>people</kbd-output>, etc.) Tous ces <SFB />s sont supprimés avec <ErgoptiPlus />,
		plus de nombreux autres encore plus rares.
	</p>

	<h3>
		Utilisation de la touche <kbd>,</kbd> + <kbd>Consonne</kbd>
	</h3>
	<p>
		La touche <kbd>,</kbd> est l’une des plus importantes dans <ErgoptiPlus />. C’est grâce à elle
		que la plupart des <SFB />s restants sont supprimés. De plus, certaines combinaisons ont aussi
		été ajoutées pour plus de confort, afin d’éviter de devoir sauter de 2 rangées avec des doigts
		consécutifs pour écrire un bigramme (donc éviter les <em>ciseaux</em>). C’est le cas de
		<kbd>cl</kbd> ou encore de <kbd>ph</kbd>.
	</p>
	<KeyboardBasis id="virgule" />
	<p>
		Comme vous pouvez le constater, la touche <kbd>,</kbd> est vraiment pour supprimer les derniers
		petits <SFB />s restants. La disposition <Ergopti /> éliminait déjà la majorité d’entre eux.
	</p>

	<h3>Utilisation des touches <kbd>È</kbd> et <kbd>Ê</kbd></h3>
	<p>
		Les touches <kbd>È</kbd> et <kbd>Ê</kbd> permettent de se débarrasser des quelques <SFB />s se
		trouvant sur la main gauche. Plus particulièrement, ce sont les <SFB />s sur les touches
		<kbd>I</kbd>, <kbd>E</kbd> ainsi qu’en <kbd>U</kbd> :
	</p>
	<ul class="margin-top-2">
		<li>
			<kbd>êe</kbd> ➜ <kbd-output>oe</kbd-output> ;
		</li>
		<li>
			<kbd>eê</kbd> ➜ <kbd-output>eo</kbd-output> ;
		</li>
		<li>
			<kbd>ê,</kbd> ➜ <kbd-output>u,</kbd-output> ;
		</li>
		<li>
			<kbd>ê.</kbd> ➜ <kbd-output>u.</kbd-output> ;
		</li>
		<tiny-space></tiny-space>
		<li>
			<kbd>èy</kbd> ➜ <kbd-output>ié</kbd-output> ;
		</li>
		<li>
			<kbd>yè</kbd> ➜ <kbd-output>éi</kbd-output>.
		</li>
		<p>
			Idéalement, cela devrait plutôt être l’inverse afin d’être plus logique (le son YÈ donnant
			IÉ). Toutefois, <kbd-output>ié</kbd-output> étant beaucoup plus fréquent, il mérite d’avoir le
			roulement vers l’intérieur qui est plus confortable.
		</p>
	</ul>

	<h3>Utilisation de roulements</h3>
	<ul class="margin-top-2">
		<li><kbd>êé</kbd> ➜ <kbd-output>aî</kbd-output> ;</li>
		<li><kbd>éê</kbd> ➜ <kbd-output>â</kbd-output> ;</li>
		<li><kbd>p'</kbd> ➜ <kbd-output>ct</kbd-output> ;</li>
		<li><kbd>à★</kbd> ➜ <kbd-output>bu</kbd-output> ;</li>
		<li><kbd>àu</kbd> ➜ <kbd-output>ub</kbd-output>.</li>
	</ul>

	<h3>Touche <kbd>★</kbd> de répétition</h3>
	<p>
		De nombreux <SFB />s se produisent non pas à cause de deux touches devant être tapées par le
		même doigt, mais lors de la répétition de la même touche. C’est par exemple le cas avec
		<kbd>ll</kbd> (elle, pelle, telle, etc.) ou encore <kbd>rr</kbd> (terre, erreur, etc.).
	</p>
	<p>
		Sur le logiciel Excel, la touche <kbd>F4</kbd> permet de répéter la dernière action. Ne pourrait-on
		pas avoir la même chose sur sa disposition clavier ?
	</p>
	<tiny-space></tiny-space>
	<KeyboardBasis id="magique" />
	<tiny-space></tiny-space>
	<p>
		La touche <kbd>★</kbd> est <span class="important">l’ajout principal</span>
		d’<ErgoptiPlus /> et mérite son excellent emplacement sous l’index gauche. Elle vient en remplacement
		de la touche <kbd>J</kbd>
		(mais pas le contenu des autres couches de la touche <kbd>J</kbd> tel qu’en
		<kbd>AltGr</kbd> ou en <kbd>Ctrl</kbd>). Le <kbd>J</kbd> se retrouve quant à lui en <kbd>,</kbd>
		+
		<kbd>Voyelle</kbd>.
	</p>
	<p>
		La nouvelle touche <kbd>★</kbd>
		<span class="important">va répéter la dernière touche tapée</span>. Ainsi, <kbd>l★</kbd>
		va envoyer <kbd-output>ll</kbd-output>, tandis que <kbd>r★</kbd> va envoyer
		<kbd-output>rr</kbd-output>. Cela engendrera cependant un petit <SFB></SFB> pour les lettres doublées
		suivies d’un <kbd>U</kbd>, tel que « connu » ou « battu ». La combinaison <kbd>★ê</kbd> permet
		d’éviter ce problème. Ainsi, « connu » pourra s’écrire <kbd>con★ê</kbd> et « battu » pourra
		s’écrire <kbd>bat★ê</kbd>.
	</p>
	<p>
		L’utilisation de la touche <kbd>★</kbd> va instantanément fluidifier la fra<kbd>p★</kbd>e et
		réduire le nombre de <SFB />s. Une fois qu’on y est habitué, l’écriture au clavier devient
		encore un peu plus rapide et efficace, car même les lettres doublées peuvent être parallélisées.
		D’autant que
		<span class="important"
			>doubler les lettres est loin d’être la seule fonction de la touche
		</span>
		<kbd>★</kbd>…
	</p>
</section>
