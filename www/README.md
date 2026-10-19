# isolate website

A single [Blume](https://useblume.dev/docs/) build serves the landing page at
`/` and all documentation under `/docs/`.

- [`index.html`](index.html) is the landing page source. The small
  [`pages/index.astro`](pages/index.astro) route serves it unchanged in dev
  and production.
- [`../docs/`](../docs/), [`../README.md`](../README.md), and
  [`../CONTRIBUTING.md`](../CONTRIBUTING.md) remain the documentation sources.
- [`../icon.svg`](../icon.svg) is the shared brand icon source. The
  `public/icon.svg` symlink exposes it to the landing page and documentation
  as `/icon.svg`, including their favicons.

`scripts/sync-docs.js` copies Markdown into the gitignored
`content/` directory before each run, moving each page's `# Heading` into
frontmatter and pointing links to non-page repository files at GitHub. Opening
paragraphs stay in the body; their summaries supply SEO metadata without
rendering a duplicate introduction.

Requires Node.js 22.19 or newer and Python 3.11+ for built-site checks. Run
these commands from `www/`:

```shell
npm install
npm run dev       # landing at http://localhost:4321/, docs at /docs/
npm run build     # sync, then write the complete static website to dist/
npm run preview   # serve dist/
npm run preview:cloudflare # serve dist/ with Cloudflare's asset routing (build first)
npm test          # publication contracts in temporary fixtures
npm run check     # publication tests, strict links, type check, build, rendered links
```

`npm run dev` syncs once at startup; rerun `npm run sync` after editing
the source Markdown. A new page under `docs/` or `docs/design/` is synced automatically,
but it appears in the sidebar only after its route is added to
`navigation.sidebar` in [`blume.config.ts`](blume.config.ts).

Publish `www/dist/` as the hosting root. Its `index.html` is the landing
page, and `docs/index.html` is the documentation overview. Keep the generated
assets and discovery files alongside them; no second build or routing proxy is
needed. `basePath: "/docs"` mounts documentation routes; navigation config
and Markdown links remain relative to the documentation root.

[`wrangler.json`](wrangler.json) configures Cloudflare Workers Static Assets
with the name `iso`, slashless HTML URLs, and the generated 404 page. To
validate or publish from `www/`:

```shell
npm run deploy:dry-run # build and validate deployment without publishing
npm run deploy        # build and publish using your Cloudflare account
```

The command and configuration references are published as topic pages from
their canonical files in `docs/`. Topic boundaries and sidebar entries share
[`scripts/reference-pages.js`](scripts/reference-pages.js). Add a new section
there when extending either reference; sync fails if a section is unassigned.
Links to reference sections, including links between topics, are rewritten to
their published destinations.

Contributor docs and design records have separate navigation tabs. Design
records retain their status notes, rank below guides in search, and stay out of
the combined LLM exports; their landing page links to the individual records.

The six landing-page feature drawings use the Hairline `hairline-create` skill.
Their sources and unmodified engine live in `public/hairline/`, with the engine's
MIT notice and revision recorded in `../THIRD_PARTY_LICENSES.md`. The adapter
`features.js` mounts them over inline resting SVGs in `index.html`, so the artwork
also renders without JavaScript. Theme colours come from the landing page's CSS;
the engine handles pointer input, reduced motion and sleeping offscreen.

When changing a drawing, run Hairline's `look.mjs` against that figure's `.js`
file and inspect the resulting sheet and motion strip. Update its matching
`data-hairline` element in `index.html` with the resting SVG from the browser
(`svg.outerHTML`) so the fallback stays in sync. Keep the engine unchanged.
