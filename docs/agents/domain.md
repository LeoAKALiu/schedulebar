# Domain Docs

How engineering skills consume this repository’s domain documentation.

## Before exploring, read these

- `CONTEXT.md` at the repository root.
- `docs/adr/` entries that affect the area being changed.

If these files do not yet exist, proceed silently. `/domain-modeling`, `/grill-with-docs`, or architecture work creates them lazily when terminology or durable decisions are resolved.

## File structure

This is a single-context repository:

```
/
├── CONTEXT.md
├── docs/adr/
└── src/
```

## Use the glossary’s vocabulary

When issues, tests, specifications, or code name a domain concept, use the term defined in `CONTEXT.md`. Do not drift to rejected synonyms.

If a required concept is absent, reconsider whether the new term is necessary or record the gap for `/domain-modeling`.

## Flag ADR conflicts

If proposed work contradicts an existing ADR, surface the conflict explicitly rather than silently overriding the decision.
