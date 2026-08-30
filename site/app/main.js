// The whole site, in one bundle.
//
// esbuild rolls this up into `assets/bundle.js`: Lit, the router, the views and
// the two live widgets, as one ES module. No import map, no CDN and no module
// graph over the network — and it runs from a `file://` URL as readily as from
// Pages, which is what a path-based router could not do.

import './app.js';
import './copy.js';
import '../elements/download.js';
import '../elements/gallery.js';
