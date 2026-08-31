# The three.c3 scripting API

A Three.js-shaped scene API over direct Vulkan.

- [differences](differences.md) — Where this is not Three.js. Read this section first — nearly every script that fails does so against one of these.
- [classes](classes.md) — The constructors, their properties and their methods.
- [functions](functions.md) — Everything on `three` itself, keyed by its whole call.
- [stats](stats.md) — What each number from `scene.stats()` counts.
- [intersection](intersection.md) — The record a raycast or a pick answers with.
- keys — The names `three.input` and `three.onKey` match against. This list is read out of the engine's own key table, so it is the list that actually matches.
- [example](examples.md#example) — A complete scene, with the draw-call count it ends on.
- [exampleFromFile](examples.md#example-from-a-file) — The same, from a glTF file.

## How these files are used

This folder is the one source of the API documentation. The [website](../site/) reads it directly.
The engine cannot — it embeds JavaScript, not Markdown — so `tools/docs.mjs` compiles the folder into
`src/js/prelude/docs.data.js`, and that is what `three.getApiDocs()`, `three.searchDocs()` and the
`get_api_docs` MCP tool answer out of.

That compiled module is **committed**, and no build step rewrites it. Edit the Markdown, run the
compiler, commit both:

```sh
node tools/docs.mjs           # rewrite docs.data.js if anything changed
node tools/docs.mjs --check   # what CI runs: fails if the committed module is stale
node tools/docs.mjs --print   # the compiled object, as JSON
```

The compiler is strict. A file it cannot read the way this page describes stops the build with the
file and the line, because an entry that quietly compiled to nothing would be worse.

## The layout

The paragraph at the top of this file is the `summary`, and the list under it is the order the
sections come in — `differences` first, because it is the section that stops scripts failing. The
text after each ` — ` is the section's blurb.

`keys` is the one section not written here: the key table is read out of the engine, so the names an
agent sees are the names the host matches.

| File | Becomes |
| --- | --- |
| `README.md` | `summary`, and the section order |
| `differences.md` | `differences`: one entry per `## heading` |
| `classes.md` | `classes`: one class per `## Name` |
| `functions.md` | `functions`: one entry per `## heading` |
| `stats.md`, `intersection.md` | one entry per `- ` list item |
| `examples.md` | `example` and `exampleFromFile`: a fenced code block each, as code |

The link says where a section is written, so a file need not be named after its section and need not
hold only one: two links to the same file with a different `#heading` each — the way `examples.md`
carries both examples — are two sections out of one file, split at those headings. A file nobody
links to is still a section, named after itself, with no blurb. Anything under `docs/` that is not
`.md` is ignored.

## Writing an entry

A section file holds entries and nothing else.

A `# heading` — at the top, or anywhere — is a title or a divider for the reader and compiles to
nothing, which is how `functions.md` groups its entries by area. It is also what a `#heading` link
splits a shared file at, so the two readings never disagree. A paragraph about the section itself
belongs in the list above, not in the file.

```markdown
# Spatial queries

## three.query.sphere(centre, radius, into)

Every drawable node whose bounding box reaches within radius of a point. ...

## three.query.box(box, into)

The same, for a Box3, a { min, max } or a flat [minX, minY, minZ, maxX, maxY, maxZ].
```

The heading is the entry's key, exactly as written — it is what
`{ section: "functions.three.query.box(box, into)" }` asks for and what the website links to, so
renaming one moves it. Entries come out in the order they are written.

Short entries can be a list instead, one per item, which is how `stats.md` is written:

```markdown
- `drawCalls` — vkCmdDrawIndexed calls for one frame of this scene.
- `instances` — Total placed meshes.
```

The prose is Markdown and stays Markdown all the way to the reader: paragraphs, `code` spans,
**bold**, fenced blocks and `- ` lists inside an entry all come through. Wrap lines wherever you
like; a paragraph is joined back into one line. Tables and numbered lists are not in the subset — a
line that is neither a heading, a fence nor a `- ` item is a paragraph, so a table would arrive as
one run-on line. An identifier with `*`, `_` or `<` in it wants backticks, or Markdown will read it
as emphasis or a tag. `<!-- comments -->` are dropped.

Aim entries at a person reading the website: open with one sentence saying what the thing is, put the
options and the gotchas in a `- ` list rather than in a run-on paragraph, and show a two-line example
where it replaces a paragraph of prose.

## Writing a class

`classes.md` holds one class per `## Name`: how it is constructed, what it is, then up to three parts
at `###`, in this order — `Properties`, `Methods`, `Details`.

````markdown
## Scene

```js
new three.Scene()
```

An independent world, made and immediately shown. ...

### Properties

- `position`
- `isActive` — whether this is the one being rendered — only one is

### Methods

- `add(...objects)`
- `play(name, { loop, speed, time, fade })`

### Details

#### isActive

Whether this is the Scene being rendered. Exactly one is. ...
````

A member is a name or a signature in backticks, with an optional ` — one line` after it. Keep that
line short: anything longer is a `Details` entry, because a member list a reader scans should stay
scannable, and a paragraph inside the backticks compiles as the member's *name*.

`Details` is for the members whose one line was not enough: a `#### member` heading naming something
in either list, then paragraphs. A detail that names a member not in the lists is an error, because
it is almost always a typo.
