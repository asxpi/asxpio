# asxp.io — IE Sergei Poljanski website

## What this is
The public-facing website for the user's Individual Entrepreneur registered in Georgia. Single-purpose: present the legal entity and accept contact-form submissions.

## Rule of thumb for this file
**Same confidentiality bar as the rendered HTML.** If a fact isn't on the public page, it doesn't belong here. Sensitive operational details (banking, registration number, tax-regime reasoning) live in the user's private memory, not in the repo.

## Hard rules

- **Never use the words "consulting" or "advisory"** anywhere on the site or in invoicing copy. Frame work as "services", "engineering", "implementation". This is for tax-classification reasons; ask the user before deviating.
- **Never commit `.env`** or any real credential. Production secrets come from Forgejo secrets at deploy time.
- **Don't write Claude Code as co-author on commits.** (User-global preference.)
- **Don't write commits at all unless asked.** (User-global preference.)

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
- In-memory `RateLimit` (5 req/hour/IP) — see `lib/rate_limit.rb`
- `Rack::Protection::AuthenticityToken` for CSRF (uses session-stored token)
- Honeypot field named `website` for spam
- Static assets in `public/`; views in `views/`
- Deploy: `Dockerfile` + `docker-compose.yml` (Traefik labels for asxp.io / www.asxp.io)
- Dev shell: `flake.nix` (Ruby 3.4, bundler, openssl, zlib, libyaml). Run `nix develop`.

The patterns mirror `~/Code/projects/narayana/www`. Use that repo as a reference for conventions (middleware, helpers, dotenv pattern) — but don't pull in narayana-specific things this site doesn't need (no Redis, no i18n, no Prawn, no API client).

## Contact form behavior

`POST /contact` does, in order:
1. Honeypot check — if `website` field non-empty, silently 302 to `/thanks`.
2. Validate name, email, subject, message.
3. Rate-limit by client IP.
4. `Mailer.notify_owner` → message to `MAIL_TO` (`ie@asxp.io`), `Reply-To: <visitor email>`.
5. `Mailer.confirm_visitor` → receipt to visitor, `Reply-To: ie@asxp.io`. Failure here is logged but not surfaced to the user.

`MAIL_FROM` must use a Fastmail-verified send-as address (currently `me@asxp.io`). The friendly name reads "IE Sergei Poljanski Contact Form".

## Operational notes

- `client_ip` reads `X-Forwarded-For` first (Traefik sets it), falling back to `X-Real-IP` and `REMOTE_ADDR`.
- The rate limiter resets on app restart — acceptable for one-process deploys.
- If the Ruby process is down, the site is down. There's no static fallback. (Trade-off accepted for the contact form.)

## SSH key comment caveat

`public/id_ed25519.pub` is served from the site. The comment field (currently `ie+2026@asxp.io`) is part of the key file itself; editing the website without regenerating the key file means the website and the file disagree. Keep them in sync, or regenerate the key.

## Logo placeholder

The header monogram in `views/index.erb` (inline SVG, "SP" in Hack monospace on a 56×56 dark-grey square) is a **placeholder** awaiting a real logo from a designer friend. When the real logo arrives, swap in this order:

1. **Drop the asset** into `public/` (e.g. `public/logo.svg` — prefer SVG; PNG fallback if needed).
2. **Header in `views/index.erb`** — replace the entire `<div class="monogram">…</div>` block with `<img src="/logo.svg" alt="IE Sergei Poljanski" class="monogram" />`. The `.monogram` CSS class in `public/style.css` (centered, `margin-bottom: 14px`) handles layout — adjust `width`/`height` on the `<img>` if the new logo's proportions differ.
3. **Favicons** — replace or supplement `public/hedgehog.png`. The `<link rel="icon">` and `<link rel="apple-touch-icon">` in `views/layout.erb` point at `/hedgehog.png`; update both. Ideally provide 32×32 (favicon) and 180×180 (apple-touch).
4. **Open Graph image** — currently absent (Twitter Card type is `summary`, no thumbnail). Add `public/og-card.png` (1200×630, logo + entity name on dark `#121212`), then in `views/layout.erb` add `<meta property="og:image" content="https://asxp.io/og-card.png" />` and change `<meta name="twitter:card" content="summary" />` to `summary_large_image`.

The hedgehog is the user's pre-IE personal mark; once the IE has its own logo, the hedgehog can stay as-is for old-time's sake or be retired. Ask before retiring it.

## Common tasks

- **Generate a new SESSION_SECRET:** `openssl rand -hex 64` (then update Forgejo secret).
- **Local dev:** `nix develop`, then `bundle exec rerun -- rackup -p 3000`. Visit `http://localhost:3000`.
- **Local image build (sanity check):** `docker compose build`
- **Production deploy:** automatic via `.forgejo/workflows/deploy.yaml` on push to `main`. Pipeline:
  1. Kaniko builds the image and pushes it to the Forgejo registry.
  2. SSH copies `docker-compose.yml` to the deploy directory on the prod host.
  3. SSH writes `.env` (mode 600) from Forgejo secrets — `SESSION_SECRET` and `SMTP_PASSWORD` are interpolated; non-secret config is hardcoded in the workflow.
  4. SSH `sed`-substitutes the image tag in `docker-compose.yml` and runs `docker compose up -d`.

## Where the secrets live

| Forgejo secret    | Use                                 | Rotate by         |
|-------------------|-------------------------------------|-------------------|
| `SESSION_SECRET`  | Rack session cookie HMAC            | Update secret + push (or re-run last deploy). All sessions invalidated; nobody is logged in to this site so no user impact. |
| `SMTP_PASSWORD`   | Fastmail app password               | Generate new app password in Fastmail → update secret → push. |
| `DEPLOY_IP/USER/SSH_KEY` | SSH to prod from CI            | Standard SSH key rotation. |
| `FORGEJO_REGISTRY/USER/TOKEN` | Kaniko registry auth        | Forgejo token rotation. |

**Non-secret config that lives in the workflow** (not in `.env.example`, not in secrets): `SMTP_ADDR`, `SMTP_PORT`, `SMTP_USER`, `MAIL_FROM`, `MAIL_TO`. Change these by editing `.forgejo/workflows/deploy.yaml`.

## What `.env.example` is for

Local development only. Copy to `.env`, fill in dummy/test SMTP creds (or real ones if you want to actually send) and a throwaway `SESSION_SECRET`. The Nix dev shell sources `.env` automatically. **Production never reads `.env.example` and never has a stale `.env`** — every deploy regenerates it.
