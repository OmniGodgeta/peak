# Legal — starter drafts

**These are drafts, not legal advice.** They exist so launch isn't blocked by a
blank page and so the app has something real to link to. Before a public launch:

- Have a lawyer in your operating jurisdiction review all four.
- Fill every `〈bracketed〉` placeholder (entity name, contact address, governing
  law, hosting region).
- Decide the DMCA agent (a real name + address; US requires registration with the
  Copyright Office, ~$6).
- Reconcile with the safety obligations in [../DEPLOY.md](../DEPLOY.md) §6
  (NCMEC/CSAM, EU DSA point of contact, UK AADC, US state age rules).

The app bundles these under `app/assets/legal/` and shows them at
**Me → About → Terms / Privacy / Guidelines**, and onboarding links to Terms +
Privacy before an account is created.

| File | Shown as |
|---|---|
| `TERMS.md` | Terms of Service |
| `PRIVACY.md` | Privacy Policy |
| `COMMUNITY_GUIDELINES.md` | Community Guidelines |
| `DMCA.md` | Copyright / DMCA |

Keep the copies in `docs/legal/` and `app/assets/legal/` in sync (the app build
does not read from `docs/`).
