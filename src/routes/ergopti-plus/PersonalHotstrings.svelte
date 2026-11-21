<!-- src/routes/ergopti-plus/PersonalHotstrings.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Personal & Dynamic Hotstrings
DESCRIPTION:
The "your own shortcuts" story: TOML-backed personal hotstrings added in one
click from the menu, and @-prefixed dynamic hotstrings computed at fire time
(dates, personal info).

FEATURES & RATIONALE:
1. Sales Angle: the shipped catalog is the base; what converts users is
   adding THEIR signature/IBAN in 5 seconds without touching code.
==============================================================================
-->

<script>
	import DriverFrame from './DriverFrame.svelte';
	import { reveal } from './reveal.js';
	import { i18n, t } from './i18n.svelte.js';

	/** @type {{geo: Record<string, {width: number, height: number}>}} */
	let { geo } = $props();

	// Live personal info — seeded with the demo values shown in the embedded
	// window, then UPDATED IN REAL TIME as the visitor edits the real
	// personal-info window below. Every example on this screen derives from
	// these fields, which is exactly how the driver's dynamic hotstrings work.
	let info = $state({
		first_name: 'Adrien',
		last_name: 'Moyaux',
		email: 'adrien@exemple.fr',
		phone: '+33 6 12 34 56 78',
		address: '15 rue Lafayette, 75009 Paris',
		iban: 'FR76 1234 5678 9012 3456 789'
	});

	/**
	 * Receive live edits from the embedded personal-info window.
	 * @param {Record<string, string>} fields
	 */
	function onInfoChange(fields) {
		info = { ...info, ...fields };
	}

	const today = new Date();
	// The dates are written in the language the page is read in.
	let dateLocale = $derived(i18n.lang === 'en' ? 'en-GB' : 'fr-FR');
	let dateShort = $derived(today.toLocaleDateString(dateLocale));
	let dateLong = $derived(
		today.toLocaleDateString(dateLocale, {
			day: 'numeric',
			month: 'long',
			year: 'numeric'
		})
	);

	let personalExamples = $derived([
		{
			trig: 'np★',
			out: `${info.first_name} ${info.last_name}`.trim() || '…',
			desc: t('Nom complet')
		},
		{ trig: 'em★', out: info.email || '…', desc: t('E-mail') },
		{ trig: 'tel★', out: info.phone || '…', desc: t('Téléphone') },
		{
			trig: 'sig★',
			out: t('Cordialement, {name}', { name: info.first_name }).trim(),
			desc: t('Signature')
		},
		{ trig: 'ad★', out: info.address || '…', desc: t('Adresse') },
		{ trig: 'iban★', out: info.iban || '…', desc: 'IBAN' }
	]);

	let dynamicExamples = $derived([
		{ trig: 'dt★', out: dateShort, desc: t('Date du jour') },
		{ trig: 'date★', out: dateLong, desc: t('Date en lettres') },
		{ trig: '@ph', out: info.phone || '…', desc: t('Téléphone configuré') },
		{
			trig: '@np★',
			out: `${info.last_name} ⇥ ${info.first_name}`.trim(),
			desc: t('Remplissage de formulaire')
		}
	]);

	let steps = $derived([
		t('Sélectionnez un texte que vous tapez souvent.'),
		t('Ouvrez le menu → Hotstrings personnels.'),
		t('Choisissez un déclencheur (ex : sig★).'),
		t('C’est actif — sans redémarrer le driver.')
	]);
</script>

<section class="personal" id="ep-perso-hotstrings" style="--section-accent: #8e8e93;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">{t('Vos propres raccourcis')}</p>
			<h2>{@html t('Et ceux que <em>vous</em> tapez tous les jours.')}</h2>
			<p class="lead">
				{@html t(
					'Signature, IBAN, formules récurrentes : ajoutez vos hotstrings <strong>en un clic</strong> depuis le menu — stockés dans un simple fichier TOML, rechargés à la volée.'
				)}
			</p>
		</header>

		<div class="personal-grid">
			<article class="ep-card" use:reveal>
				<h3>{t('Ajout en 5 secondes')}</h3>
				<ol class="steps">
					{#each steps as s, i}
						<li><span class="step-num">{i + 1}</span>{s}</li>
					{/each}
				</ol>
				<ul class="rows">
					{#each personalExamples as p}
						<li>
							<span class="hs-key">{p.trig}</span>
							<span class="hs-arrow">→</span>
							<span class="hs-out">{p.out}</span>
							<span class="hs-desc">{p.desc}</span>
						</li>
					{/each}
				</ul>
			</article>

			<article class="ep-card" use:reveal={{ delay: 90 }}>
				<h3>{t('Hotstrings dynamiques')}</h3>
				<p class="card-lead">
					{@html t(
						'Certaines valeurs changent tous les jours (la date) ou ne doivent pas être écrites en dur (téléphone, IBAN). Le préfixe <code>@</code> les calcule <strong>au moment précis</strong> du déclenchement, depuis l’éditeur d’informations personnelles.'
					)}
				</p>
				<ul class="rows">
					{#each dynamicExamples as d}
						<li>
							<span class="hs-key">{d.trig}</span>
							<span class="hs-arrow">→</span>
							<span class="hs-out">{d.out}</span>
							<span class="hs-desc">{d.desc}</span>
						</li>
					{/each}
				</ul>
				<p class="card-foot">
					{t(
						'Nom, e-mail, téléphone, adresse, IBAN : tout est centralisé dans une seule fenêtre — les hotstrings dynamiques s’en servent automatiquement.'
					)}
				</p>
			</article>
		</div>

		<!-- The REAL personal-info window, live-wired to the examples above -->
		<figure class="info-embed">
			<figcaption>
				<p class="info-lead" use:reveal>
					{@html t(
						'La fenêtre en question — la vraie. <strong>Modifiez un champ ci-dessous</strong> : les exemples <code>np★</code>, <code>sig★</code>, <code>@np★</code>… au-dessus se réécrivent en direct, exactement comme le feront vos expansions.'
					)}
				</p>
			</figcaption>
			<DriverFrame
				id="personal_info_editor"
				width={geo.personal_info_editor?.width ?? 560}
				height={geo.personal_info_editor?.height ?? 680}
				displayHeight={480}
				oninfochange={onInfoChange}
			/>
		</figure>
	</div>
</section>

<style>
	.personal-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
	}

	.steps {
		display: flex;
		flex-direction: column;
		gap: 9px;
		list-style: none;
		margin: 0 0 18px;
	}

	.steps li {
		align-items: baseline;
		color: var(--ink-soft);
		display: flex;
		font-size: 0.92rem;
		gap: 10px;
	}

	.step-num {
		align-items: center;
		background: rgba(49, 190, 255, 0.12);
		border: 1px solid rgba(49, 190, 255, 0.3);
		border-radius: 50%;
		color: var(--accent-blue);
		display: inline-flex;
		flex-shrink: 0;
		font-size: 0.72rem;
		font-weight: 800;
		height: 22px;
		justify-content: center;
		position: relative;
		top: 2px;
		width: 22px;
	}

	.rows {
		display: flex;
		flex-direction: column;
		gap: 9px;
		list-style: none;
	}

	.rows li {
		align-items: baseline;
		display: flex;
		flex-wrap: wrap;
		gap: 6px 10px;
	}

	.rows .hs-desc {
		margin-left: auto;
	}

	.card-lead {
		margin-bottom: 16px;
	}

	.card-foot {
		border-top: 1px solid var(--border);
		color: var(--ink-faint);
		font-size: 0.85rem;
		margin-top: 16px;
		padding-top: 14px;
	}

	@media (max-width: 880px) {
		.personal-grid {
			grid-template-columns: 1fr;
		}
	}

	.info-embed {
		margin: clamp(24px, 3.5vw, 36px) 0 0;
	}

	.info-lead {
		color: var(--ink-soft);
		font-size: 0.92rem;
		margin: 0 0 16px;
		text-align: center;
	}
</style>
