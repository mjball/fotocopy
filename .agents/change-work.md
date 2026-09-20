# Change work

Every completed task that modifies repository files must be committed on a
`codex/` branch, pushed, opened as a pull request, self-reviewed, and merged
when clean. This applies to app changes, tests, documentation, and repository
instructions. Never report work complete while requested changes exist only in
the local working tree. Planning, diagnosis, and review tasks that do not
modify files are exempt.

For a pull request that changes the Fotocopy app itself (its source code or
user-visible behavior), ask the user before modifying files, committing,
pushing, or opening the pull request whether it should include the release
steps: publishing a GitHub release and freshly installing the app in
`/Applications/Fotocopy.app`. Ask once per pull request unless its scope
materially changes. State that **yes is the default**; a user may explicitly
decline those release steps. A **no** answer opts out only of publishing the
GitHub release and installing the app; it never opts out of committing,
opening, self-reviewing, and merging the pull request. Do not ask for
documentation-only, instruction-only, planning, diagnosis, or review work.

For a user-requested product behavior change, presume the request is to ship it
unless the user explicitly limits the scope to planning, diagnosis, review, or
declines the release steps when asked. Whether or not release steps are
included, do not call the work complete at an intermediate milestone such as
implementation, testing, or opening a pull request. Merging the pull request is
the minimum completion point for any task that modified repository files.

Run the relevant tests and the temporary release-build verification. For a
shipped product behavior change, read `.agents/release-delivery.md` and
complete its applicable delivery sequence without waiting for prompts between
steps.

Report completion only after the applicable work is finished. State explicitly
when a step is genuinely inapplicable, unavailable, or requires a user choice.
