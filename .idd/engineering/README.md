# IDD Engineering

Engineering Rules are current durable implementation guardrails owned by this project.

Read `INDEX.md` first. Do not load every rule by default. Use the index for discovery, then read only all Always rules and the Conditional rules that are semantically relevant to the current implementation task.

## Boundary

Use `.idd/intent/` for product behavior, externally observable properties, public/domain/compatibility contracts, product-significant operational constraints, and ADR rationale.

Use `.idd/engineering/` for implementation-only durable constraints used to preserve architecture, consistency, maintainability, or engineering conventions.

Ask:

> Could another implementation completely preserve the product contract and still be forbidden by this rule?

If yes, the constraint usually belongs here.

Engineering Rules are not product intent, Factory state, verification commands, task plans, migration progress, or generated descriptions of current code.

## Discovery and applicability

Applicability is exactly one of:

- `Always`: applies to every implementation change and is mechanically enumerated, not semantically selected.
- `Conditional`: applicability is selected semantically from the human-readable `Applies when` description.

Do not select Conditional rules by filename, keyword, path, extension, glob, project type, embeddings, or similarity score.

## Rule format

Stable IDs use `ENG-NNNN`.

Canonical filenames match:

```text
^ENG-\d{4}\.rule-[a-z0-9][a-z0-9-]*\.md$
```

The first heading must equal the filename stem.

For `Always`, an `Applies when` section is optional and does not alter applicability.

Rule documents are normative. `INDEX.md` is only a compact metadata projection for discovery. INDEX Applicability must match the document.

Operational verification commands belong in `.idd/verification.yaml`.
