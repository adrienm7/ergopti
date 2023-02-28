export function typography(searchNode = document.body) {
	const excludedTags = [
		'html',
		'head',
		'style',
		'title',
		'link',
		'meta',
		'script',
		'object',
		'iframe',
		'pre',
		'kbd',
		'code',
		'textarea',
		'noscript'
	];
	const nodes = searchNode instanceof NodeList ? searchNode : searchNode.childNodes;

	nodes.forEach((node) => {
		if (node.nodeType === 1 && !excludedTags.includes(node.tagName.toLowerCase())) {
			typography(node);
		} else if (node.nodeType === 3 && node.nodeValue.trim() !== '') {
			const spaceRegex = /(\u00AB|\u2014)(?:\s+)?|(?:\s+)?([\?!:;\u00BB])/g;
			const apostropheRegex = /'/g;
			const space = '<span class="insecable" style="font-size: 0.67em">&nbsp;</span>';
			const newText = node.nodeValue
				.replace(apostropheRegex, '’')
				.replace(spaceRegex, `$1${space}$2`);
			const newElement = document.createElement('span');
			newElement.innerHTML = newText;
			node.parentNode.replaceChild(newElement, node);
		}
	});
}
