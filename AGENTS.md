# Delivery discipline

These rules apply to every change that will be committed or proposed for review.

- Keep the pull request title and description current as work changes. Update the description with each meaningful commit or scope change; before merging, verify that it accurately describes the complete result, its user-facing or engineering rationale, and verification performed.
- Treat the README as part of the release surface. Before merging a behavior-changing pull request, review its overview and feature list and update them when the shipped product has changed.
- Write commit messages and pull-request descriptions that explain both **what** changed and **why** it changed. Use a concise imperative subject for commits, then include a body when the rationale is not already unmistakable from the subject. Do not leave non-obvious safety, performance, UX, or data-integrity decisions implicit.

# Completion and shipping

For a user-requested product behavior change, presume the request is to ship it
unless the user explicitly limits the scope to planning, diagnosis, review, or
an unshipped patch. Do not call the work complete at an intermediate milestone
such as implementation, testing, opening a pull request, or merging it.

Complete the applicable delivery sequence without waiting for prompts between
steps:

- run the relevant tests and the temporary release-build verification;
- update release-facing documentation, commit on a `codex/` branch, open and
  self-review a pull request, then merge it when clean;
- publish a GitHub release with user-visible release notes, using the next patch
  version for a backward-compatible fix unless the change clearly needs a
  different version;
- install the published release into `/Applications/Fotocopy.app` and verify
  its version, code signature, and launch state.

Report completion only after that sequence is finished. State explicitly when a
step is genuinely inapplicable, unavailable, or requires a user choice.
