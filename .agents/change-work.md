# Change work

For a pull request that changes the Fotocopy app itself (its source code or
user-visible behavior), ask the user before modifying files, committing,
pushing, or opening the pull request whether it should include the release
steps: publishing a GitHub release and freshly installing the app in
`/Applications/Fotocopy.app`. Ask once per pull request unless its scope
materially changes. State that **yes is the default**; a user may explicitly
choose an unshipped patch instead. Do not ask for documentation-only,
instruction-only, planning, diagnosis, or review work.

For a user-requested product behavior change, presume the request is to ship it
unless the user explicitly limits the scope to planning, diagnosis, review, or
an unshipped patch. Do not call the work complete at an intermediate milestone
such as implementation, testing, opening a pull request, or merging it.

Run the relevant tests and the temporary release-build verification. For a
shipped product behavior change, read `.agents/release-delivery.md` and
complete its applicable delivery sequence without waiting for prompts between
steps.

Report completion only after the applicable work is finished. State explicitly
when a step is genuinely inapplicable, unavailable, or requires a user choice.
