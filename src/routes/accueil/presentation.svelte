<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import { taperTexte } from '$lib/clavier/taperTexte.js';
	let texte;
	let roulements_voyelles = [
		'ai',
		'aie',
		'au',
		'eu',
		'ée',
		'ie',
		'ieu',
		'io',
		'oi',
		'ou',
		'ow',
		'wo',
		'you'
	];
	let roulements_consonnes = [
		'ch',
		'd’',
		'ld',
		'nc',
		'ng',
		'ns',
		'nt',
		'ntr',
		'pl',
		'pr',
		'rs',
		'tr'
	];
</script>

<section>
	<h2 data-aos="fade-up" data-aos-mirror="true">Distance des doigts aux touches</h2>
	<div class="content">
		<h3 data-aos="fade-right" data-aos-mirror="true">Optimisation de la rangée du milieu</h3>

		<p>
			Lors de l’apprentissage de la dactylographie, il est enseigné que les doigts doivent reposer
			sur la rangée du milieu (<kbd>QSDF</kbd>
			et <kbd>JKLM</kbd> en AZERTY). En particulier, il y a souvent une petite bosse sur les touches
			de repos pour les index, qui sont donc <kbd>F</kbd> et <kbd>J</kbd> en AZERTY.
		</p>
		<p class="text-gray">
			➜ L’idée est de taper sur une touche, puis de tout de suite replacer le doigt sur la rangée du
			mileu. Cela permet de toujours être capable de bouger rapidement dans n’importe quelle
			direction, un peu comme un sportif se replace toujours au milieu du terrain au cours d’un
			match.
		</p>
		<p>
			Il est alors logique de se dire que nos doigts étant la plupart du temps sur la rangée du
			milieu, autant y placer les lettres les plus fréquemment utilisées. En procédant ainsi, il n’y
			a presque plus besoin de bouger les doigts, juste à presser les lettres de la rangée de repos
			et parfois atteindre la rangée supérieure ou inférieure pour les lettres les moins fréquentes.
		</p>
		<bloc-clavier data-couleur="azerty">
			<bloc-ligne>
				<bloc-touche data-doigt="auriculaire" data-main="gauche" style="--taille: 1;"
					><div>Q</div></bloc-touche
				>
				<bloc-touche data-doigt="annulaire" data-main="gauche" style="--taille: 1;"
					><div>S</div></bloc-touche
				>
				<bloc-touche data-doigt="majeur" data-main="gauche" style="--taille: 1;"
					><div>D</div></bloc-touche
				>
				<bloc-touche data-doigt="index" data-main="gauche" style="--taille: 1;"
					><div>F</div></bloc-touche
				>
				<div style="display: inline-block; width: 50px;" />
				<bloc-touche data-doigt="index" data-main="droite" style="--taille: 1;"
					><div>J</div></bloc-touche
				>
				<bloc-touche data-doigt="majeur" data-main="droite" style="--taille: 1;"
					><div>K</div></bloc-touche
				>
				<bloc-touche data-doigt="annulaire" data-main="droite" style="--taille: 1;"
					><div>L</div></bloc-touche
				>
				<bloc-touche data-doigt="auriculaire" data-main="droite" style="--taille: 1;"
					><div>M</div></bloc-touche
				>
			</bloc-ligne>
			<legende-clavier>Rangée du milieu en AZERTY</legende-clavier>
		</bloc-clavier>

		<p>
			Pourtant, le QWERTY est pire qu’une disposition aléatoire sur ce point. <span
				class="text-gray"
				>La légende raconte que sa première rangée remonte à l’époque de l’invention de la machine à
				écrire. Le choix de la disposition QWERTY aurait, entre autres raisions, été influencé par
				un aspect purement marketing. En effet, à des fins de démonstrations, ont été placées sur la
				rangée supérieure de la machine à écrire toutes les lettres nécessaires pour pouvoire écrire <kbd-sortie
					>TYPEWRITER</kbd-sortie
				>.</span
			>
		</p>
		<p>
			Certaines des touches ayant les fréquences d’apparition les plus rares (en français et en
			anglais) sont sur ces excellents emplacements tel que le <kbd>Q</kbd>, le <kbd>F</kbd>, le
			<kbd>J</kbd>
			et le
			<kbd>K</kbd>. Pire, la quasi-totalité des touches les plus utilisées se retrouvent en fait sur
			la rangée du dessus (<kbd>AZERTYUIOP</kbd>). C’est notamment le cas de toutes les voyelles,
			qui sont pourtant d’un nombre limité comparé au nombre de consonnes et qui pourtant sont
			nécessaires à l’écriture de chaque mot.
		</p>

		<bloc-clavier data-couleur="hypertexte">
			<bloc-ligne>
				<bloc-touche data-doigt="auriculaire" data-main="gauche" style="--taille: 1;"
					><div>A</div></bloc-touche
				>
				<bloc-touche data-doigt="annulaire" data-main="gauche" style="--taille: 1;"
					><div>I</div></bloc-touche
				>
				<bloc-touche data-doigt="majeur" data-main="gauche" style="--taille: 1;"
					><div>E</div></bloc-touche
				>
				<bloc-touche data-doigt="index" data-main="gauche" style="--taille: 1;"
					><div>U</div></bloc-touche
				>
				<div style="display: inline-block; width: 50px;" />
				<bloc-touche data-doigt="index" data-main="droite" style="--taille: 1;"
					><div>S</div></bloc-touche
				>
				<bloc-touche data-doigt="majeur" data-main="droite" style="--taille: 1;"
					><div>N</div></bloc-touche
				>
				<bloc-touche data-doigt="annulaire" data-main="droite" style="--taille: 1;"
					><div>T</div></bloc-touche
				>
				<bloc-touche data-doigt="auriculaire" data-main="droite" style="--taille: 1;"
					><div>R</div></bloc-touche
				>
			</bloc-ligne>
			<legende-clavier>Rangée du milieu en HyperTexte</legende-clavier>
		</bloc-clavier>

		<p>
			En français et en anglais, le <kbd>E</kbd>
			est de loin la lettre la plus fréquente. Viennent ensuite les voyelles <kbd>A</kbd>,
			<kbd>I</kbd>, <kbd>O</kbd> et <kbd>U</kbd>, ainsi que les consonnes
			<kbd>S</kbd>, <kbd>N</kbd>, <kbd>T</kbd> et <kbd>R</kbd>. <Nom /> place évidemment les lettres
			les plus utilisées sur la rangée du milieu. En résulte immédiatement un déplacement des doigts
			largement diminué et un meilleur confort.
		</p>
		<h3 data-aos="fade-right" data-aos-mirror="true">Optimisation selon la force des doigts</h3>
		<p>
			Une fois que les lettres les plus fréquentes ont été placées sur la rangée du milieu, il reste
			encore beaucoup à faire. En effet, <strong>chaque doigt a une force différente</strong>.
			<span class="text-gray"
				>Ainsi, un pouce a plus de force qu’un index, qui a plus de force qu’un majeur, qui a plus
				de force qu’un annulaire, qui a plus de force qu’un auriculaire. Vous pouvez facilement vous
				en rendre compte en pressant fort de l’index sur une table, puis en essayent de faire de
				même avec votre auriculaire.</span
			>
		</p>
		<p>
			Par conséquent, ce constat de la force des doigts pris en compte, les meilleurs emplacements
			sont ceux sur la rangée de repos, en partant de l’index pour aller vers l’annulaire. Puis, les
			meilleurs emplacements seront sur les touches au-dessus et en-dessous de la rangée de repos,
			en partant là encore de l’index pour aller vers l’annulaire.
		</p>
		<p>METTRE ICI UN CLAVIER VIDE MONTRANT LES MEILLEURS EMPLACEMENT EN COULEUR</p>
		<p>
			La rangée des chiffres est donc encore moins accessible, car il faut traverser deux rangées
			depuis la rangée de repos pour l’atteindre. C’est pour cette raison que laisser le <kbd>É</kbd
			>
			sur cette ligne comme en AZERTY est une très mauvaise idée, car cette lettre est beaucoup utilisée
			en français. Par exemple, en français, le <kbd>É</kbd> est 5 fois plus fréquent que le
			<kbd>J</kbd>, dont la touche est pourtant en AZERTY sur l’un des meilleurs emplacements du
			clavier : la touche de repos de l’index.
		</p>
		<p>
			Enfin, contrairement au BÉPO ou à l’Optimot, <Nom /> ne place pas de symboles de programmation
			ou de ponctuation sur la rangée des chiffres. Ces symboles sont ramenés au plus près des doigts
			grâce à l’utilisation de la couche <kbd>AltGr</kbd>.
		</p>

		<mini-espace />

		<BlocClavier clavier="frequences" />

		<p>
			Comme vous pouvez le constater sur le clavier ci-dessus, les lettres les plus fréquentes sont
			bien sur la rangée du milieu en <Nom />. Effectivement, la lettre la plus fréquente, le
			<kbd>E</kbd>, est en rouge. Viennent ensuite en orange les voyelles et consonnes les plus
			fréquentes. Enfin, les lettres en vert, voire bleu, sont les moins fréquentes de toutes.
		</p>
		<p>
			Attention toutefois, car ces fréquences vont varier selon le texte analysé et la langue de
			celui-ci. Vous trouverez plus de détails sur la page <a href="/benchmarks">Benchmarks</a>.
		</p>
	</div>
</section>

<section>
	<h2 data-aos="zoom-out" data-aos-mirror="true">Minimisation des SFBs</h2>
	<div class="content">
		<p>
			La disposition AZERTY est extrêmement mauvaise au vu de la distance nécessaire pour atteindre
			les touches les plus fréquentes. Toutefois, c’est loin d’être son seul défaut. L’un de ses
			autres problèmes majeurs est son grand nombre de <SFB />s.
		</p>
		<p>
			Qu’est-ce qu’un SFB ? C’est le fait de <strong
				>devoir taper deux touches d’affilée avec exactement le même doigt</strong
			>. Par exemple, c’est taper <kbd>CE</kbd> en AZERTY : il faut d’abord utiliser le majeur
			gauche pour descendre d’une rangée et atteindre le <kbd>C</kbd>, puis remonter de deux rangées
			pour atteindre le <kbd>E</kbd>. Avec <Nom />, le <kbd>C</kbd> est sur l’index droit sur la
			rangée du haut et le <kbd>E</kbd> est directement sur la rangée du milieu, sur le majeur gauche.
		</p>
		<p>
			Il est donc impossible de paralléliser sa frappe lors d’un <SFB />. Suivre un chemin linéaire
			est nécessaire : d’abord taper la première touche, puis bouger son doigt pour atteindre la
			deuxième, puis enfin frapper la deuxième touche, ceci avec le même doigt. Impossible de
			déplacer deux doigts en même temps pour ne plus avoir qu’à taper dans le bon ordre sur les
			touches atteintes. Le pire est quand ces <SFB />s constituent la majorité de vos frappes, ce
			qui se produit si vous utilisez une disposition non optimisée telle que AZERTY.
		</p>
		<p>
			Ainsi, une combinaison de deux touches, c’est-à-dire deux caractères qui se suivent, est
			appelée <em>bigramme</em> (ou <em>digramme</em>). Pour optimiser une disposition clavier, il
			faut s’assurer que les bigrammes les plus fréquents ne se fassent pas avec le même doigt : on
			parle de <strong>limiter les <em>Same Finger Bigrams</em></strong>.
		</p>
		<mini-espace />
		<p>
			Cette tâche est bien plus difficile qu’on le pense, car certaines lettres comme le <kbd>E</kbd
			>
			ou le <kbd>R</kbd> se combinent avec presque toutes les autres. Il faut alors choisir de les
			regrouper avec les lettres faisant les bigrammes les moins fréquents. Par conséquent, la
			supression totale des <SFB />s est impossible. Toutedois, il est quand même possible de les
			réduire drastiquement. C’est ce que fait <Nom />.
		</p>
	</div>
</section>
<section>
	<h2 data-aos="zoom-out" data-aos-mirror="true">Alternance des mains</h2>
	<div class="content">
		<p>
			L’alternance des mains est très importante pour garantir une bonne <strong
				>fluidité de frappe</strong
			>, et donc un meilleur confort. L’objectif est d’essayer d’avoir le plus d’alternance des
			mains possible lors de la frappe de texte : main droite, ensuite main gauche, puis main
			droite, main gauche, etc.
		</p>
		<p>
			Cette alternance des mains permet de <strong>ne pas surutiliser l’une des deux mains</strong> l’utilisant
			pour taper la majorité du texte. Cela se ferait en effet au détriment de l’autre main qui resterait
			au-dessus de sa partie du clavier, à attendre de pouvoir enfin entrer en jeu. Ainsi, avec une bonne
			alternance des mains, pendant qu’une main frappe une touche, l’autre peut se replacer sur la rangée
			du milieu et se préparer à frapper la suivante.
		</p>
		<p>
			Si la touche suivante est sur la même main que la touche précédente (sauf éventuellement avec
			un roulement, cf. le point suivant), la frappe sera moins confortable. Imaginez que vous
			deviez atteindre le <kbd>C</kbd>
			de l’AZERTY, puis le <kbd>T</kbd>, pour écrire <kbd>CT</kbd>, un bigramme très courant en
			français et anglais. Dans ce cas, vous devez d’abord légèrement abaisser votre main pour que
			le majeur atteigne la rangée du bas pour taper
			<kbd>C</kbd>. Puis, il faut que l’index atteigne quant à lui la rangée du haut pour taper
			<kbd>T</kbd>. En résulte un sentiment d’inconfort avec deux doigts proches mais qui doivent
			aller dans des directions différentes. Au contraire,
			<strong>en "parallélisant" les frappes sur les deux mains</strong>, le résultat se révèle bien
			plus satisfaisant.
		</p>
		<p>
			L’alternance des mains a une limite. Il est impossible d’alterner parfaitement à chaque
			frappe. C’est pourquoi, une fois une alternance maximale atteinte, il faut encore améliorer
			l’expérience de frappe dans le cas où deux touches de la même main doivent être frappées
			d’affilée. C’est là qu’interviennent les roulements, présentés en détail dans le point
			suivant.
		</p>
	</div>
</section>
<section>
	<h2 data-aos="zoom-out" data-aos-mirror="true">Optimisation des roulements</h2>
	<div class="content">
		<p>
			L’optimisation de l’alternance des mains fait que lors de l’utilisation d’une main pour
			frapper une touche, il y a de fortes probabilités que le frappe suivante se fasse avec l’autre
			main. Toutefois, cela n’arrive pas dans la totalité des cas, c’est pourquoi il convient de
			s’assurer que le plus possible de frappes intra-mains se fassent à l’aide de roulements.
		</p>
		<p>
			Pour moi, un "roulement" désigne un déplacement sur deux doigts consécutifs et jamais à plus
			d’une rangée d’écart. Il y peu d’informations sur le sujet en ligne ; un roulement a
			probablement une définition plus large que la mienne, mais alors dans ce cas le côté "qui
			roule" est selon moi perdu. À la limite si c’est de l’index à l’auriculaire, mais pas de
			l’index à l’annulaire par exemple.
		</p>
		<p>
			En conclusion, un roulement est pour moi le <kbd>PO</kbd> de l’AZERTY ou le <kbd>ST</kbd> du
			BÉPO (idéalement, car mouvement horizontal). Sinon, c’est éventuellement le <kbd>PL</kbd> de
			l’AZERTY ou le <kbd>LS</kbd> du BÉPO. Toutefois, ce n’est pas le <kbd>ST</kbd> de l’AZERTY ni
			le <kbd>GL</kbd> du BÉPO.
		</p>
		<p>
			La disposition <Nom /> a été construite avec pour contrainte principale de permettre de réaliser
			les bigrammes consonne-consonne et voyelle-voyelle les plus courants grâce à des roulements, de
			préférence sur des doigts consécutifs dans un mouvement horizontal.
		</p>

		<h3 data-aos="fade-right" data-aos-mirror="true">Très bons bigrammes voyelle-voyelle</h3>
		<ul>
			<li><kbd>AI</kbd></li>
			<li><kbd>IE</kbd></li>
			<li><kbd>EU</kbd></li>
			<li><kbd>OI</kbd></li>
			<li><kbd>OU</kbd></li>
		</ul>

		Avec même quelques trigrammes très confortables :
		<ul>
			<li><kbd>AIE</kbd> notamment pour écrire <span class="hyper text-bold">AIE</span>NT</li>
			(avec en plus NT qui est lui aussi un roulement, que demander de plus ?)
			<li><kbd>IEU</kbd></li>
			<li><kbd>YOU</kbd></li>
		</ul>

		<h3 data-aos="fade-right" data-aos-mirror="true">Très bons bigrammes consonne-consonne</h3>
		<ul>
			<li><kbd>SN</kbd></li>
			<li><kbd>NT</kbd></li>
			<li><kbd>TR</kbd></li>
			<li><kbd>RT</kbd></li>
			<li><kbd>RS</kbd></li>
			<li><kbd>NS</kbd></li>
			<li>
				<kbd>CH</kbd> ce bigramme est extraordinaire, une fois habitué il est difficile de s’en passer
			</li>
			<li><kbd>PL</kbd></li>
			<li>
				<kbd>LD</kbd> surtout fréquent en anglais (O<span class="hyper text-bold">LD</span>, COU<span
					class="hyper text-bold">LD</span
				>, SHOU<span class="hyper text-bold">LD</span>, WOU<span class="hyper text-bold">LD</span>,
				etc.)
			</li>
		</ul>
		<h3 data-aos="fade-right" data-aos-mirror="true">Autres bons bigrammes</h3>
		<ul>
			<li>
				<kbd>OW</kbd> très utilisé en anglais (ALL<span class="hyper text-bold">OW</span>
				, D<span class="hyper text-bold">OW</span>N, FOLL<span class="hyper text-bold">OW</span>, H<span
					class="hyper text-bold">OW</span
				>, KN<span class="hyper text-bold">OW</span>, N<span class="hyper text-bold">OW</span>,
				<span class="hyper text-bold">OW</span>N, SH<span class="hyper text-bold">OW</span>, etc.)
			</li>
			<li>
				<kbd>WO</kbd> très utilisé en anglais (T<span class="hyper text-bold">WO</span>,
				<span class="hyper text-bold">WO</span>MAN, <span class="hyper text-bold">WO</span>RD,
				<span class="hyper text-bold">WO</span>RK, <span class="hyper text-bold">WO</span>RLD,
				<span class="hyper text-bold">WO</span>RTH, <span class="hyper text-bold">WO</span>ULD,
				etc.)
			</li>
			<li>
				<kbd>="</kbd> utilisé en programmation pour assigner une chaîne de caractères à une variable
			</li>
			<li><kbd>+=</kbd> utilisé en programmation pour incrémenter</li>
		</ul>

		<petit-espace />
		<p>Vous pouvez visualiser les roulements présentés précédemment ci-desosus :</p>
		<BlocClavier clavier="roulements" />
		<div style="height: 20px" />
		<controles-roulements
			class="btn-group"
			style="width: 100%; margin: 0 auto; display: inline-block; text-align: center"
		>
			<select bind:value={texte} on:change={() => taperTexte('roulements', texte, 250, false)}>
				<option selected disabled hidden>Sélectionner le roulement</option>
				<option disabled>• Roulements voyelles •</option>
				{#each roulements_voyelles as value}<option {value}>{value.toUpperCase()}</option>{/each}
				<option disabled>• Roulements consonnes •</option>
				{#each roulements_consonnes as value}<option {value}>{value.toUpperCase()}</option>{/each}
			</select>
		</controles-roulements>
	</div>
</section>
<section>
	<h2 data-aos="zoom-out" data-aos-mirror="true">Placement logique des touches</h2>
	<div class="content">
		<p>
			Afin de <strong> faciliter la mémorisation</strong> ainsi que de
			<strong>réduire la charge cognitive</strong>, les touches de la disposition sont, le plus
			possible, <span style="text-decoration: underline;"> placées logiquement</span>. Ceci en
			particulier sur la couche <kbd>AltGr</kbd> :
		</p>

		<ul>
			<li>
				<kbd>AltGr</kbd> + <kbd>À</kbd> ➜ <kbd-sortie>`</kbd-sortie> car le
				<span class="hyper text-bold">`</span> est au-dessus du A
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>C</kbd> ➜ <kbd-sortie>ç</kbd-sortie>
				car la cédille est sous le <span class="hyper text-bold">C</span>
			</li>
			<li>
				<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>D</kbd> ➜
				<kbd-sortie>δ</kbd-sortie>
				car c’est la touche morte pour écrire les lettres grecques (α, β, γ, δ…), dont l'une des plus
				connues est <span class="hyper text-bold">δ</span>
			</li>
			<li>
				<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>E</kbd> ➜
				<kbd-sortie>ᵉ</kbd-sortie>
				car c’est la touche morte <span class="hyper text-bold">E</span>xposant
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>É</kbd> ➜ <kbd-sortie>/</kbd-sortie>
				car le <span class="hyper text-bold">/</span> est au-dessus du E
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>È</kbd> ➜ <kbd-sortie>\</kbd-sortie>
				car le <span class="hyper text-bold">\</span> est au-dessus du E
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>Ê</kbd> ➜ <kbd-sortie>^</kbd-sortie>
				car le <span class="hyper text-bold">^</span> est au-dessus du E
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>H</kbd> ➜ <kbd-sortie>#</kbd-sortie>
				car c’est la première lettre de <span class="hyper text-bold">H</span>ashtag
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>L</kbd> ➜ <kbd-sortie>=</kbd-sortie> car éga<span
					class="hyper text-bold">L</span
				>
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>M</kbd> ➜ <kbd-sortie>&</kbd-sortie> car le nom de ce symbole est a<span
					class="hyper text-bold">M</span
				>persand
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>P</kbd> ➜ <kbd-sortie>+</kbd-sortie>
				car c’est la première lettre de <span class="hyper text-bold">P</span>lus
			</li>
			<li>
				<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>R</kbd> ➜
				<kbd-sortie>ℝ</kbd-sortie>
				car c’est la touche morte pour écrire les ensembles mathématiques (ℕ, ℤ, ℚ, ℝ, ℂ), dont l'un
				des plus connus est <span class="hyper text-bold">R</span>
			</li>
			<li>
				<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>T</kbd> ➜
				<kbd-sortie style="font-weight: normal;">◌̈</kbd-sortie>
				car c’est la touche morte <span class="hyper text-bold">T</span>rémat
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>V</kbd> ➜ <kbd-sortie>|</kbd-sortie> car c’est la barre
				<span class="hyper text-bold">V</span>erticale
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>X</kbd> ➜ <kbd-sortie>*</kbd-sortie>
				car <span class="hyper text-bold">x</span> ressemble au fois
			</li>
		</ul>

		<mini-espace />

		<p>D’autres sont placées par paires l’une à côté de l’autre :</p>
		<ul>
			<li>
				<kbd>AltGr</kbd> + <kbd>A</kbd> ➜ <kbd-sortie>{'<'}</kbd-sortie> et <kbd>AltGr</kbd> +
				<kbd>I</kbd>
				➜ <kbd-sortie>{'>'}</kbd-sortie>
			</li>
			<li>
				<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>A</kbd> ➜ <kbd-sortie>⩽</kbd-sortie> et
				<kbd>Shift</kbd>
				+ <kbd>AltGr</kbd> +
				<kbd>I</kbd>
				➜ <kbd-sortie>⩾</kbd-sortie>
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>E</kbd> ➜ <kbd-sortie>{'{'}</kbd-sortie> et <kbd>AltGr</kbd> +
				<kbd>U</kbd>
				➜ <kbd-sortie>{'}'}</kbd-sortie>
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>S</kbd> ➜ <kbd-sortie>(</kbd-sortie> et <kbd>AltGr</kbd> +
				<kbd>N</kbd>
				➜ <kbd-sortie>)</kbd-sortie>
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>T</kbd> ➜ <kbd-sortie>[</kbd-sortie> et <kbd>AltGr</kbd> +
				<kbd>R</kbd>
				➜ <kbd-sortie>]</kbd-sortie>
			</li>
			<li>
				<kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-sortie>«</kbd-sortie> et <kbd>AltGr</kbd> +
				<kbd>F</kbd>
				➜ <kbd-sortie>»</kbd-sortie>
			</li>
			<li>
				<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-sortie>“</kbd-sortie> et
				<kbd>Shift</kbd>
				+ <kbd>AltGr</kbd> +
				<kbd>F</kbd>
				➜ <kbd-sortie>”</kbd-sortie>
			</li>
		</ul>

		<mini-espace />

		<p>
			Enfin, les raccourcis avec les nouvelles touches par rapport à l’AZERTY et <kbd>Ctrl</kbd> sont
			faciles à retenir :
		</p>
		<ul>
			<li>
				<kbd>Ctrl</kbd> + <kbd>É</kbd> ➜ <kbd-sortie>Ctrl</kbd-sortie> +
				<kbd-sortie>+</kbd-sortie> pour zoomer
			</li>
			<li>
				<kbd>Ctrl</kbd> + <kbd>È</kbd> ➜ <kbd-sortie>Ctrl</kbd-sortie> +
				<kbd-sortie>-</kbd-sortie> pour dézoomer
			</li>
		</ul>
		<mini-espace />
		<p>
			À noter que les touches sont aussi placées le plus possible par distance selon leur fréquence
			d’utilisation. Ainsi, les touches très utilisées comme les <kbd>()</kbd>,
			<kbd>{'{}'}</kbd>, etc. sont toutes sur la rangée du milieu et sur les doigts les plus forts.
		</p>
		<p class="encadre">
			<span class="text-bold">⚠ Attention</span> : Le <kbd>$</kbd> est l’un des seuls symboles à ne
			pas être sur un emplacement logique (le
			<kbd>D</kbd>
			de <span class="hyper text-bold">D</span>ollar). Ceci parce qu’il est plus intéressant de
			mettre le <kbd>"</kbd> sur cette lettre, afin d’avoir un excellent roulement <kbd>="</kbd>. Le
			<kbd>$</kbd>
			se trouve sur la touche <kbd>★</kbd>.
		</p>
		<h2 data-aos="zoom-out" data-aos-mirror="true">
			Ponctuations avec espace insécable automatique
		</h2>
		<p>
			Enfin, les ponctuations <kbd>;</kbd>, <kbd>:</kbd>, <kbd>?</kbd> et <kbd>!</kbd> ont une
			particularité. En effet, lors de l’utilisation de <kbd>Shift</kbd>, elles sont
			<strong>automatiquement envoyées avec une espace insécable</strong> qui les précède. Les espaces
			insécables ne sont pas disponibles en AZERTY, et c’est très dommage. Ce sont des espaces qui ont
			la particularité de toujours rester collés au texte qui les précède et les suit.
		</p>
		<p>
			Ainsi, vous n’aurez plus jamais de <kbd>?</kbd> qui se balade au début d’une ligne parce qu’il
			n’y avait plus de place sur la ligne précédente. Cela donne des documents avec un rendu bien
			plus professionnel. Attention cependant :
			<strong>ne les utilisez pas dans d’autres situations que l'écriture de texte</strong>. Par
			exemple, en programmation, une espace insécable peut causer des erreurs, sans forcément être
			visible (vous ne verrez qu’un simple espace, qui pourtant sera la cause du problème).
		</p>
		<p>
			En revanche, en utilisant <kbd>AltGr</kbd>, la ponctuation seule est renvoyée. Cette méthode
			permet d’écrire dans un français impeccable en
			<kbd>Shift</kbd>, tout en programment normalement avec la couche <kbd>AltGr</kbd>, qui
			contient d’ailleurs tout le reste des symboles nécessaires à l’écriture de code.
		</p>
		<div class="encadre">
			<p class="text-bold">Ainsi, il est facile de se rappeler où est quoi :</p>
			<ul class="margin0">
				<li>le français est en <kbd>Shift</kbd></li>
				<li class="margin0">la programmation est en <kbd>AltGr</kbd></li>
			</ul>
		</div>
	</div>
</section>
<section>
	<h2 data-aos="zoom-out" data-aos-mirror="true">Chiffres en accès direct</h2>
	<div class="content">
		<p>
			Les chiffres sont en accès direct sur les dispositions QWERTY ou encore DVORAK, mais pas en
			AZERTY. Chaque manière de faire a ses avantages, car en AZERTY les symboles sont alors
			directement accessibles et donc plus facilement réalisables. En revanche, il devient compliqué
			d’écrire un nombre en plein milieu d’une phrase, car cela nécessite de passer en <kbd
				>Shift</kbd
			> momentanément pour l’écrire.
		</p>
		<p>
			Le passage des chiffres en accès direct permet d’<strong
				>écrire très rapidement des nombres</strong
			>
			en milieu de phrase. La rangée des nombres n’est de toute façon pas très accessible, donc il vaut
			mieux placer les symboles qu’elle contenait sur la couche <kbd>AltGr</kbd>, plus proches des
			mains car sur les 3 rangées du milieu pour ne pas avoir à trop bouger les doigts. C’est
			exactement ce que fait <Nom />.
		</p>
	</div>
</section>
<section>
	<h2 data-aos="zoom-out" data-aos-mirror="true">Optimisation pour l’utilisation à une main</h2>

	<div class="content">
		<p>
			Lors de l’utilisation d’un ordinateur, la plupart du temps la souris est tenue de la main
			droite et la main gauche repose près de la partie gauche du clavier. Quand vient le moment de
			taper sur une touche ou de réaliser une combinaison de touches pour faire un raccourci, il est
			bien souvent nécessaire de bouger la main droite. Celle-ci doit se déplacer de la souris à la
			partie droite du clavier, taper dessus, puis retourner à la souris pour continuer la
			navigation.
		</p>
		<p>
			Par conséquent, il est également important de s’assurer que, grâce à sa disposition clavier,
			beaucoup d’actions courantes puissent se réaliser avec la seule main gauche afin de <strong
				>ne pas avoir à lâcher la souris</strong
			>. À noter que sur ce point AZERTY est très bon car <kbd>X</kbd>, <kbd>C</kbd>, <kbd>V</kbd>
			et de nombreuses autres lettres fréquemment utilisées pour faire des raccourcis en combinaison
			avec <kbd>Ctrl</kbd> sont du côté gauche.
		</p>
		<p>
			Avec <Nom />, le <kbd>=</kbd> a ainsi été dupliqué à gauche pour être mis en accès direct.
			Cela permet de faire facilement les raccourcis sur Excel comme <kbd>=</kbd> et
			<kbd>Alt</kbd>
			+
			<kbd>=</kbd>. En effet, normalement le <kbd>=</kbd> se situe en <kbd>AltGr</kbd> +
			<kbd>L</kbd>. En dehors de cela, des touches de raccourci ont aussi été implémentées :
		</p>

		<h3 data-aos="fade-right" data-aos-mirror="true">
			Touches de raccourci sur la version Ergodox
		</h3>
		<p>
			La version d’<Nom /> adaptée aux claviers de type Ergodox est complètement optimisée pour l’utilisation
			à une main, car des touches <kbd>Copier</kbd>, <kbd>Coller</kbd>, <kbd>Couper</kbd> et
			<kbd>Alt+Tab</kbd> ont été directement incluses à gauche du clavier. À noter que ces touches ne
			sont pas définies dans le pilote et que ce sont uniquement des idées d’implémentation. Les claviers
			de type Ergodox peuvent en effet être programmés pour ajouter et déplacer des touches.
		</p>

		<h3 data-aos="fade-right" data-aos-mirror="true">Touches de raccourci sur la version ISO</h3>
		<p>
			La version ISO (pour claviers standards) ne peut quant à elle malheureusement pas bénéficier
			de ces touches de raccourci, car les touches à sa gauche sont déjà occupées par les touches
			<kbd>Shift</kbd>, <kbd>"Capslock"</kbd> et <kbd>Tab</kbd> contrairement à l’Ergodox où l’on peut
			placer ces 3 touches sous les pouces.
		</p>
		<p>
			<NomPlus /> donne toutefois le moyen de contourner les limites de la version ISO grâce à un
			<strong>mécanisme de tap-hold</strong>. L’idée du tap-hold est qu’il est possible d’assigner
			deux actions à une même touche : une au tap (appui bref) et une au hold (maitenir pressé).
			Grâce au tap-hold, il est possible de faire pour que taper une touche envoie un raccourci,
			mais que si on la presse elle se comporte normalement. Cela permet d’intégrer des touches
			<kbd>Copier</kbd>, <kbd>Coller</kbd> et <kbd>Alt+Tab</kbd> respectivement sur
			<kbd>LShift</kbd>, <kbd>LCtrl</kbd> et <kbd>Alt</kbd>.
		</p>
		<p>
			Enfin, <NomPlus /> a aussi optimisé les raccourcis <kbd>Ctrl</kbd> + <kbd>Z</kbd> et
			<kbd>Ctrl</kbd>
			+ <kbd>S</kbd>. Ceux-ci sont dédoublés en <kbd>Ctrl</kbd> + <kbd>Ê</kbd> et <kbd>Ctrl</kbd>
			+ <kbd>★</kbd>
		</p>
	</div>
</section>
