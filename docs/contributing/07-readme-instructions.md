# README conventions

The root `README.md` is the front door. It tells someone what pltfctl is, how to run it, and
where everything else lives. Any change to it should follow the conventions below.

## Layout, top to bottom

1. **Title.** `# pltfctl`. This is the only H1, and every "back to top" link points to its
   anchor (`#pltfctl`).
2. **Banner.** A centered single-row HTML table of icons (see [Banner](#banner)).
3. **Pitch.** One paragraph: what it is, what it stands up, and the one-command up/down
   promise. It has no heading.
4. **Divider.** A line of exactly 50 dashes (`-----…`).
5. **Contents.** `## Contents`, a bulleted list linking to every `##` section in order.
6. **Body sections.** Each is a `##` section followed by `[back to top](#pltfctl)` and a
   divider.
7. **`## What are some references?`** External links grouped under `###` subheadings (Build
   and Packaging, Infrastructure and Platform, Technology Stack). Format each as
   `- [Name](url): one-line role`.
8. **`## License`.** Always last.

## Section style

- **Name each `##` section as the question a reader would ask**, e.g. "How do I run it?",
  "Which ports does it use?". The exceptions are Contents, License, and short noun headings
  that are already established, such as "Three sizes".
- Answer the question in the first sentence, then give the detail.
- Use plain words and short sentences. Explain a term the first time it appears (for example,
  "distro").
- Put commands in indented or fenced code blocks that can be copied as-is. Show the
  `./scripts/pltfctl` form.
- Use a table for anything with two or more dimensions (ports, CIDRs, distros).
- When you add, rename or remove a section, update **Contents** in the same change.

## What belongs in the README and what doesn't

| Belongs in the README | Goes elsewhere |
| --- | --- |
| What it is, how to run it, what you get | Why a script does something: `scripts/README.md` |
| User-visible ports, URLs, distros | Contributor how-tos: `docs/contributing/` |
| A map of the folders | Background and deep dives: `wiki/` |
| Pointers to deeper docs | Agent orientation: `CLAUDE.md` |

Keep the README generic. pltfctl supplies failure domains, so worked examples for a specific
consumer belong in that consumer's repo.

## Banner

The banner shows the stack at a glance. Icons live in `assets/icons/` and are referenced by
relative path.

- One `<td>` per icon in a single row inside `<div align="center"><table><tr>`.
- Every `<img>` has `height="120"` and an `alt` text. Wrap it in a link to the tool's homepage
  (the CLI icon has no link).
- Order: CLI first, then the tools in the order a user meets them (k3d, Helm, Flux).
- To add an icon: commit a square PNG, at least 256px, to `assets/icons/<tool>.png`, then add
  a cell. Keep the banner to 6 icons or fewer.
- Don't hotlink images from other sites. Commit them to `assets/` so the banner renders
  offline and can't break when the other site changes.

## Checklist before you commit

- [ ] Contents matches the `##` sections exactly, in the same order.
- [ ] Every section ends with `[back to top](#pltfctl)` and a divider.
- [ ] Every relative link and image path resolves.
- [ ] Commands and paths match the current layout (`scripts/`, `infra/`, `deploy/`, `docs/`).
- [ ] No port, CIDR or version appears that disagrees with `infra/k3d/fleet.env` or `.env.sbom`.

---

← Previous: [Things never to change casually](06-invariants.md) · [Index](00-index.md)
