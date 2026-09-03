# KHALA VOICE — Documentation

A voice meeting recording, transcription, and AI summary service. Desktop web / mobile web / PWA.

It splits the Meeting Recorder feature out of `autosquad/sisyphus` into a standalone app,
combining an account / friends / sharing system with the plan and credit system from `devkanban`.

## Reading order

| # | Document | Contents |
|---|---|---|
| 00 | [Setup checklist](00-setup-checklist.md) | **Where the keys go** — start here after deploying |
| 01 | [Overview](01-overview.md) | Product scope, settled decisions, non-goals, terminology |
| 02 | [Architecture](02-architecture.md) | Stack, system layout, repo structure, deployment requirements |
| 03 | [Domain model](03-domain-model.md) | Full context map and schemas |
| 04 | [Recording pipeline](04-pipeline.md) | Recording → upload → transcription → speakers → summary *(ported from sisyphus)* |
| 05 | [Auth & sharing](05-auth-sharing.md) | Accounts, social login, friends, share links, permissions |
| 06 | [Subscriptions & credits](06-billing.md) | Plans, credit ledger, usage metering *(ported from devkanban)* |
| 07 | [Config & admin](07-config-admin.md) | Config resolution order, secrets policy, system admin |
| 08 | [Frontend](08-frontend.md) | Routing, core separation, responsive design, PWA |
| 09 | [API](09-api.md) | REST endpoint specification |
| 10 | [Porting map](10-porting-map.md) | What we take from sisyphus / devkanban, and how |
| 11 | [Roadmap](11-roadmap.md) | Milestones |
| 12 | [Design system](12-design-system.md) | Four themes, component specs *(ported from devkanban)* |
| 13 | [Device testing](13-device-testing.md) | Verification procedure for mobile background recording |
| 14 | [Provenance](14-provenance.md) | **What came from where in sisyphus/devkanban** |

## Principles

1. **Secrets never live in code.** This repo will be published as open source.
   Configuration is resolved strictly in the order `DB → environment variables → none`,
   with no literal defaults in code.
   → [07-config-admin.md](07-config-admin.md)
2. **Business logic stays out of the UI.** Frontend logic lives in `packages/core`
   and the UI is a thin shell on top. How many UIs we ship remains a decision we can change later.
   → [08-frontend.md](08-frontend.md)
3. **No external workflow dependencies.** The S3 presigning and AI summarization that
   sisyphus delegated to n8n are implemented directly inside the app. Prompts are
   version-controlled in the repo as well.
4. **Everything ported keeps its provenance.** Anything taken from sisyphus / devkanban
   is annotated in code comments and in [14-provenance.md](14-provenance.md), down to the
   original path. When the original gets fixed, we must be able to judge whether this
   copy needs the fix too.
5. **Metering always runs.** Actual billing is zero for now, but the credit ledger is
   recorded precisely so that real usage and cost stay visible. Going paid should be a
   matter of flipping a switch.
