# Exactly one runtime gem, and it is not up for renegotiation: Ruby has no MIME
# parser in stdlib, and hand-cutting on `boundary` breaks on the first newsletter
# that nests multipart/related inside multipart/alternative. `mail` is pure Ruby,
# so packaging it stays boring.
#
# Everything else — Atom generation included — is stdlib. Minitest ships with the
# interpreter, so it is not a dependency here.
source "https://rubygems.org"

gem "mail", "~> 2.8"
