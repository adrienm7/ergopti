export function makeIds(content) {
	// eslint-disable-line
	var headings = content.querySelectorAll('h1, h2, h3, h4, h5, h6, h7');
	var headingMap = {};

	Array.prototype.forEach.call(headings, function (heading) {
		var id = heading.id
			? heading.id
			: heading.innerText
					.trim()
					.toLowerCase()
					.replace(/\s+/g, '-')
					.replace(/[êéè]/g, 'e')
					.replace(/[à]/g, 'a')
					.replace(/[ù]/g, 'u')
					.replace(/[^a-z0-9-]/g, '') /* Enlever les caractères spéciaux */
					.replace(/-{2,}/g, '-') /* Enlever les - en double, voire triple */
					.replace(/^-+/, '') /* Enlever les - au début de l’id */
					.replace(/-+$/, ''); /* Enlever les - à la fin de l’id */
		headingMap[id] = !isNaN(headingMap[id]) ? ++headingMap[id] : 0;
		if (headingMap[id]) {
			heading.id = id + '-' + headingMap[id];
		} else {
			heading.id = id;
		}
	});
}
