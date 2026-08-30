// The constants the whole app agrees on.

export const SITE = {
	name: 'three.c3',
	// A project Pages site is served from a subdirectory, so every link in the
	// app is either a fragment or relative. This is here for the one thing that
	// needs an absolute origin: the meta tags in `index.html`.
	origin: 'https://tonis2.github.io/three.c3/',
	repo: 'https://github.com/tonis2/three.c3',
	owner: 'tonis2',
	project: 'three.c3',
};

// Three entries, and the shortness is the design. Download and Screenshots are
// sections of the home page rather than routes of their own — a visitor who came
// to look at pictures should not have to go and find the download — so the only
// links here are the two places that are genuinely somewhere else: a reference
// you search, and a sequence you read.
export const NAV = [
	{ href: '#/', label: 'Home', match: 'home' },
	{ href: '#/api', label: 'API', match: 'api' },
	{ href: '#/tutorials', label: 'Tutorials', match: 'tutorials' },
];
