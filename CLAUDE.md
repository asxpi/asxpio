# asxp.io — IE Sergei Poljanski website

## What this is
The public-facing website for the user's Individual Entrepreneur registered in Georgia. Two responsibilities:
1. Present the legal entity and accept contact-form submissions.
2. Generate, store, and serve client invoices as signed PDF links.

The site depends on the **storage stack** in the sibling `~/Code/projects/asxpio/storage` repo, which runs Postgres + Garage (S3) on the same host. asxpio is stateless; all invoicing state lives there.

## Rule of thumb for this file
**Same confidentiality bar as the rendered HTML.** If a fact isn't on the public page, it doesn't belong here. Sensitive operational details (banking, registration number, tax-regime reasoning) live in the user's private memory, not in the repo.

## Hard rules

- **Never use the words "consulting" or "advisory"** anywhere on the site or in invoicing copy. Frame work as "services", "engineering", "implementation". This is for tax-classification reasons; ask the user before deviating.
- **Never commit `.env`** or any real credential. Production settings and secrets live in iac (sops, below).

## Entity facts (also visible on the rendered page)

- Legal name: **IE Sergei Poljanski** / `SERGEI POLJANSKI` (Latin) / `ინდ. მეწარმე სერგეი პოლჯანსკი` (Georgian)
- Legal form: Individual Entrepreneur (Georgia)
- Tax ID: `304813343`
- Registered: 2026-05-04
- Activity codes: 62010 (main), 62090 (additional)
- Address: Ilia and Nino Nakashidze St, N 1, Building N3, Apt N3, Krtsanisi, Tbilisi, Georgia
- Public contact: `ie@asxp.io`, `t.me/ie_asxpi`, +995 595 026 471

Banking details and registration number are deliberately not on the public page and not in this file. They go on invoices only.

## Stack

- **Sinatra 4.2** + Puma + Rack 3 + erubi, on Ruby 3.4
- **Mail gem** for SMTP (Fastmail, STARTTLS on 587)
- **Sequel + pg** for Postgres (the `asxpio` DB on the storage stack)
- **Prawn + prawn-table** for PDF rendering, with vendored Noto Sans + Noto Sans Georgian in `public/fonts/`
- **aws-sdk-s3** against Garage on the storage stack
- In-memory `RateLimit` (5 req/hour/IP) — see `lib/rate_limit.rb`
- `Rack::Protection::AuthenticityToken` for CSRF (uses session-stored token)
- `AdminAuth` (`lib/admin_auth.rb`, a Sinatra extension): session login at `/admin/login` against the `users` table (`lib/user.rb`, scrypt via OpenSSL, no gem). Session holds user id + `session_version` (bump = logged out everywhere). `ADMIN_USER`/`ADMIN_PASSWORD` bootstrap the first superuser on an empty table and otherwise work only while no active superuser exists (recovery; it re-creates that superuser). Login is rate-limited per IP (`LOGIN_RATE_LIMIT`, default 10/15 min).
- Superusers authenticate only on `SUPERUSER_HOST` (`admin.asxp.io`; Traefik allows WireGuard 10.20.0.0/24 + VPC 10.10.0.0/20 only). Elsewhere their correct password gets the normal "Wrong username or password", their session counts as logged out, a reset request sends nothing, and the env recovery login is off. The check reads `HTTP_HOST`, not `request.host` (which trusts `X-Forwarded-Host`). Account links for non-superusers use `SITE_URL` so they work off WireGuard. Unset = no restriction (dev, tests).
- Permissions (`lib/admin_acl.rb`): areas `invoices`, `bingo`, `files`, `users` × independent flags read/write/delete in `user_permissions` (read + delete without write is valid); superusers bypass. GET → read (…/new, …/duplicate → write), POST …/delete|…/disable → delete, other POST → write. Unmapped /admin paths are superuser-only, and `test/admin_acl_test.rb` fails if a registered admin route isn't mapped — add new admin routes to `AdminACL::RULES`. Views hide forms via `can?(area, perm)`; the server check is the real gate.
- Users UI (`lib/users_admin.rb`): `/admin/users` create/edit/disable/delete (superusers can also rename; sessions key on id, the audit log keeps old names), permission grid (you can only grant flags you hold; flags you can't grant keep their value; only superusers touch superuser accounts; no self-lockout; last active superuser can't be deleted). New users get a one-time invite link (48 h) by email via `Mailer.account_link`, also shown once to the admin. `/admin/reset` emails a 1 h reset link (same answer for unknown accounts). Tokens are stored as SHA-256 only (`user_tokens`). `/admin/audit` lists `audit_log` (logins, user changes, bingo and invoice actions) — call `audit!(action, target, detail)` in new admin actions.
- Timestamps: `Sequel.default_timezone = :utc` (lib/db.rb); always write `Time.now.utc`.
- Honeypot field named `website` for spam
- Static assets in `public/`; views in `views/`
- Deploy: `flake.nix` builds the app (`nix/package.nix`) and runs it (`nix/module.nix`, `services.asxpio`); see Production below.
- Dev shell: `flake.nix` (Ruby 3.4, bundler, openssl, zlib, libyaml, postgresql). Run `nix develop`.

The patterns mirror `~/Code/projects/narayana/www`. Use that repo as a reference for conventions (middleware, helpers, dotenv pattern) — but don't pull in narayana-specific things this site doesn't need (no Redis, no i18n, no API client).

## Storage dependency

Postgres and Garage are native services on asxpio-ops (iac, `nixos/hosts/asxpio-ops/{postgres,garage}.nix`). The app runs on asxpio-services and talks to:

- `10.10.0.10:5432` (Postgres, private network) — the `asxpio` database.
- `10.10.0.10:3900` (Garage S3, private network) — PDFs, bingo photos, public files.
- `https://s3.asxp.io` over Traefik — used **only** for presigned URLs, so the browser can dereference them. Same Garage, different hostname.

If Postgres is down, the app fails to boot (Sequel connects at process start) and systemd retries every 5 s until it is back. The contact form goes down with the invoicing UI in that case. Accepted trade-off; the alternative was a much more elaborate "degrade gracefully when DB is gone" path that wasn't worth the code.

## Page structure

The public site is multi-page: `/` (hero + intro links + services grid), `/keys`, `/contact` (form + direct contacts + the demoted legal/invoice-details block). Shared top nav in `views/partials/_site_nav.erb` (included by each page view, not the layout, so invoice/admin pages stay nav-free); it highlights the active page and links to `blog.asxp.io` — **the blog repo (`../blog`) must be deployed or that nav link 404s**. Per-page `@page_title` is set in the routes.

## Contact (form removed)

**There is no contact form.** `/contact` is a static page: direct contacts (email, Telegram, phone) plus the legal/invoice-details block. `POST /contact` and `GET /thanks` were removed, along with `views/partials/_contact_form.erb`, `views/thanks.erb`, the honeypot, and the `.contact-form` CSS.

Removed 2026-08-04 after persistent spam: ~12 submissions/48h reaching the inbox, overwhelmingly from `80.94.95.173` (with neighbours in `80.94.95.0/24` and `141.98.11.0/24`). The traffic was scripted, not browser-driven — `HTTP/1.0` requests with a User-Agent randomised per request across Chrome 129/130/131 + Avast/CCleaner/Edg variants. The in-app rate limiter was absorbing ~75% of attempts but the remainder still landed. Options weighed and rejected: proof-of-work captcha (would have worked against these no-JS scripts, but not worth the code for a form whose only output is an email), Cloudflare Turnstile (external dependency, conflicts with the self-hosted posture), Traefik IP ban (v3 has no built-in deny-list — only `IPAllowList`; would need a third-party plugin or an all-except-CIDR allow-list with an IPv6 footgun).

**Still present but now unused by the public site:** `lib/mailer.rb`, `lib/rate_limit.rb`, and the `SMTP_*` / `MAIL_*` env vars. Left in place deliberately so the form can be restored, and because `Mailer.configure!` still runs at boot. If the form is never coming back, these and their entries in the environment file in iac can be retired.

`MAIL_FROM` must use a Fastmail-verified send-as address (currently `me@asxp.io`).

If a form is ever reinstated, note that Traefik's access log (`/var/log/traefik/access.log` on asxpio-ops, User-Agent retained) is the only place with client IPs — the app itself logs no requests.

## Invoicing

### Routes

Admin (HTTP Basic via `ADMIN_USER`/`ADMIN_PASSWORD`):

- `GET  /admin` → dashboard (`views/admin/dashboard.erb`): invoice counts/outstanding/overdue + recent five, bingo score/reserve/latest incident/missing photos. Shared admin nav in `views/admin/_nav.erb`.
- `GET  /admin/invoices` — list, newest first.
- `GET  /admin/invoices/new` — create form. Dynamic line items via `public/admin-invoice-form.js`.
- `POST /admin/invoices` — validate → allocate number → render PDF → upload to S3 → persist row.
- `GET  /admin/invoices/:uuid` — detail page with public URL + "Mark paid" toggle.
- `POST /admin/invoices/:uuid/paid` — toggles `paid_at`; optional `paid_on` (YYYY-MM-DD, no future dates) backdates it to that day 12:00 UTC. `POST …/paid-date` corrects the date of a paid invoice. The PDF doesn't print the date, so neither re-renders.
- `POST /admin/invoices/:uuid/cancel` (optional `reason`) — sets `cancelled_at`/`cancel_reason`, renders and uploads a third PDF variant (`…-cancelled.pdf`, diagonal CANCELLED stamp + date/reason line) which becomes current, so the client link and download switch over. Status precedence: cancelled > paid > pending; marking paid is refused while cancelled. `POST …/reinstate` clears it.
- `POST /admin/invoices/:uuid/hide` — superuser-only toggle of `hidden`: hidden invoices are left out of the admin list, dashboard and admin invoice pages for everyone but superusers (`visible_invoices` / `admin_invoice!` helpers). The public `/i/:uuid` link is unaffected.
- `GET /admin/invoices/stats[?year=YYYY]` — `lib/invoice_stats.rb`: invoiced / received / outstanding in GEL at each invoice's captured rate (cancelled excluded), overdue, average days to pay, received per month by payment date (bar chart, `--chart-bar` validated with the dataviz skill against the dark surface) plus the same figures as a table, per-currency totals, top clients, crypto usage. Respects `visible_invoices`.

Public:

- `GET /i/:uuid` — landing page: client name, number, total, status badge, download button.
- `GET /i/:uuid/pdf` — 302 to a 5-minute presigned URL (Content-Disposition: attachment).
- `GET /healthz` — liveness (plus `SELECT 1` when invoicing is configured); used for checks; systemd learns readiness from Puma itself (`Type=notify`).

### Storage model

- `invoices` table (`db/migrations/001_invoices.rb`): UUID PK, unique `number` (format `INV-{YYYY}-{NNNN}`, allocated by scanning the current year's max), JSONB `items`, captured-at-issue `gel_rate`, `paid_at` nullable, `pdf_key` for the S3 object path (`invoices/<number>-<uuid>.pdf`).
- `db/migrations/002_invoice_ltc.rb` added Litecoin-only columns; `003_invoice_crypto.rb` generalized them: `crypto_coin` (a `CryptoAsset` code, e.g. `BTC`, `USDT-TRC20`), `crypto_address` (captured at issue), `crypto_rate` (price in the invoice currency, snapshotted), `crypto_amount` (due — derived `total / crypto_rate` unless hand-overridden). All nullable; crypto is opt-in per invoice (blank address ⇒ no crypto block/QR). Pre-migration LTC invoices were backfilled with `crypto_coin = 'LTC'`.
- `Invoice` (Sequel model) — number allocation, line-item normalization, `total` / `total_gel` helpers, plus `crypto?` and `crypto_amount_due`. **Always assign `uuid` as an attribute after `Invoice.new(...)`** — passing it to `new` raises `MassAssignmentRestriction` because Sequel guards primary keys.

### Crypto payment

Opt-in per invoice. Crypto options are **payout addresses** (`payout_addresses`, `lib/payout_address.rb`, edited at `/admin/invoices/payout-addresses`): each row is self-contained — ticker (`coin`, printed on the PDF), name, QR URI scheme (`litecoin`; NULL = bare address), amount parameter (`amount`/`tx_amount`/NULL), CoinGecko id (NULL = rate typed by hand), address, active. Several per ticker are fine; any coin can be added. `CryptoAsset::DEFAULTS` is only a template set (prefills those fields for a known ticker, backfilled migration 012, names legacy invoices) plus the one-time env seed (`PayoutAddress.seed_from_env!` from `CRYPTO_ADDRESSES`/`LTC_ADDRESS`). The new-invoice form picks a payout address; the invoice **snapshots** `crypto_coin`, `crypto_address`, `crypto_name`, `crypto_scheme`, `crypto_amount_param`, so editing, retiring or deleting a payout entry never changes issued invoices. The form has a "Fetch live" button: `GET /admin/crypto-rate?payout=<id>&currency=&gel_rate=` returns the price via `lib/crypto_rate.rb` (CoinGecko, no API key; USD/EUR direct, GEL derived from the form's `gel_rate`). `lib/crypto_qr.rb` renders the QR from the invoice's snapshot: `scheme:address?param=amount`, scheme-only, or the bare address (the PDF then prints a "verify the network" hint).

### PDF rendering

`lib/invoice_pdf.rb` (Prawn). A4, single-column header + two-column parties + bracketed meta strip + line items + right-aligned totals + payment block + repeating footer. Noto Sans Georgian is registered as a fallback family so the Georgian legal name renders. Avoid Unicode characters not present in Noto Sans (e.g. `≈`) — they render as tofu.

### Frontend

Admin pages use a shared dark palette extended in `public/style.css` (search for `Invoices`). The new-invoice form's "+ add line" / row removal is plain vanilla JS in `public/admin-invoice-form.js` (no framework). The public landing intentionally exposes only what a recipient needs to confirm the right invoice; no banking details on the HTML page, those live inside the PDF.

### Caveats

- The `INV-{YYYY}-{NNNN}` allocator is `SELECT MAX(...) + 1` over the numeric suffix. Concurrent creates (Puma threads) that collide on the unique constraint are retried — the whole build→render→upload→save sequence, since the PDF embeds the number; a losing attempt orphans its two S3 objects. If we ever run a second instance, switch to a DB-side sequence per year.
- Anyone with the UUID can fetch the PDF. UUIDs are 122-bit random so not enumerable, but they aren't access-controlled. If a stronger gate is ever needed (email confirmation, expiry on paid, etc.) it goes in the `/i/:uuid` and `/i/:uuid/pdf` handlers.
- The bucket is **private**; only the app's scoped key can put/get. Presigned URLs use `S3_PUBLIC_ENDPOINT=https://s3.asxp.io` so the signed host matches what the browser fetches.

## Datacenter bingo (admin side)

The public site (datacenterbingo.xyz) lives in its own repo: `git.czsk.it/asxpi/datacenterbingo`, mirrored to GitHub. It reads the tables and photos below through a read-only DB role (`bingo`) and S3 key. What stays here is the admin, which writes, and the schema.

- **Schema is owned here.** After adding a bingo migration, refresh `test/schema.sql` in datacenterbingo and update its models. Keep `Bingo::PROVIDERS`, `Board` and the model methods in step with its `lib/bingo.rb`. UI strings (`T`) and views are only there.
- `BINGO_HOST` (the environment file in iac) is used only for the IndexNow host and the admin's "view site" link; Traefik no longer routes it here.
- Tables `bingo_datacenters`, `bingo_incidents` (`db/migrations/004_bingo.rb`…). `updated_at` is set on save; `renumber!` bumps only moved rows, and deleting an incident bumps its datacenter (use `destroy`, not dataset `delete`, so the hook runs). First boot seeds from `db/bingo_seed.json` only if the table is empty; after that, edit via the admin.
- Admin: `/admin/bingo` (`lib/bingo_admin.rb`). Record and delete incidents; add, edit and delete DCs (delete cascades); upload a photo or import it from a URL; bulk import or re-import photos from `photo_source_url`; "Sort by MW".
- Status: operational | building | planned. `mw_type` (it | connected | total | design | mva, NULL = not stated) tags the MW figure; mva swaps the unit. The public default card is operational only, and so is the dashboard tile (`Board.load('operational')`).
- Provider: `bingo_datacenters.provider` holds a `Bingo::PROVIDERS` slug (backfilled by migration 016; new rows get it from `Bingo.guess_provider`; editable in the admin). The public site filters cards by it.
- Ordering: `position` is dense 1..N (`Bingo.place!` inserts and shifts; `renumber!` runs after deletes). Positions 1–25 are the card; the rest are reserve. Slug is fixed at creation because it names the photo objects.
- Photos: stored in `BINGO_S3_BUCKET` (`datacenterbingo-photos`, made by the storage repo; unset = `S3_BUCKET`) as `bingo/<slug>-<hex>.<ext>`, with the type sniffed from magic bytes (JPEG/PNG/WebP).
  - Limits: 8 MB cap, and metadata is stripped (GPS!). URL import is https-only.
  - On store, ImageMagick derives `-480.webp`, `-1200.webp` and `-og.jpg` (1200×630). `photo_variants` / `photo_og` record whether that succeeded.
  - "Rebuild resized photos" re-derives the variants from the stored originals.
  - Served publicly by the bingo site at `/p/:file`; previewed here at `/admin/bingo/p/:file`.
- IndexNow (`Bingo::IndexNow`): admin actions ping api.indexnow.org with the changed URLs. The key comes from `INDEXNOW` → `INDEXNOW_KEY`; the bingo site has the same key and serves `/<key>.txt`. Unset = no-op.
- Photos are third-party (operator sites, Habr, Wikimedia Commons CC BY-SA) — keep `photo_credit` filled; renders/illustrations are marked as such.
- Monitor (`lib/bingo_monitor.rb`, `bin/monitor`, migration 017): the `asxpio-monitor` systemd service (same package, `bin/asxpio-monitor`; touches `MONITOR_HEARTBEAT` after every round) opens one TCP connection per minute to each active `bingo_monitor_targets` row; a handshake or a refusal counts as answered. Results fold into 5-minute `bingo_monitor_samples` per datacenter (upserts) and `bingo_monitor_buckets` (rounds + control hosts, i.e. targets with `datacenter_id` NULL); kept 30 days. Targets are managed at `/admin/bingo/monitor` (bulk lines `slug host[:port] source_url label`, slug `_control` for controls). Only add hosts a public source ties to that one site. The public status page in datacenterbingo reads these tables; migration 017 grants them to the `bingo` role.
- No street addresses or coordinates on the page — city level only.

## Public files (`/admin/files`)

Files published for anyone to fetch: `lib/files_admin.rb`, `lib/public_file.rb`, migration 018, ACL area `files`.

- Objects go to `PUBLIC_S3_BUCKET` (`public`, a Garage website made by the storage repo; unset = `S3_BUCKET`) and are read at `PUBLIC_BASE_URL/<key>` (`https://s3.asxp.io/public/…`), not through this app. Both are set in the environment file in iac.
- The app's key is write-only there (put, delete; no read, no list), so `public_files` is the only record of the objects. Objects uploaded some other way don't show up.
- Key: `<8 hex>/<sanitised ASCII filename>`, fixed for the life of the file. "Replace" re-uploads under the same key and must keep the extension.
- The extension decides how the object is served. `PublicFile::INLINE` types (images, PDF, plain text, audio, video) get their content type and `inline`; everything else, HTML and SVG included, is `application/octet-stream` with `Content-Disposition: attachment`. `s3.asxp.io` is same-site with the admin, so don't add a type that can run script.
- JPEG/PNG/WebP metadata is stripped (`Bingo::Photo.strip_metadata`) unless the uploader ticks "keep".
- Limits: `PUBLIC_MAX_MB` per file (50) and `PUBLIC_QUOTA_MB` in total (2048). Uploads are read into memory.

## Operational notes

- `client_ip` reads `X-Forwarded-For` first (Traefik sets it), falling back to `X-Real-IP` and `REMOTE_ADDR`.
- The rate limiter resets on app restart — acceptable for one process.
- If the Ruby process is down, the site is down. There's no static fallback. (Trade-off accepted for the contact form.)

## SSH key comment caveat

`public/id_ed25519.pub` is served from the site. The comment field (currently `ie+2026@asxp.io`) is part of the key file itself; editing the website without regenerating the key file means the website and the file disagree. Keep them in sync, or regenerate the key.

## Logo & brand assets

The real logo from the designer friend has landed: `public/logo.svg`, a white hedgehog with an "SP" script signature (the hedgehog mark got promoted from personal placeholder to brand). Derived assets, all generated from `logo.svg`:

- `public/favicon-32.png` — hedgehog only (no "SP", too small to read) on `#121212`. Generated but **not used**: the user prefers the old `hedgehog.png` as favicon.
- `public/apple-touch-icon.png` — 180×180, same treatment. Also currently unused.
- `public/og-card.png` — 1200×630 OG/Twitter card: hedgehog + name + tagline in IBM Plex Sans on `#121212`. Referenced from `views/layout.erb` (`og:image`, `twitter:card: summary_large_image`).

To regenerate (e.g. if the logo changes): `resvg --export-id 'hedgehog-'` renders the hedgehog without the signature; compose with ImageMagick on a `#121212` canvas (both via `nix shell nixpkgs#resvg nixpkgs#imagemagick`). `public/hedgehog.png` is the old pre-IE personal mark and remains the favicon + apple-touch icon by the user's choice (`views/layout.erb`).

## Fonts & design tokens

Web fonts are **self-hosted** in `public/fonts/` (no Google Fonts / jsdelivr): IBM Plex Sans (400/400i/600/700) + IBM Plex Mono (400), latin subsets from fontsource, plus `NotoSansGeorgian-Regular.woff2` (converted from the vendored PDF TTF) as a `unicode-range`-gated fallback so the Georgian legal name renders in Noto without a download on Georgian-free pages. `@font-face` lives at the top of `public/style.css`; `layout.erb` preloads the two main sans weights. The PDF fonts (TTFs, same dir) are unchanged and still used by Prawn.

All colors in `public/style.css` are CSS custom properties on `:root` (design tokens: `--bg`, `--surface*`, `--border*`, `--text*`, badge colors). The blog repo (`../blog`) is meant to consume the same token block — keep them in sync when restyling. Don't hard-code hex values in new CSS; add a token.

## Common tasks

- **Local dev:** `nix develop`, then `bundle exec rerun -- rackup -p 3000`. Visit `http://localhost:3000`. Without `DATABASE_URL` the contact form still works; invoicing routes return 503.
- **Run tests:** `nix develop -c bin/test` — full suite (minitest + rack-test) against an ephemeral Postgres it provisions and tears down itself. `bundle exec rake test` runs without a DB, skipping DB-backed tests. Mail uses `Mail::TestMailer`; S3 uses aws-sdk stubbed responses; tests never touch real services, and `.env` is deliberately not loaded when `RACK_ENV=test`.
- **Package (what the servers run):** `nix build`. After changing `Gemfile.lock`, `nix run nixpkgs#bundix` refreshes `gemset.nix`; CI (`bin/check-gemset`) fails until they match.

## Production

`flake.nix` exports the app (`packages.default`: bundlerEnv from `Gemfile.lock` and `gemset.nix`; `bin/asxpio` is Puma serving `config.ru`, `bin/asxpio-monitor` the worker; photos are resized with ImageMagick 7's `magick`) and a module (`services.asxpio`: both as hardened systemd services with a dynamic user). asxpio-services runs them; Traefik on asxpio-ops routes asxp.io, www and admin.asxp.io (WireGuard + VPC only) to port 3001.

A push to `main` is picked up by Renovate in asxpi/iac (flake input `asxpio`) within about 15 minutes and deployed by comin. CI here (`.forgejo/workflows/ci.yaml`) only tests: the suite on a Postgres service container, `bin/check-gemset`, the package build. Migrations run at boot, as before.

## Where the secrets live

All production settings and secrets are one environment file in iac's sops (`nixos/secrets/asxpio-services.yaml`, key `asxpio/env`; edit with `sops` from iac's `nixos/`). The app's Postgres role password and Garage key are also provisioned on asxpio-ops from `nixos/secrets/asxpio-ops.yaml` (`postgres/asxpio_password`, `garage/asxpio_*`); a rotation changes both files in one commit. The `DATABASE_URL` and `S3_*` values here are in Garage's key format already.

- `SESSION_SECRET`: `openssl rand -hex 64`. Changing it logs everyone out.
- `ADMIN_USER` / `ADMIN_PASSWORD`: the env recovery login. Save new values to the password manager.
- `CRYPTO_ADDRESSES`, `LTC_ADDRESS`: **seed only**, imported into `payout_addresses` on the first boot with an empty table; drop them once the admin page shows the addresses.
- `INDEXNOW_KEY`: shared with datacenterbingo, which serves it (its own env file in iac).

### Password character caveat (learned the hard way)

`DATABASE_URL` is a URL, so the `asxpio` role's password **must not contain** `/`, `@`, `:`, `?`, `#`, `&`, `%`, `+`, `=`, or whitespace. If a rotation produces a password with those characters, Sequel will refuse to parse the URL and the app won't boot. Generate URL-safe passwords with:

```
LC_ALL=C tr -dc 'A-Za-z0-9._-' </dev/urandom | head -c 40; echo
```

## What `.env.example` is for

Local development only. Copy to `.env`, fill in dummy/test SMTP creds (or real ones if you want to actually send) and a throwaway `SESSION_SECRET`. The Nix dev shell sources `.env` automatically. **Production never reads `.env.example` or a `.env`**: its environment file comes from iac.
