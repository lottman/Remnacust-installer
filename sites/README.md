# Bundled node websites

These are twenty independent static reference sites. Each directory is the editable
source of one complete website: three thematic pages, a linked About page, a
branded 404 page, local styles, a local script and original SVG illustrations. They do not accept orders, bookings,
accounts or uploads, and do not represent operating businesses. Minecraft content
is an independent Java Edition planning guide, not an official hosting service.

## Editing

Edit HTML text and the theme's `assets/site.css` directly. `assets/base.css` is
copied into each site so that the selected site is self-contained. Edit only that
copy when changing one site's basic controls. No framework, npm packages, remote
fonts or build-time network requests are needed.

`site.json` contains the stable ASCII `id`, Russian installer `title` and Russian
`description`. It is catalogue metadata and is not installed as a public asset.
Keep a site's ID unchanged when editing its content. The only replacement token
is `{{DOMAIN}}`, in HTML text; the installer escapes the chosen domain before
rendering. Do not put that token in an attribute, CSS, JavaScript or SVG.

Every bundled page has its own Content-Security-Policy meta tag, before styles and
scripts. Scripts and styles are separate local files. The policy does not modify
or constrain an existing owner-managed website. If deliberately extending a
bundled page, review its CSP explicitly; the catalogue builder enforces the
bundled policy, local resources and absence of inline handlers/styles/scripts.

The illustrative catalogues contain generic products or original study prompts,
not live inventory. Cost and capacity tools label their assumptions. Replace
content honestly if using a theme for an actual project. All illustrations were
created for this catalogue; there are no third-party image or font assets.

## Rebuilding

From the repository root, using Python 3.10 or newer:

```sh
python3 scripts/build-node-sites.py
python3 scripts/build-node-sites.py --check
python3 tests/node-sites-catalog.test.py
```

The builder creates `installer/node-sites.json` as deterministic compact UTF-8
with a trailing newline. It also creates `installer/node_site_catalog.py`, a
data-only transport for helper cohorts compatible with older installer entries.
`--check` verifies both artifacts. JSON remains the canonical catalogue format:

```json
{"schema":1,"sites":[{"id":"shoes","title":"Обувь и повседневный стиль","description":"…","files":{"index.html":"…","assets/site.js":"…"}}]}
```

The helper bytes are exactly `CATALOG_JSON = ` followed by Python `repr()` of the
UTF-8-decoded JSON string, then one LF, encoded as UTF-8. It contains one string
assignment and no imports or executable logic. The runtime reads the file as data
and decodes the literal after the exact prefix; it must not import or execute it.
Both generated files are separately limited to 2 MiB, including representation
overhead. Custom `--output` writes the helper beside the JSON by default;
`--helper-output` can choose a separate destination. Helper bundle manifests are
managed separately from this content builder.

Sites and file paths are sorted. Paths are relative POSIX names. Only HTML, CSS,
JS and SVG are bundled. Each site must have three thematic pages plus `about.html`
and `404.html`. About is linked from every footer. The 404 page uses root-relative
local resource and navigation URLs so it also works for missing nested paths when
the site is served at the domain root. It is not added to the ordinary navigation.
Symlinks, external resources, active SVG, unsafe DOM sinks and unknown replacement
tokens are rejected. The complete encoded catalogue is limited to 2 MiB.

Preview any directory using an ordinary local static file server. There is no
SPA fallback or backend requirement. Test at 320, 390 and 1280 pixels; tab through
links and controls and test with reduced motion enabled. Form tools use standard
HTML validation before their submit handler runs. Saved choices are scoped by
site ID in browser localStorage, and storage failures do not send data elsewhere.
Tools still calculate when localStorage is unavailable. Downloads are generated
locally using Blob URLs and never uploaded.

## Pages and functional checks

All sites have `index.html`, `about.html` and `404.html`. Calculator forms use `#tool`, their submit button,
and a text-only `#result` output. Search uses `#search`, category filters use
`#category`, and the no-results state is `#empty`.

| ID | Other pages | Primary check |
|---|---|---|
| shoes | `catalog.html`, `fit.html` | Save a shoe; filter walking shoes. `#length=26`, `#room=1` gives 27.0 cm inner length and approximate EU 41. |
| minecraft | `handbook.html`, `planner.html` | `#players=8`, `#world=vanilla`, `#worldsize=4`, `#copies=7` gives 4 GiB RAM and 34 GiB backup allowance. `#properties` downloads authenticated, allowlisted server settings. |
| ceramics | `forms.html`, `studio.html` | `#width=12`, `#height=9`, `#shrink=12` gives 13.6 × 10.2 cm wet dimensions. |
| coffee | `recipes.html`, `brew.html` | `#dose=20`, `#ratio=16`, `#cups=2` gives 320 g water and 160 g water per cup. |
| bakery | `bread.html`, `dough.html` | `#flour=500`, `#hydration=68`, `#salt=2`, `#yeast=0.7` gives 340 g water, 10 g salt and 3.5 g yeast. |
| bicycles | `workshop.html`, `fit.html` | Check and restore the ride checklist. `#inseam=80`, `#style=0.67` gives a 54 cm traditional seat-tube estimate. |
| plants | `plants.html`, `care.html` | Filter by light, save plants, check tasks, reload, and use `#reset-care`. |
| architecture | `studies.html`, `room.html` | `#length=4.5`, `#width=3.6`, `#scale=20` gives 16.20 m² and a 22.5 × 18.0 cm drawing. |
| outdoors | `routes.html`, `pack.html` | Filter terrain; check tasks and use `#pack-download` for a file preserving checked states. |
| artgallery | `collection.html`, `looking.html` | Save studies; select `#work`, enter `#note`, submit, reload and use `#note-download`. |
| bookshop | `shelves.html`, `reading.html` | Save reading prompts. `#pages=240`, `#words=250`, `#pace=220`, `#minutes=25` gives 273 minutes and 11 reading days. |
| musicstudio | `sessions.html`, `beat.html` | Edit `#step-0`…`#step-7`, set `#tempo`, submit to start/stop quiet generated audio. Hiding the tab stops playback. No autoplay. |
| furniture | `pieces.html`, `planner.html` | `#modules=3`, `#wall=300`, `#cover=70` gives 260 cm width, 40 cm remaining and an illustrative €1170 estimate. |
| petcare | `routines.html`, `pantry.html` | `#food=5`, `#daily=180`, `#pets=1` gives 27 full days. This is inventory arithmetic, not a feeding recommendation. |
| travelguide | `districts.html`, `day.html` | Default three stops (30 minutes each plus 15-minute walks) start at 09:00, 09:45 and 10:30, finishing at 11:00. Submit before `#day-download`. Too little `#budget` yields a useful correction. |
| fitness | `sessions.html`, `timer.html` | Set `#work`, `#rest`, `#rounds`; submit, pause with `#pause`, resume and use `#reset`. `#clock` updates without continuous live announcements. Reset before changing an in-progress routine. |
| codingnotes | `notes.html`, `json.html` | Enter valid/invalid JSON in `#source`; submit, change `#indent`, and use `#json-download`. HTML-like strings remain text, never executed. Ctrl/Cmd+Enter also formats. |
| astronomy | `fieldnotes.html`, `eyepiece.html` | `#scope=750`, `#eyepiece=25`, `#apparent=60` gives 30× and an approximate 2° field. No live sky or location data. |
| boardgames | `games.html`, `dice.html` | `#dice=2`, `#sides=6` returns two values in 1…6 and their sum; `#rolls` keeps at most ten local results. |
| webhosting | `options.html`, `budget.html` | `#views=10000`, `#transfer=500`, `#files=50`, `#backups=7` gives 4.77 GiB transfer, 0.39 GiB storage and 5.96 GiB with the stated transfer margin. |

No renderer, network configuration, installer runtime or user website is changed
by the source builder or these content tests.
