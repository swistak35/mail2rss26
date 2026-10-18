# Issue tracker: the plan in the notes

mail2rss26 has no issue tracker of its own, and GitHub Issues are not used. Tickets are
org-mode TODO headings in the project's plan, in Rafał's notes repository:

    $NOTES_DIR/projects-mail2rss26.org

(`~/Dropbox/notes` on the workstation, `/home/dev/repos/notes-private` on Rivendell.)
The notes repository's own `docs/agents/issue-tracker.md` describes the conventions.

## When a skill says "publish to the issue tracker"

`/status-projektu zapis mail2rss26`: add the TODO headings under the phase they belong
to. The skill edits in a worktree of its own and pushes only the plan file.

## When a skill says "fetch the relevant ticket"

`/status-projektu odczyt mail2rss26`, then find the heading by `:ID:` or title with
`grep -n` and read only that subtree.
