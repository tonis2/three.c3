// One owner for the two things outside <body> that change with the route.
//
// A fragment change does not reload the document, so nothing updates the title
// or the description unless something here does — and a browser's history menu,
// a bookmark and a shared tab title all read them.

const description = document.querySelector('meta[name="description"]');

export function setHead(title, summary) {
	document.title = title;
	if (summary && description) description.setAttribute('content', summary);
}
