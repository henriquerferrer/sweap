# Working in this repo

## This repo is public: name no private project or person

sweap is developed against private projects and used by real people. None of them may be named anywhere that ships from this repo:

- files: `plugin/`, `scripts/`, `docs/`, `roadmap/`, tests and fixtures
- commit messages, branch names
- pull request and issue titles, bodies and comments, release notes

Write the generic form instead:

- Projects that run sweap are **consumer A, B and C**. A consumer's PR is "consumer A PR 403", with no `#`, because `#403` links to this repo's own PR 403.
- People are described by role ("the maintainer", "a tester"), never by name.
- Paths start at `~/`, never at a home directory such as `/Users/<name>/`.

Don't document which consumer is which, here or anywhere in the repo. That mapping stays private.

The same goes for screenshots, recordings, logs and transcripts pasted into docs or PRs: check them for names, repo slugs and paths before they go in.

### The guard

`scripts/no-private-names.sh` runs before every Bash call (see `.claude/settings.json`). It denies a `git push` or a writing `gh` call (`gh pr`, `gh issue`, `gh api`, `gh release`) when the pushed diffs, the commit messages, the command line or a `--body-file` matches a name. The names live outside the repo, one extended regex per line, in `~/.config/sweap/private-names` (override with `SWEAP_PRIVATE_NAMES`). If that file is missing or empty, the guard denies everything it checks.

When it denies, reword the text to the generic form and retry. Never bypass it, and never add the names to the repo to "fix" it. The guard only catches names on its list, so you still have to check text yourself.
