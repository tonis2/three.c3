// Prism reads `window.Prism.manual` when its core module initialises, so this
// has to be evaluated before that module is. See `highlight.js`.

globalThis.Prism = { manual: true };
