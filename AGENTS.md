# Delivery discipline

These rules apply to every change that will be committed or proposed for review.

- Keep the pull request title and description current as work changes. Update the description with each meaningful commit or scope change; before merging, verify that it accurately describes the complete result, its user-facing or engineering rationale, and verification performed.
- Treat the README as part of the release surface. Before merging a behavior-changing pull request, review its overview and feature list and update them when the shipped product has changed.
- Write commit messages and pull-request descriptions that explain both **what** changed and **why** it changed. Use a concise imperative subject for commits, then include a body when the rationale is not already unmistakable from the subject. Do not leave non-obvious safety, performance, UX, or data-integrity decisions implicit.
