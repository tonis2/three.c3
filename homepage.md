# three.c3 — the website

**A plan for one deliverable and nothing else.** The engine's task list is
`plan.md`; this file is the site that ships beside it, from an empty repository
folder to a page on `tonis2.github.io/three.c3`. An entry leaves this file when
it stops being work somebody has to do.

The site answers five questions and no others: what is this, where do I get it,
what can it do, what does the API say, and how do I write my first scene.

---

## 0. The finding this whole plan turns on

**The API reference is not written, it is generated.**
`src/js/prelude/docs.js` is already the single source of truth — 113 KB of
`DOCS`, plus `docsIndex`, `docsSearch`, `findSection` and `docsMarkdown` — and
it is deliberately import-free: its one live call is `H.keyNames()`. So a Node
script can `import` that module with a four-line stub for `globalThis.__three`
and emit the whole surface as JSON, with no C3 build, no GPU and no binary.

That is what makes the site cheap to keep honest. The page a human reads, the
answer `three.getApiDocs()` gives an agent and the `get_api_docs` MCP tool all
come out of the same object, so they cannot drift. A doc string edited in
`docs.js` is on the website the next time `main` moves, and nothing has to be
copied by hand — which is the failure every hand-written API page eventually
has.

The one value that does not travel with the module is the key table, because
`keyNames` is a host binding over `KEY_NAMES` in `src/scene/input.c3:384`. The
generator parses the names out of that table, so the key list on the page is
the list the engine actually matches against rather than a second copy of it.

## 1. Shape and hosting

- [ ] **Plain HTML, CSS and JavaScript. No runtime framework, no CDN.** Every
      page is static and loads with no dependency; `marked` and `highlight.js`
      are build-time devDependencies and nothing they produce is shipped as a
      library. The site should open from a file:// URL as readily as from
      Pages.
- [ ] **Built by a Node script, deployed by Actions.** Not Jekyll — the API
      generator has to run anyway, and once a build step exists, Jekyll is a
      second one that earns nothing. `actions/upload-pages-artifact` and
      `actions/deploy-pages`, so no `gh-pages` branch and no generated files in
      the tree.
- [ ] **The base path is `/three.c3/`, not `/`.** A project Pages site is
      served from a subdirectory, and an absolute `/assets/style.css` is the
      standard way this breaks — it works locally and 404s on the deploy. Every
      href and src is relative, and the build fails on an absolute one rather
      than trusting a review to catch it.

### The layout

    tutorials/          01-hello-scene.md, 02-creating-materials.md, ...
    site/
      build.mjs         markdown -> html, page templates, the whole build
      gen-api.mjs       imports src/js/prelude/docs.js under a __three stub
      pages/            index, download, api, tutorials, screenshots
      assets/           style.css, search.js, slider.js, download.js
      screenshots/      *.jpg and captions.json  (committed, see section 6)
    .github/workflows/pages.yml

`tutorials/` sits at the repository root rather than under `site/`, because a
tutorial is documentation of the engine and should be readable in the
repository, in the release zip and on GitHub without the website being
involved.

## 2. The generator

- [ ] **`site/gen-api.mjs` emits `api.json` from `docs.js`.** Stub
      `globalThis.__three = { keyNames: () => [...] }` before the import, take
      the exported `DOCS`, write it whole. The key names come from parsing the
      `KEY_NAMES` table in `src/scene/input.c3`; if that parse finds nothing,
      the build FAILS rather than shipping an empty key table — a silently
      missing section is worse than a red build.
- [ ] **Emit a flat entry list beside it**, keyed by the same paths
      `getApiDocs({ section })` accepts — `classes.ShaderMaterial`,
      `functions.three.load(path)`. One walk, the same two-deep rule
      `docsEntries()` uses: a top-level plain object is a SECTION and
      everything one level inside it is an entry. Getting that rule wrong is
      what glues fifty separate `differences` answers into one blob.
- [ ] **Run the generator in CI as its own check.** A `docs.js` edit that
      breaks the site should fail on the commit that made it, not on the next
      deploy.

## 3. Home

- [ ] **Say what it is in one sentence, above the fold.** `DOCS.summary`
      already is that sentence — a Three.js-shaped scene API over Vulkan where
      every mesh placed with the same asset reference is one instanced draw
      call. Generated, so it cannot go stale.
- [ ] **A code sample that is not written by hand.** `DOCS.example` is a
      complete scene ending in `stats()` with the draw-call count in a comment,
      which is the claim the whole engine rests on. Render that.
- [ ] **A feature grid, six cells.** Instanced by default with no batching step
      to invoke; one binary with the Slang compiler and the shader templates
      inside it; glTF with skinning, morph targets and crossfades; physics,
      navigation and spatial queries; a Slang `ShaderMaterial` with a vertex
      stage; an MCP server so an agent can drive it.
- [ ] **Three calls to action** — Download, Tutorials, API — and nothing else
      competing with them.

## 4. Download

- [ ] **Resolve the release at runtime, from the GitHub API.** The assets are
      version-suffixed (`three-macos-arm64-0.1.0.zip`), so the usual
      `/releases/latest/download/<name>` trick cannot work: the name is not
      knowable without the version. The page fetches
      `api.github.com/repos/tonis2/three.c3/releases/latest`, matches assets by
      their `three-<os>-<arch>` prefix and fills in the links.
- [ ] **Fall back to the releases page when that fetch fails.** Unauthenticated
      API calls are rate-limited per IP, and a download page that shows nothing
      is the worst page on the site. The static link is in the markup and the
      script replaces it, so it degrades rather than disappears.
- [ ] **Detect the visitor's platform and put that card first.** The other two
      stay visible — a person on a Mac downloading the Windows zip for someone
      else is an ordinary thing to do.
- [ ] **Carry the first-run lines from `packaging/bundle-README.md`**, macOS
      quarantine included. Somebody who downloads a non-notarised binary and
      hits a Gatekeeper dialog with no explanation on the page they came from
      does not come back.
- [ ] **Consider unversioned aliases instead.** If `release.yml` also uploaded
      `three-macos-arm64.zip` beside the versioned asset, this page would be
      three static links and no JavaScript at all. Worth doing if the fetch
      turns out to be a nuisance.

## 5. The API reference

- [ ] **A sidebar of the sections and a pane for one entry.** Sections are
      whatever `DOCS` has: `differences`, `classes`, `functions`, `stats`,
      `intersection`, `keys`. `differences` and `stats` are the two read on
      nearly every task — `docsIndex()` already knows this, and the page should
      open on `differences` rather than on an empty state.
- [ ] **Render both entry shapes.** An entry is either a string, an array, or
      the class record `{ construct, note, properties, methods, details }`.
      Three renderers, and `details` hangs under the property or method it
      explains rather than as a fourth list.
- [ ] **Search, client-side, over the whole JSON.** The same rule
      `docsSearch()` uses: a hit is any entry whose PATH or PROSE contains the
      term, case-insensitively. No index library — 113 KB gzips to about 30 KB
      and a substring scan over it is instant. No `SEARCH_BUDGET` here: that
      cap exists because an agent pays tokens for an answer, and a human
      scrolling does not.
- [ ] **The URL fragment is the path `getApiDocs` takes.**
      `#/classes/ShaderMaterial` on the page, `{ section:
      "classes.ShaderMaterial" }` in the tool. One vocabulary for the person
      and the agent, and a link somebody pastes into a chat is a link the agent
      can act on.
- [ ] **Deep links must survive a reload**, which means reading the fragment on
      load and not only on click.

## 6. Screenshots

- [ ] **The images are committed. They cannot be generated in CI.** Not an
      oversight — `release.yml` says it at length: no runner in the matrix has
      a GPU that will draw this, the Linux one would be on lavapipe and the
      macOS one answers `VK_ERROR_INITIALIZATION_FAILED`. A picture of the
      renderer has to come off a machine with a graphics card, so it is a file
      in the repository.
- [ ] **Capture them from `examples/`**, which is five finished scenes already:

          ./three --script examples/village.js --headless \
                  --screenshot site/screenshots/village.jpg \
                  --width 1600 --height 900 --frames 120

      `--frames` matters: a scene screenshotted on frame 0 is a scene before
      its first animation tick.
- [ ] **A slider with no library.** CSS scroll-snap, arrow buttons, arrow keys,
      lazy-loaded images. `captions.json` holds one line per shot and the
      example it came from, and each caption links to that file on GitHub — so
      the gallery doubles as the examples page and there is no second list to
      keep in step.

## 7. Tutorials

- [ ] **One markdown file per tutorial, with frontmatter** — `title`, `order`,
      `summary`. Numbered filenames so the folder reads in order:
      `01-hello-scene.md`, `02-creating-materials.md`.
- [ ] **Rendered at BUILD time, not fetched at run time.** A tutorial fetched
      by JavaScript is invisible to search engines, blank with JS off and
      slower for everyone. The build turns each file into a page.
- [ ] **Write the fenced JavaScript out as a runnable file too.** A tutorial's
      code block becomes `tutorials/01-hello-scene.js`, so the page can say
      `./three --script tutorials/01-hello-scene.js` and mean it exactly. A
      snippet that has never been run is a snippet that does not run.
- [ ] **Sidebar, prev/next, and a copy button on every block.**
- [ ] **The first five.** Their material is in `SKILL.md` and the `examples/`,
      and none of it has to be invented:
      hello scene; creating materials; loading a glTF kit; animation and
      skinning; input and systems.

## 8. Deploy

- [ ] **`.github/workflows/pages.yml`** on push to `main` touching `site/`,
      `tutorials/` or `src/js/prelude/docs.js`, plus `workflow_dispatch`.
      `npm ci`, `node site/build.mjs`, upload, deploy.
- [ ] **Enable Pages with the Actions source** in the repository settings once,
      by hand. Nothing in the workflow can do it and a first deploy against the
      branch source silently serves the wrong thing.
- [ ] **Link the site from `README.md` and from the release body.**

## 9. Polish, last

- [ ] Dark and light, from `prefers-color-scheme`. One stylesheet.
- [ ] Open Graph tags and one card image, so a pasted link shows the renderer.
- [ ] A 404 that offers the four pages.
- [ ] Favicon.

## Milestones

1. Scaffold and pipeline — an empty page deployed and reachable. Everything
   after this is content against a thing that already works.
2. Home and Download.
3. The API reference and its search.
4. The tutorial pipeline and the first five.
5. Screenshots, then section 9.
