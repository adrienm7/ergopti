<!--
  The term « SFB » with its definition. The definition showed on hover only,
  hidden from the keyboard and from screen readers (visibility: hidden): the
  term is now a button that describes itself by the definition
  (aria-describedby), the definition shows on hover and on focus, and Escape
  hides it without moving the focus (WCAG 1.4.13, 2.1.1).
-->
<script>
	const id = $props.id();
	let dismissed = $state(false);

	/** Escape hides the shown definition; the next focus or hover shows it again. */
	function onKeydown(event) {
		if (event.key === 'Escape') dismissed = true;
	}
</script>

<span class="nowrap texte-sfb">
	<span class="tooltip" class:dismissed>
		<button
			type="button"
			class="sfb-term"
			aria-describedby={id}
			onkeydown={onKeydown}
			onmouseenter={() => (dismissed = false)}
			onblur={() => (dismissed = false)}>SFB</button
		>
		<span class="tooltiptext" role="tooltip" {id}>
			« <span lang="en">Same Finger Bigram</span> », c’est-à-dire nécessiter le même doigt pour
			taper deux lettres qui se suivent. Par exemple, en AZERTY un SFB serait <kbd>UN</kbd> qui implique
			d’utiliser l’index droit pour appuyer successivement sur ces deux touches. Et pourtant, cette combinaison
			est si fréquente en français…
		</span>
	</span>
</span>

<style>
	.texte-sfb {
		display: inline;
		width: fit-content;
	}

	.tooltip {
		border-bottom: 2px dotted white;
		display: inline-block;
		white-space: normal;
	}

	/* The term keeps the look of the text around it: only the focus ring of
	   the site (accessibility.css) shows that it is a control. */
	.sfb-term {
		background: none;
		border: 0;
		color: inherit;
		cursor: help;
		display: inline;
		font: inherit;
		letter-spacing: inherit;
		line-height: inherit;
		margin: 0;
		padding: 0;
		text-align: inherit;
		text-transform: inherit;
		word-spacing: inherit;
	}

	.tooltip .tooltiptext {
		/* Enlève les dégradés de texte */
		background-clip: unset;
		background-color: rgba(0, 13, 27, 0.95);
		border: 1px solid rgba(255, 255, 255, 0.2);
		border-radius: 8px;
		box-shadow: rgba(0, 0, 0, 0.35) 0px 5px 15px;
		color: white;
		display: inline-block;
		font-size: 1rem;
		font-weight: normal;
		line-height: 1.35;
		max-width: 600px;
		padding: 20px;
		position: relative;
		visibility: hidden;
		width: 90%;
		z-index: 2;
		-webkit-text-fill-color: white;
		/* Position the tooltip: under the term's line (the margin moves it from
		   its static place), so it never covers the focused term (WCAG 2.4.11). */
		margin-top: 1.5em;
		position: absolute;
		right: 50%;
		transform: translate(50%, 0);
	}

	.tooltip:hover .tooltiptext,
	.tooltip:focus-within .tooltiptext {
		visibility: visible;
	}

	.tooltip.dismissed .tooltiptext {
		visibility: hidden;
	}
</style>
