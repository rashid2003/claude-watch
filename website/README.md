# Session Watch website

Static site: no build step, no framework. `index.html`, `pricing.html`, `thanks.html`, `privacy.html` plus `assets/`.

## Deploy (Cloudflare Pages)

```sh
npx wrangler pages deploy website --project-name sessionwatch
```

Then add the custom domain `sessionwatch.lajward.co` to the Pages project (the lajward.co zone is already on Cloudflare).

## Wiring

- **Billing API**: `assets/billing.js` talks to `https://billing.sessionwatch.lajward.co` (the worker in `../billing/`). Override by setting `window.SW_CONFIG = { BILLING_API: "..." }` before the script tag.
- The billing worker's `SITE_ORIGIN` must be this site's origin — its checkout success URL is `/thanks` and cancel URL is `/pricing` (Cloudflare Pages serves `thanks.html` at `/thanks`).

## Placeholders to fill before launch

- **Mac download**: the button links to the GitHub releases page. Publish `SessionWatch-<version>.dmg` (from `scripts/release-mac.sh`) as a GitHub release, or swap in a direct URL.
- **TestFlight**: `pricing`/install page button (`id="testflight-link"` in `index.html`) points at the repo README until a public TestFlight link exists.
- **Homebrew cask**: shown as "coming soon".
- **Contact email**: `hello@lajward.dev` everywhere — change if another address is preferred.

## Design

Matches the app (iOS `Theme.swift`): monospace everything (JetBrains Mono standing in for SF Mono), dark `#121212`, clay `#D97757`, status green/yellow/red, lowercase chrome, Claude CLI glyphs (`· ✢ ✳ ✶ ✻ ✽`). The buddy in `assets/buddy.js` is rebuilt in SVG from `Sources/WatchProtocol/BuddyArt.swift` — Blobby, Pixel and Bolt, five moods.
