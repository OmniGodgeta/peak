# Security policy

## Reporting a vulnerability

**Do not open a public issue for security problems.**

Email **security@shadowchat.example** (placeholder — set a real address before public
launch) with:

- a description of the issue and its impact,
- steps to reproduce or a proof of concept,
- affected component/version/commit.

We aim to acknowledge within 72 hours and to ship a fix or mitigation on a timeline
proportional to severity. We'll credit you in the release notes unless you'd rather stay
anonymous. We won't pursue legal action for good-faith research that respects user
privacy and doesn't degrade the service.

A [security.txt](https://securitytxt.org/) will be published at `/.well-known/security.txt`.

## Scope

In scope: the app, the Supabase schema and RLS policies, Edge Functions, the media
pipeline, auth flows, the E2E messaging implementation, the federation endpoints, and the
reference instance.

Out of scope: third-party services (Supabase, Stripe, FCM/APNs) themselves — report those
to the vendor; denial-of-service testing against the reference instance; social
engineering of staff or users.

## Security model summary

- **Authorization** is enforced in Postgres via Row-Level Security, deny-by-default, on
  every table. The app cannot grant itself access the policies don't allow.
- **DMs** are end-to-end encrypted (MLS, RFC 9420) from Phase 2.5. The server stores
  ciphertext and minimal routing metadata; it never holds group keys.
- **Secrets** live only in Supabase Vault, read only by Edge Functions. None in the
  client, none in the database rows, none in logs.
- **Media** is stripped of EXIF/GPS on upload; delivery URLs are signed and short-lived.
- **Tokens** are stored in the platform secure enclave (Keychain / Keystore).
- **Dependencies** are pinned; a CI denylist blocks analytics/ad/tracking SDKs; Dependabot
  (or equivalent) watches for advisories.
- **Retention**: data has documented lifetimes; deletion propagates to backups within the
  stated window.

## Hardening checklist for security-sensitive PRs

- [ ] New tables have RLS enabled and a deny-by-default policy
- [ ] Each policy has a test proving it allows the intended case and denies others
- [ ] No secret is read in the client or written to a log
- [ ] User-supplied identifiers are not trusted for authorization (claims come from the JWT)
- [ ] Media inputs are size- and type-checked and re-encoded server-side
- [ ] Rate limits considered for any new unauthenticated or cheap-to-abuse endpoint
- [ ] Threat-model note included for auth / crypto / payments / federation changes
