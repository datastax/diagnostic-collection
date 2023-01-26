# Contributing guidelines


## Commits

Keep your changes **focused**. Each commit should have a single, clear purpose expressed in its 
message.

Resist the urge to "fix" cosmetic issues (add/remove blank lines, move methods, etc.) in existing
code. This adds cognitive load for reviewers, who have to figure out which changes are relevant to
the actual issue. If you see legitimate issues, like typos, address them in a separate commit (it's
fine to group multiple typo fixes in a single commit).

Commit message subjects start with a capital letter, use the imperative form and do **not** end
with a period.

Avoid catch-all messages like "Minor cleanup", "Various fixes", etc. They don't provide any useful
information to reviewers, and might be a sign that your commit contains unrelated changes.
 
We don't enforce a particular subject line length limit, but try to keep it short.

You can add more details after the subject line, separated by a blank line.

```
One line description of your change
 
Optional longer description.
```

## Pull requests

Like commits, pull requests should be focused on a single, clearly stated goal.

Contributors need to sign the [DataStax CLA](https://cla.datastax.com/).
