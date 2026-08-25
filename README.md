# obj

A small personal archive for things I apparently decided were important.
Static, Lua-built, no JavaScript.

## The idea

`obj` is part archive, part diary, part evidence that I will turn anything
into a software project if given enough time.

Entries are plain Markdown files with a small frontmatter header.
A stdlib-only Lua script reads them, checks that I have not made the metadata
up incorrectly, and renders the site.
Nothing runs in the browser except the page.

## Directory layout

| Path                    | Purpose                                            |
|-------------------------|----------------------------------------------------|
| `posts/`                | Content entries (Markdown + frontmatter).          |
| `templates/`            | HTML templates used by the build.                  |
| `lua/`                  | Lua modules (catalog, markdown, templates, rss).   |
| `build.lua`             | The build script; reads `posts/`, writes `dist/`.  |
| `static/`               | Static assets copied to `dist/static/`.            |
| `dist/`                 | Build output (generated; do not edit by hand).     |
| `.github/workflows/`    | CI that builds and deploys to GitHub Pages.        |

## Entry frontmatter schema

Every entry begins with a `---` block containing `key: value` lines and a
closing `---`. Values are scalars, numbers, or comma-separated lists
(e.g. `tags: lua, software`). No multiline blocks. After the closing
`---`, the rest is the Markdown body.

Base fields required for every entry:

- `id` - unique string, format `JOSH-YYYY-NNNN`; do not reuse one.
- `title` - the accession title.
- `date` - `yyyy-mm-dd`.
- `type` - one of: `essay`, `field-note`, `specimen`, `incident`, `artifact`.
- `tags` - lowercase, comma-separated list.

Per-type required fields:

- `field-note`: `mood`, `location`.
- `specimen`: `rating` (number, 0-5), `location`.
- `incident`: `severity`, `status`.
- `artifact`: `language`, `status`, `classification`.
- `essay`: no extra required fields.

Optional per-type fields are also understood by the build (e.g.
`known_hazards`, `repo`, `subtitle`) but are not required.

## Build locally

```sh
lua5.4 build.lua     # or: luajit build.lua
```

Output lands in `dist/`. Open `dist/index.html` to view.

## Deploy

Push to `main` and GitHub Actions does the rest.
It installs Lua, runs the build, and publishes `dist/` to GitHub Pages.
If the site is empty, the pipeline is probably lying to you.

## License

Content and code: see repository license. Catalogue entries are personal;
quote at your own risk.
