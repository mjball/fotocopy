# Release delivery

## Pull requests and documentation

- Keep the pull request title and description current after each meaningful
  scope or implementation change. Before merging, verify that it describes the
  complete result, its user-facing or engineering rationale, and verification.
- Before merging a behavior-changing pull request, review the README overview
  and feature list. Update them when they no longer describe the shipped
  product.
- Explain both **what** and **why** in commits and pull requests. Use a concise
  imperative commit subject, then add a body when the rationale is not already
  unmistakable. State non-obvious safety, performance, UX, or data-integrity
  decisions explicitly.

## Release versioning

Fotocopy uses Chrome-style milestone versioning rather than Semantic Versioning.
Tags and app bundles use `vM.0.R`, where `M` is the curated product milestone
and `R` is a release revision within that milestone.

- Start each new curated milestone at `vM.0.0`. A milestone represents a
  coherent, user-facing product release; it is not a compatibility promise and
  is not determined by whether a change is breaking.
- Increment `R` (`v1.0.0` to `v1.0.1`) for fixes, regression recoveries, and
  other follow-up releases in the current milestone. Ship urgent fixes without
  waiting for the next milestone.
- Increment `M` (`v1.0.2` to `v2.0.0`) only when a meaningful set of
  user-facing improvements merits the next curated release. Do not use version
  numbers merely as a counter for merged pull requests.
- The `1.0.0` milestone marks Fotocopy's first stable curated product release;
  it does not create a SemVer API or data-format compatibility commitment.

This deliberately borrows Chrome's milestone-and-revision release model while
retaining macOS's three-component bundle version format. Do not adopt Chrome's
four-component build identifiers for app bundle versions.

## Shipping sequence

For a shipped product behavior change:

- update release-facing documentation, commit on a `codex/` branch, open and
  self-review a pull request, then merge it when clean;
- publish a GitHub release with user-visible release notes, choosing its
  version according to the milestone policy above;
- install the published release into `/Applications/Fotocopy.app` and verify
  its version, code signature, and launch state.
