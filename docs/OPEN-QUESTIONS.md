# Open questions

Decisions that shape the product and haven't been made yet. Grouped by how soon they
block work.

## Blocks Phase 0–1

1. **Brand & scope of the name.** "ShadowChat" reads messaging-first, but the product is a
   hybrid super-app. Keep the name and lean into "chat + more", or treat "Chat" as one
   pillar's label? Any tagline preference?
2. **Reference-instance hosting.** Start on hosted Supabase (fastest), or self-host the
   Supabase stack on the `shadow` box from day one? Recommendation: hosted for Phase 0–3,
   self-host later.
3. **Account model.** Is a handle globally unique across the whole network from day one
   (simpler), or scoped per instance like Mastodon (`@name@instance`) in anticipation of
   federation? Recommendation: per-instance form from the start, single instance for now.
4. **Age gate.** Minimum age 13 (US COPPA line) or 16 (GDPR default)? Teen band behaviour
   is specced; just need the number and whether we do age *verification* or age
   *declaration* at first.
5. **Content policy baseline.** We need a written acceptable-use policy for the reference
   instance before public sign-ups. Who drafts it? Start from an existing open policy
   (e.g. Mastodon covenant, Bluesky community guidelines) and adapt?

## Blocks Phase 2 (messaging / crypto)

6. **MLS implementation.** OpenMLS via FFI is the plan. Acceptable to ship Phase 2
   *without* E2E (transport encryption only) and add MLS in 2.5, or must DMs be E2E from
   first release?
7. **Multi-device.** E2E + multi-device + history sync is hard. Do we support multiple
   devices per account at launch, or one active device with QR-linked additions later?

## Blocks Phase 6 (money)

8. **Legal entity & payments.** Is there a company, or is this a personal open-source
   project for now? Payments/payouts need an entity, tax handling, and a jurisdiction.
9. **Funding model priority.** Which comes first: user subscription (ShadowChat+),
   creator monetization fees, or self-host licensing? Affects what we build in Phase 6.

## Blocks Phase 7 (federation)

10. **Federation stance.** Full ActivityPub interop with Mastodon/Threads, or a more
    controlled federation with an allowlist at first? Trade-off: reach vs. moderation load.

## Smaller / deferrable

11. Design language — do you want a distinct visual identity now, or ship functional and
    restyle later? (A design pass can happen in parallel.)
12. Analytics — confirm: first-party aggregate-only, opt-out honoured, no third-party. Any
    exceptions?
13. Native desktop (macOS/Windows/Linux via Flutter) — in scope eventually or never?
14. Do we want a public roadmap board (GitHub Projects) and open governance docs now?
