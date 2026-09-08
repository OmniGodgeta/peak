# Open questions

Decisions that shape the product. Resolved ones are at the bottom.

## Blocks Phase 1

1. **Content policy baseline.** We need a written acceptable-use policy for peak.social
   before public sign-ups. Start from an existing open policy (Mastodon server covenant,
   Bluesky community guidelines) and adapt? Who owns the final wording?
2. **`shadow` capacity.** Self-hosting the full Supabase stack (Postgres + GoTrue +
   PostgREST + Realtime + Storage + Studio + Kong) plus media wants ~4 GB RAM and real
   disk. Confirm `shadow` has headroom alongside Jellyfin + arcade-server, or plan a
   dedicated box / VM.
3. **Public reachability.** peak.social needs a domain + TLS + a way in from the public
   internet (Cloudflare Tunnel, Tailscale Funnel, or a plain reverse proxy with a static
   IP). Which? (Tailscale Funnel is already partly set up on `shadow`.)

## Blocks Phase 2 (messaging)

4. **Multi-device.** E2E + multiple devices + history sync is hard. Support multiple
   devices per account at launch, or one active device with QR-linked additions later?

## Blocks Phase 6 (money)

5. **Legal entity & payments.** Is there a company, or is this a personal open-source
   project for now? Payments/payouts need an entity, tax handling, and a jurisdiction.
6. **Funding priority.** Which first: user subscription (Peak+), creator monetization
   fees, or self-host licensing?

## Blocks Phase 7 (federation)

7. **Federation stance.** Full ActivityPub interop with Mastodon/Threads on day one, or a
   controlled allowlist first? Reach vs. moderation load.

## Smaller / deferrable

8. Design language — the mark sets the direction (deep space, electric blue, "Higher
   Together"). Want a fuller design pass now, or ship functional and refine?
9. Native desktop (macOS/Windows/Linux via Flutter) — in scope eventually or never?
10. Public roadmap board (GitHub Projects) and open governance docs now, or later?

---

## Decided (2026-09-08)

| Question | Decision |
|---|---|
| Name | **Peak** — tagline "Higher Together". Mark supplied, used as app icon. |
| Product shape | Hybrid super-app: feed + messaging + communities + discovery |
| Platform | Flutter — iOS + Android + Web (PWA) |
| Backend | Supabase, **self-hosted on `shadow` from day one** |
| Repo | `github.com/OmniGodgeta/peak`, public, AGPL-3.0 |
| Handles | Federation-shaped from the start: `@name@peak.social` (one instance for now) |
| Minimum age | **13**, self-declared via date of birth at sign-up. Under-18 → teen account. Real age verification is a Phase 5 item. |
| DM encryption | Transport-encrypted in Phase 2; **MLS end-to-end in Phase 2.5**, before any public launch |
| Theme | Dark-first (the identity is "deep space"); user theme control in Phase 5 |
