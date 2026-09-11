# Change work

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
