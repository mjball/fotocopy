# Delivery discipline

These rules apply to every change that will be committed or proposed for review.

- Keep the pull request title and description current as work changes. Update the description with each meaningful commit or scope change; before merging, verify that it accurately describes the complete result, its user-facing or engineering rationale, and verification performed.
- Treat the README as part of the release surface. Before merging a behavior-changing pull request, review its overview and feature list and update them when the shipped product has changed.
- Write commit messages and pull-request descriptions that explain both **what** changed and **why** it changed. Use a concise imperative subject for commits, then include a body when the rationale is not already unmistakable from the subject. Do not leave non-obvious safety, performance, UX, or data-integrity decisions implicit.

# Completion and shipping

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
retaining macOS's three-component bundle version format. Do not adopt
Chrome's four-component build identifiers for app bundle versions.

For a user-requested product behavior change, presume the request is to ship it
unless the user explicitly limits the scope to planning, diagnosis, review, or
an unshipped patch. Do not call the work complete at an intermediate milestone
such as implementation, testing, opening a pull request, or merging it.

Complete the applicable delivery sequence without waiting for prompts between
steps:

- run the relevant tests and the temporary release-build verification;
- update release-facing documentation, commit on a `codex/` branch, open and
  self-review a pull request, then merge it when clean;
- publish a GitHub release with user-visible release notes, choosing its
  version according to the milestone policy above;
- install the published release into `/Applications/Fotocopy.app` and verify
  its version, code signature, and launch state.

Report completion only after that sequence is finished. State explicitly when a
step is genuinely inapplicable, unavailable, or requires a user choice.
