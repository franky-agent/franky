# Managing software specifications over time: applied research

Captured 2026-04-29. Synthesized from IETF, W3C/WHATWG, Python PEPs, Rust RFCs,
Kubernetes KEPs, the Linux kernel ABI conventions, ADR practice, and modern
spec-driven-development writing. Intended as the durable reference behind doc
decisions in this repo.

## 1. Headline principles

1. **Removal-from-text is the rare case; obsolescence-in-place is the default.** Every mature spec process surveyed (RFCs, PEPs, ADRs, KEPs, Linux ABI, HTML LS) keeps the text addressable; what changes is the *status* attached to it.
2. **Status is metadata, not deletion.** A status field with a fixed vocabulary (`Final` / `Superseded` / `Withdrawn` / `Removed`) and a *reciprocal* pointer (`Replaces` ↔ `Superseded-By`) is the universal pattern.
3. **Frozen documents are immutable; living documents have no version.** Mixing the two — "this section is frozen but we'll edit it later" — is what produces dead anchors and rotten cross-references.
4. **A spec answers "what is true now?"; a changelog answers "what changed?"; a rationale doc answers "why?".** Conflating two of these into one document is the mechanism by which specs bloat into living changelogs.
5. **Cross-references survive when they target stable identifiers, not prose.** Section numbers, RFC numbers, KEP numbers, ADR numbers — never "the section about X."
6. **A removed feature becomes a tombstone, not a hole.** Either a one-line stub with a forward pointer, or kept-in-place with `status: removed` — but never a missing anchor that source code or other docs reference.
7. **Append-only history goes in a separate stream from the spec.** ADRs, RFCs, and PEPs are append-only because they're decisions; the *spec they produced* is editable. Don't make your spec append-only.
8. **A two-way reachability invariant is non-negotiable.** From the old name you can find the new one; from the new one you can find what it replaced. If either direction breaks, citation rots.

## 2. When to remove vs archive vs mark-in-place

The decision rule that emerges across projects, ordered by what the text needs to support:

**Mark in place (status change, text unchanged)** when external references exist. The Linux kernel formalizes this: an interface "cannot be removed from the kernel tree without going through the obsolete state first." Python PEPs follow the same rule — once a PEP reaches `Final`, `Rejected`, or `Superseded`, it is "considered a historical document rather than a living specification" and is not substantially modified. Rust RFC 1201 was marked superseded by adding a banner — `"⚠ This RFC has been superseded by RFC 2972 ⚠"` — at the top of the existing file rather than moving or deleting it. The HTML Living Standard does this at section granularity: `applet`, `marquee`, `frame` all live in §16 with explicit replacement pointers, never deleted.

**Move to archive (with redirect stub)** when the section is large, no longer informative for current behavior, *and* you've broken external citations of it. Linux distinguishes `Documentation/ABI/obsolete/` (still in tree, will be removed) from `Documentation/ABI/removed/` (a list of things gone, with one-line entries citing the original definition file). The pattern is: removed entries are *abbreviated* but not vaporized — they retain enough text to disambiguate.

**Hard-delete** essentially never. PEPs are not deleted; rust-lang/rfcs preserves text of complete and inactive RFCs; the RFC Editor is explicit that "once published, RFC Series documents are not changed." The DOI tombstone-page convention codifies this for citation systems: if a record is withdrawn, the URL still resolves to a tombstone page describing what it was.

**The decision rule**, stated tightly:

> Remove only if (a) nothing — source code, other specs, papers, issue threads — *cites* the section by anchor or number, AND (b) the content is purely transient (a planning note, not a normative claim). Otherwise demote to a status-marked stub. When in doubt, mark in place; the cost of a kept paragraph is bytes, the cost of a broken citation is reader confusion forever.

## 3. Cross-reference patterns that hold up over time

**Patterns that work:**

- **Reciprocal headers with stable IDs.** PEP's `Replaces:`/`Superseded-By:` and KEP's `superseded-by:` produce two-way reachability. From either document you can find the other.
- **Banner-at-top supersession notices.** Rust's `⚠ superseded by RFC 2972 ⚠` is a one-line edit to a frozen document — minimal mutation, high signal. Critically, the banner is at the *top* so it's seen before any of the now-stale body.
- **Anchored section numbers, not titles.** RFC 7322 mandates `Updates: nnnn` headers and citation by RFC number specifically because titles change but numbers don't. Your code's `§Q` references have this property — `§Q` is a stable label even if the section heading changes.
- **Tombstone entries with one-line forward pointer.** Ansible's runtime.yml encodes this as data: `tombstone: { removal_version: 2.0.0, warning_text: "Use foo.bar.new_cloud instead." }`. Linux ABI/removed similarly carries a one-line "Defined on file X" link to the original definition.
- **Hyperlinked replacement-suggestions.** HTML LS's obsolete features each say "use `<embed>` or `<object>` instead" with an actual hyperlink to the modern replacement.

**Patterns that rot:**

- **"See above" / "as discussed earlier."** Survives until the document is restructured, then becomes a dangling phrase.
- **Full-text quotation of the old definition inside the new doc.** Doubles maintenance; the two copies drift; readers don't know which is current.
- **Soft pointers in prose ("the old behavior was X").** Without a stable anchor, these become unverifiable archeology after the next two refactors.
- **Pointers to issue-tracker discussions.** Rust internals have noted this exact failure mode: "it is impossible to tell from reading an accepted RFC whether it was implemented or stabilised, and if it was, whether the implementation matched the RFC." PR/issue links rot — they go private, get renumbered when repos move, and discussions get squashed.
- **Citations by section title rather than number.** `"see the OAuth section"` breaks when you rename the section; `"see §Q"` doesn't.

A *good* deprecation pointer has four properties: top-of-document placement, a stable target ID (number, not title), a reason in one sentence, and a forward link if a replacement exists. The Rust banner and the Linux ABI obsolete files both have all four.

## 4. Keeping specs small and accurate: the discipline

The cleanest separation in mature processes is a three-stream model:

- **Spec** = present-tense normative claims about what is true now. ("The `read` tool refuses files >256 KiB without an explicit limit.")
- **Rationale / decision record** = why we made the choice. (ADRs, decided design docs.)
- **Changelog** = what changed and when. (Per-release notes, separate file.)

Conflating these is *the* mechanism of bloat. The Cognitect/Nygard rule for ADRs is unambiguous: an ADR captures Context + Decision + Consequences, and "if a decision is reversed, we will keep the old one around, but mark it as superseded" — meaning **the decision record is append-only, but the spec it produces is not**. The spec gets edited in place; the decision log accumulates.

OpenSpec's spec-driven-development variant recently formalized this distinction: design notes "live in their own folders... rather than being embedded in or attached to spec documents. This only works with discipline. The change must close." The default OpenSpec schema discards `design.md` once the change ships and only carries `specs.md` forward.

The Keep a Changelog spec is similarly explicit about the boundary: "the purpose of a commit is to document a step in the evolution of the source code, while the purpose of a changelog entry is to document the noteworthy difference... to communicate them clearly to end users." Different audience, different document.

**Practical disciplines that keep a spec small:**

1. **Move "what shipped in vX.Y.Z" prose out of the spec body.** Either to a `CHANGELOG.md` keyed by version, or to a per-release section that's *clearly partitioned* and skippable. Diátaxis treats reference material as map-of-territory: it should reflect the structure of the thing, not the history of how the thing got there.
2. **Status fields, not status prose.** "❌ removed in v1.30.0" as a row-level marker beats a paragraph saying "this used to work, then in v1.28 we tried X, then in v1.30 we removed it."
3. **Aggressively factor rationale into linked design docs.** When rationale shows up inline, the spec answers two questions at once and does both poorly.
4. **Truncate-and-link, don't elaborate-in-place.** A removed-feature stub of 3 lines + a link to `docs/archive/Q-oauth.md` keeps the spec dense.

## 5. Versioned snapshots vs living document trade-offs

The two strongest cases on opposite ends:

**WHATWG / HTML Living Standard (no versions):** "you end up following something that is *known to be wrong*. That's obviously not the way to get interoperability!" Their argument is that frozen snapshots fossilize bugs because implementers grab the snapshot, not the editor's draft. They handle "what changed when" via Git history, GitHub commit logs, and a public change feed — versioning is replaced by an audit log.

**IETF RFCs (strict immutable snapshots):** Once published, an RFC is never edited. Subsequent RFCs declare `Updates: nnnn` or `Obsoletes: nnnn` headers; readers chain forward through these to find current truth. The benefit is citability — academic papers and standards from 1985 still cite RFC 822 and that citation still resolves to exactly the bytes the author saw.

**The actual trade-off, stated as decision criteria:**

| If your spec is... | Use... | Because... |
|---|---|---|
| Cited by external systems / papers / regulations | Versioned snapshots (RFC model) | Citations need exact bytes, forever |
| Implemented by many independent parties who must interoperate | Living standard with public change feed (WHATWG model) | Stale snapshots → bug-compatible implementations |
| Implemented by one team that controls all consumers | Living document with status markers | No external citation pressure; lowest friction |
| A mix (some external API, some internal) | Living document for current truth + per-release changelog + frozen design-decision archive | Each audience reads the right surface |

Most software-project specs (including franky's) are the bottom-two cases. The middle "living + status markers" pattern is what's worked best in practice — it's what HTML LS, Kubernetes API docs, and most modern open-source spec processes converge on.

A subtle point: "frozen v0 + living v1" is *not* the WHATWG model and *not* the RFC model — it's the **Python standard library deprecation cycle**. The current docs describe Python 3.x; old behavior lives in archived `Whatsnew` documents and the deprecated/removed-features sections. That's a reasonable hybrid and it's industry-standard.

## 6. Application to franky

**Your three-file structure (`v0.md` frozen, `v1.md` living, `v2.md` open backlog) is sound** and matches the Python+ADR hybrid pattern more than any other industry shape. The append-only `v0.md` is the equivalent of an archived Whatsnew doc; `v2.md` is your KEP-style proposal queue; `v1.md` is the living reference. Don't change this.

**The "keep §Q in place, mark rows ❌ removed" call was the right one** by the dominant industry pattern. Linux ABI, HTML LS, PEPs, and Rust RFCs all do exactly this. The reasoning "no precedent for deletion-style deprecation" is also the reasoning Linux uses verbatim ("interfaces cannot be removed from the kernel tree without going through the obsolete state first"). However — consider adding a one-line **banner at the top of §Q** in the rust-lang/rfcs style: `"⚠ Removed in v1.30.0. Retained as historical reference; see CHANGELOG entry for v1.30.0."` That single line transforms §Q from "current spec section" to "history" for any reader who lands directly via a `§Q` link in source code. Right now, source-code references to §Q point at content readers will mistake for current behavior.

**For source-code `§Q` cross-references staying alive**, the discipline that keeps these from rotting is mechanical, not procedural: a CI check that greps source for `§[A-Z]\w*` and the v1.md anchor list and fails if any code references a missing anchor. You already have the tools (Zig + ripgrep + a build hook). This is the *only* mechanism I've seen that actually works at scale — every other approach (style guides, code review) eventually misses one and the rot starts. As a one-time hardening step, also have the check verify that any `❌ removed` row's section heading still exists, so removing a section becomes a deliberate two-step (delete the row + update the anchor check).

**On the inline "what shipped in vX.Y.Z" log being interleaved with the spec — this is the place I'd push back hardest.** Industry consensus is unambiguous: spec answers "what is true now," changelog answers "what changed." Your v1.md currently mixes both, and it's already at ~2,900 lines with a per-version log that grows monotonically — this is the canonical bloat shape. Two concrete moves:

1. **Extract the "What shipped in v1.x" log into `CHANGELOG.md`** at the repo root, in Keep-a-Changelog format. Cross-link from each v1.md anchor that has changelog history. This alone will probably halve v1.md's growth rate.
2. **Keep the per-feature status markers** (✅ / ❌ removed in v1.30.0) inline in the implementation table — that's spec metadata, not changelog. The version reference is fine; the *prose explaining what happened* belongs in the changelog.

The CLAUDE.md narrative paragraph about v1.27 / v1.28 / v1.29 in particular reads like a changelog that escaped containment — it's useful context but it doesn't belong in the same document that source code cites by `§` anchor. Move it to `CHANGELOG.md`, leave `CLAUDE.md` with a "current state" snapshot and a pointer.

**One additional pattern worth adopting from KEPs**: a per-section "Status: Final | Superseded | Removed" line under each section heading in v1.md. Right now status is tracked at row-level in the implementation table; promoting it to section-level means a reader who lands at §Q via a code reference sees the status before they read a single normative claim. This is the cheapest possible defense against stale-anchor confusion, and it matches what every mature spec process (PEP, KEP, ADR) does.

---

## Sources

- [RFC 7322 — RFC Style Guide](https://www.rfc-editor.org/rfc/rfc7322.html)
- [RFC 9280 — RFC Editor Model (Version 3)](https://www.rfc-editor.org/info/rfc9280)
- [WHATWG HTML FAQ — Living Standard rationale](https://github.com/whatwg/html/blob/main/FAQ.md)
- [HTML Living Standard §16 — Obsolete features](https://html.spec.whatwg.org/multipage/obsolete.html)
- [PEP 1 — PEP Purpose and Guidelines](https://peps.python.org/pep-0001/)
- [rust-lang/rfcs README — process and inactive folder](https://github.com/rust-lang/rfcs)
- [Linux Kernel ABI README — stable / testing / obsolete / removed](https://www.kernel.org/doc/Documentation/ABI/README)
- [Kubernetes Deprecation Policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/)
- [Kubernetes KEP Process](https://github.com/kubernetes/enhancements/blob/master/keps/sig-architecture/0000-kep-process/README.md)
- [Michael Nygard — Documenting Architecture Decisions](https://www.cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
- [Diátaxis framework](https://diataxis.fr/)
- [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
- [Common Changelog](https://common-changelog.org/)
- [Ansible — Module lifecycle and tombstones](https://docs.ansible.com/projects/ansible/latest/dev_guide/module_lifecycle.html)
- [DataCite — Tombstone page best practices](https://support.datacite.org/docs/tombstone-pages)
