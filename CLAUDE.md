# asxp.io — IE Sergei Poljanski website

## What this is
The public-facing website for the user's Individual Entrepreneur registered in Georgia. Two responsibilities:
1. Present the legal entity and accept contact-form submissions.
2. Generate, store, and serve client invoices as signed PDF links.

The site depends on the **storage stack** in the sibling `~/Code/projects/asxpio/storage` repo, which runs Postgres + MinIO on the same host. asxpio is stateless; all invoicing state lives there.

## Rule of thumb for this file
**Same confidentiality bar as the rendered HTML.** If a fact isn't on the public page, it doesn't belong here. Sensitive operational details (banking, registration number, tax-regime reasoning) live in the user's private memory, not in the repo.

## Hard rules

- **Never use the words "consulting" or "advisory"** anywhere on the site or in invoicing copy. Frame work as "services", "engineering", "implementation". This is for tax-classification reasons; ask the user before deviating.
- **Never commit `.env`** or any real credential. Production secrets come from Forgejo secrets at deploy time.

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
- **aws-sdk-s3** against MinIO on the storage stack
- In-memory `RateLimit` (5 req/hour/IP) — see `lib/rate_limit.rb`
- `Rack::Protection::AuthenticityToken` for CSRF (uses session-stored token)
- `AdminAuth` Rack middleware: HTTP Basic on `/admin/*`, credentials from env. Greedy-prefix bug fixed; only `/admin` exact and `/admin/` paths are gated, so sibling assets like `/admin-invoice-form.js` stay public.
- Honeypot field named `website` for spam
- Static assets in `public/`; views in `views/`
- Deploy: `Dockerfile` + `docker-compose.yml` (Traefik labels for asxp.io / www.asxp.io). Container joins two external Docker networks: `traefik` (ingress) and `storage` (Postgres + MinIO).
- Dev shell: `flake.nix` (Ruby 3.4, bundler, openssl, zlib, libyaml, postgresql). Run `nix develop`.

The patterns mirror `~/Code/projects/narayana/www`. Use that repo as a reference for conventions (middleware, helpers, dotenv pattern) — but don't pull in narayana-specific things this site doesn't need (no Redis, no i18n, no API client).

## Storage stack dependency

Postgres and MinIO are owned by `~/Code/projects/asxpio/storage` (separate Forgejo repo, separate deploy pipeline). asxpio talks to:

- `postgres:5432` over the `storage` Docker network — for the `invoices` table.
- `minio:9000` over the `storage` Docker network — for putting PDF bytes.
- `https://s3.asxp.io` over Traefik — used **only** for presigned URLs, so the browser can dereference them. Same MinIO, different hostname.

If the storage stack is down, the asxpio container will fail to boot (Sequel connects at process start). The contact form goes down with the invoicing UI in that case. Accepted trade-off; the alternative was a much more elaborate "degrade gracefully when DB is gone" path that wasn't worth the code.

The `asxpio` Postgres role + `asxpio-invoices` MinIO bucket + scoped MinIO user are provisioned by the storage repo's init containers (`init/postgres-init.sh`, `init/minio-bootstrap.sh`). Changing those requires editing storage, not this repo.

## Page structure

The public site is multi-page: `/` (hero + intro links + services grid), `/keys`, `/contact` (form + direct contacts + the demoted legal/invoice-details block). Shared top nav in `views/partials/_site_nav.erb` (included by each page view, not the layout, so invoice/admin pages stay nav-free); it highlights the active page and links to `blog.asxp.io` — **the blog repo (`../blog`) must be deployed or that nav link 404s**. Per-page `@page_title` is set in the routes.

## Contact form behavior

The form lives on `GET /contact`; validation errors re-render `:contact` (422/429/500). `POST /contact` does, in order:
1. Honeypot check — if `website` field non-empty, silently 302 to `/thanks`.
2. Validate name, email, subject, message.
3. Rate-limit by client IP.
4. `Mailer.notify_owner` → message to `MAIL_TO` (`ie@asxp.io`), `Reply-To: <visitor email>`.
5. `Mailer.confirm_visitor` → receipt to visitor, `Reply-To: ie@asxp.io`. Failure here is logged but not surfaced to the user.

`MAIL_FROM` must use a Fastmail-verified send-as address (currently `me@asxp.io`). The friendly name reads "IE Sergei Poljanski Contact Form".

## Invoicing

### Routes

Admin (HTTP Basic via `ADMIN_USER`/`ADMIN_PASSWORD`):

- `GET  /admin` → redirects to `/admin/invoices`.
- `GET  /admin/invoices` — list, newest first.
- `GET  /admin/invoices/new` — create form. Dynamic line items via `public/admin-invoice-form.js`.
- `POST /admin/invoices` — validate → allocate number → render PDF → upload to MinIO → persist row.
- `GET  /admin/invoices/:uuid` — detail page with public URL + "Mark paid" toggle.
- `POST /admin/invoices/:uuid/paid` — toggles `paid_at`.

Public:

- `GET /i/:uuid` — landing page: client name, number, total, status badge, download button.
- `GET /i/:uuid/pdf` — 302 to a 5-minute MinIO presigned URL (Content-Disposition: attachment).
- `GET /healthz` — liveness (plus `SELECT 1` when invoicing is configured); used by the Docker HEALTHCHECK and the deploy pipeline's post-deploy wait.

### Storage model

- `invoices` table (`db/migrations/001_invoices.rb`): UUID PK, unique `number` (format `INV-{YYYY}-{NNNN}`, allocated by scanning the current year's max), JSONB `items`, captured-at-issue `gel_rate`, `paid_at` nullable, `pdf_key` for the MinIO object path (`invoices/<number>-<uuid>.pdf`).
- `db/migrations/002_invoice_ltc.rb` added Litecoin-only columns; `003_invoice_crypto.rb` generalized them: `crypto_coin` (a `CryptoAsset` code, e.g. `BTC`, `USDT-TRC20`), `crypto_address` (captured at issue), `crypto_rate` (price in the invoice currency, snapshotted), `crypto_amount` (due — derived `total / crypto_rate` unless hand-overridden). All nullable; crypto is opt-in per invoice (blank address ⇒ no crypto block/QR). Pre-migration LTC invoices were backfilled with `crypto_coin = 'LTC'`.
- `Invoice` (Sequel model) — number allocation, line-item normalization, `total` / `total_gel` helpers, plus `crypto?` and `crypto_amount_due`. **Always assign `uuid` as an attribute after `Invoice.new(...)`** — passing it to `new` raises `MassAssignmentRestriction` because Sequel guards primary keys.

### Crypto payment

Opt-in per invoice, one asset per invoice. `lib/crypto_asset.rb` is the registry (BTC, LTC, ETH, XMR, SOL, ALGO, USDT/USDC across ERC-20/TRC-20/BEP-20/Solana/Algorand) — adding an asset is one entry there. The new-invoice form has a coin select plus address (prefilled per coin from the `CRYPTO_ADDRESSES` env — JSON `code => address`; legacy `LTC_ADDRESS` still fills LTC), a rate field with a "Fetch live" button, and an editable amount overriding the derived value. `GET /admin/crypto-rate?coin=&currency=&gel_rate=` returns the live price via `lib/crypto_rate.rb` (CoinGecko, no API key; USD/EUR direct, GEL derived from the form's `gel_rate`; chain variants of a stablecoin share the token's CoinGecko id). `lib/crypto_qr.rb` renders the QR for the PDF: payment URI with amount where a scheme supports it (BTC/LTC BIP21, XMR `tx_amount`, SOL Solana Pay), scheme-only for ETH, bare address for tokens/ALGO (the PDF prints a "verify the network" hint for those).

### PDF rendering

`lib/invoice_pdf.rb` (Prawn). A4, single-column header + two-column parties + bracketed meta strip + line items + right-aligned totals + payment block + repeating footer. Noto Sans Georgian is registered as a fallback family so the Georgian legal name renders. Avoid Unicode characters not present in Noto Sans (e.g. `≈`) — they render as tofu.

### Frontend

Admin pages use a shared dark palette extended in `public/style.css` (search for `Invoices`). The new-invoice form's "+ add line" / row removal is plain vanilla JS in `public/admin-invoice-form.js` (no framework). The public landing intentionally exposes only what a recipient needs to confirm the right invoice; no banking details on the HTML page, those live inside the PDF.

### Caveats

- The `INV-{YYYY}-{NNNN}` allocator is `SELECT MAX(...) + 1` over the numeric suffix. Concurrent creates (Puma threads) that collide on the unique constraint are retried — the whole build→render→upload→save sequence, since the PDF embeds the number; a losing attempt orphans its two S3 objects. If we ever add a second container, switch to a DB-side sequence per year.
- Anyone with the UUID can fetch the PDF. UUIDs are 122-bit random so not enumerable, but they aren't access-controlled. If a stronger gate is ever needed (email confirmation, expiry on paid, etc.) it goes in the `/i/:uuid` and `/i/:uuid/pdf` handlers.
- The MinIO bucket is **private**; only the app's scoped service account can put/get. Presigned URLs use `S3_PUBLIC_ENDPOINT=https://s3.asxp.io` so the signed host matches what the browser fetches.

## Operational notes

- `client_ip` reads `X-Forwarded-For` first (Traefik sets it), falling back to `X-Real-IP` and `REMOTE_ADDR`.
- The rate limiter resets on app restart — acceptable for one-process deploys.
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

- **Generate a new SESSION_SECRET:** `openssl rand -hex 64` (then update Forgejo secret).
- **Generate a new ADMIN_PASSWORD:** `openssl rand -base64 24`. **Save it to a password manager** — Forgejo secrets are write-only.
- **Local dev:** `nix develop`, then `bundle exec rerun -- rackup -p 3000`. Visit `http://localhost:3000`. Without `DATABASE_URL` the contact form still works; invoicing routes return 503.
- **Run tests:** `nix develop -c bin/test` — full suite (minitest + rack-test) against an ephemeral Postgres it provisions and tears down itself. `bundle exec rake test` runs without a DB, skipping DB-backed tests. Mail uses `Mail::TestMailer`; S3 uses aws-sdk stubbed responses; tests never touch real services, and `.env` is deliberately not loaded when `RACK_ENV=test`.
- **Local image build (sanity check):** `docker compose build`
- **Production deploy:** automatic via `.forgejo/workflows/deploy.yaml` on push to `main`. Pipeline:
  0. Test suite runs on the `nix-latest` runner label (postgres service container); a red suite blocks the build. Non-main branches get the same job from `test.yaml`.
  1. Kaniko builds the image and pushes it to the Forgejo registry.
  2. SSH copies `docker-compose.yml` to the deploy directory on the prod host.
  3. SSH writes `.env` (mode 600) from Forgejo secrets. The full set of invoicing envs (`DATABASE_URL`, `S3_*`, `ADMIN_*`) is built here; the per-app `ASXPIO_DB_PASSWORD` / `ASXPIO_S3_*` values must match the storage repo's Forgejo secrets, since storage's init containers provision the corresponding role + MinIO user.
  4. SSH `sed`-substitutes the image tag in `docker-compose.yml`, runs `docker compose up -d`, and waits (up to 90s) for the image `HEALTHCHECK` (`GET /healthz`) to report healthy — a crash-looping container fails the deploy.

## Where the secrets live

| Forgejo secret           | Use                                                                      | Rotate by                                                                                       |
|--------------------------|--------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| `SESSION_SECRET`         | Rack session cookie HMAC                                                 | Update secret + push. All sessions invalidated; no user impact since nobody is logged in.        |
| `SMTP_PASSWORD`          | Fastmail app password                                                    | New Fastmail app password → update secret → push.                                                |
| `ADMIN_USER`             | HTTP Basic username for `/admin/*`                                       | Change secret + push.                                                                            |
| `ADMIN_PASSWORD`         | HTTP Basic password for `/admin/*`                                       | Generate fresh, update secret + push. **Forgejo doesn't show old values.** Save to password manager. |
| `ASXPIO_DB_PASSWORD`     | Password for the `asxpio` Postgres role                                  | Update on **both** repos to the same value. Push storage first (re-provisions role), then asxpio. |
| `ASXPIO_S3_ACCESS_KEY`   | MinIO service account key, scoped to `asxpio-invoices`                   | Same dual-repo update. Push storage first.                                                       |
| `ASXPIO_S3_SECRET_KEY`   | Matching MinIO secret                                                    | Same.                                                                                            |
| `CRYPTO_ADDRESSES`       | JSON object (`CryptoAsset` code => payout address) prefilled per coin into the new-invoice form | Not confidential (printed on invoices + QR), but kept as a secret so rotation is a one-place change. Update secret + push. Existing invoices keep their captured address. |
| `LTC_ADDRESS`            | Legacy: fills the LTC default when `CRYPTO_ADDRESSES` has no LTC entry  | Same as above. Can be folded into `CRYPTO_ADDRESSES` and removed.                                |
| `DEPLOY_IP/USER/SSH_KEY` | SSH to prod from CI                                                      | Standard SSH key rotation.                                                                       |
| `FORGEJO_REGISTRY/USER/TOKEN` | Kaniko registry auth                                                | Forgejo token rotation.                                                                          |

**Non-secret config that lives in the workflow** (not in `.env.example`, not in secrets): `SMTP_ADDR`, `SMTP_PORT`, `SMTP_USER`, `MAIL_FROM`, `MAIL_TO`, `DATABASE_URL` host portion, `S3_ENDPOINT`, `S3_PUBLIC_ENDPOINT`, `S3_REGION`, `S3_BUCKET`. Change these by editing `.forgejo/workflows/deploy.yaml`.

### Password character caveat (learned the hard way)

`DATABASE_URL` is a URL, so `ASXPIO_DB_PASSWORD` **must not contain** `/`, `@`, `:`, `?`, `#`, `&`, `%`, `+`, `=`, or whitespace. If a rotation produces a password with those characters, Sequel will refuse to parse the URL and the container won't boot. Generate URL-safe passwords with:

```
LC_ALL=C tr -dc 'A-Za-z0-9._-' </dev/urandom | head -c 40; echo
```

### Recovering forgotten secrets

If you forget the value of a write-only Forgejo secret, the live `.env` on prod still has it:

```
ssh deploy@<prod-host> 'sudo cat /opt/asxpio/.env'      # ADMIN_*, DATABASE_URL, S3_*
ssh deploy@<prod-host> 'sudo cat /opt/storage/.env'     # ASXPIO_DB_PASSWORD etc. (same value, storage side)
```

Re-saving the secret in Forgejo to match a fresh value requires updating both repos and redeploying storage first.

## What `.env.example` is for

Local development only. Copy to `.env`, fill in dummy/test SMTP creds (or real ones if you want to actually send) and a throwaway `SESSION_SECRET`. The Nix dev shell sources `.env` automatically. **Production never reads `.env.example` and never has a stale `.env`** — every deploy regenerates it.
