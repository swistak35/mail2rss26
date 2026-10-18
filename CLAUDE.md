# CLAUDE.md

## Start here: the plan lives outside this repository

The plan — settled decisions and why, open questions, phase-by-phase TODOs — is an
org-mode file (Polish) in Rafał's notes repository:

```
$NOTES_DIR/projects-mail2rss26.org
```

(`~/Dropbox/notes` on the workstation, `/home/dev/repos/notes-private` on Rivendell.)
Read it through the `status-projektu` skill — `/status-projektu odczyt mail2rss26` —
which brings the notes up to date first. It is large, so read it by subtree
(`grep -n '^\*'`, then the heading you need).

When the work is done, `/status-projektu zapis mail2rss26`: it rewrites "Stan na
[data]", marks TODOs DONE, adds new ones, and commits and pushes only the plan file to
the notes' master, from a worktree of its own. That push needs no asking.

## Agent skills

### Issue tracker

No tracker in this repository: tickets are TODO headings in `$NOTES_DIR/projects-mail2rss26.org`, written through `/status-projektu`. See `docs/agents/issue-tracker.md`.
