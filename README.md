# mail2rss26

Newsletters arrive by mail; this turns them into **Atom feeds** you read in an ordinary
feed reader. It is a private "kill-the-newsletter", run on our own machine and maintained
like everything else there — declaratively, with the repository as the source of truth.

The architectural decision everything else follows from: **there is no long-running
process.** OpenSMTPD accepts the message and pipes it into a program that runs once, per
message; the program stores the mail on disk and re-renders `atom.xml`; nginx serves that
file as a static asset. No daemon, no HTTP port of its own, no database, no web panel and
no login. The retry mechanism is OpenSMTPD's queue, which we get by exiting non-zero.

```
   SMTP :25                stdin, once per message              static file
sender ────► OpenSMTPD ──────────────────────────► mail2rss26 ──────────────► nginx ──► reader
                 mda "mail2rss26 ingest              ingest         atom.xml
                      --recipient %{rcpt}"
```

## Status

**Phase 5 of the plan.** `ingest` works end to end against a local directory — recipient →
feed, message stored, feed re-rendered, documented exit codes — and the whole thing is now
packaged: `nix run .#default -- ingest` works from the flake alone, with no dev shell and
nothing on `PATH`. The NixOS module and the `nixosTest` are Phase 6; nothing here has been
deployed yet.

The plan itself — settled decisions and why, open questions, phase-by-phase TODOs — lives
in the personal notes repository rather than here. This repository is the program.

## Commands

```bash
mail2rss26 ingest --recipient ADDRESS [--config PATH] [--state-dir DIR] < message.eml
mail2rss26 render [--feed NAME]       [--config PATH] [--state-dir DIR]
```

`ingest` reads exactly one message on stdin, files it under the feed the recipient names,
and re-renders that feed. It is what OpenSMTPD runs and it is the only thing that ever
writes a `.eml`.

`render` rebuilds feeds from the messages already on disk, without a delivery. Use it
after a configuration change (a retitled feed, a rotated URL), after restoring a backup,
or to bring a brand-new feed into existence — a feed with no messages renders as a valid
empty document, which is a better thing for a subscriber to fetch than a 404. Rendering is
deterministic: the same files always produce byte-identical output, so a `render` that
changes nothing rewrites the same bytes and no reader is told anything happened.

## Exit codes

**This is a contract, not an implementation detail.** The exit code is the only thing the
mail system ever learns about a delivery, and OpenSMTPD's reaction to a non-zero one is to
*keep the message in the queue and try again later*. That is the entire error-handling
subsystem of this project, obtained for free, and it only works if the codes mean
something.

The numbers are `sysexits(3)`, the vocabulary every sendmail-descended MDA is written
against.

| Code | `sysexits.h` | What happened | Does a retry help? |
| ---: | --- | --- | --- |
| 0 | `EX_OK` | Message stored and the feed re-rendered. Also the answer for a message we already had. | — |
| 64 | `EX_USAGE` | The command line is wrong — a missing `--recipient`, an unknown option. | **No.** The `mda` line in `smtpd.conf` needs editing. |
| 65 | `EX_DATAERR` | stdin held no message at all (zero bytes). | **No.** The next attempt hands over the same nothing. |
| 67 | `EX_NOUSER` | No feed is configured for this recipient, or `--feed` names a feed that does not exist. Nothing was written. | **No.** See below. |
| 70 | `EX_SOFTWARE` | An exception this program does not classify: a bug. The backtrace is on stderr, which OpenSMTPD copies into the mail log. | **No**, but the message stays queued, so a fix released today can still deliver it. |
| 74 | `EX_IOERR` | Reading stdin or writing the state directory failed: `ENOSPC`, `EACCES`, `EROFS`, a broken pipe. | **Yes.** This is the one worth deferring for. Empty the disk or fix the mode and the retry succeeds. |
| 75 | `EX_TEMPFAIL` | Reserved, and never returned. | — |
| 78 | `EX_CONFIG` | The feed list is missing, unreadable, not JSON, or does not satisfy the schema. | **No.** An operator has to fix the file. |

Three notes on how to read that table.

**"Does a retry help" is advice to a human, not a switch.** OpenSMTPD defers on *any*
non-zero exit; it does not bounce on 67 and defer on 74. So a permanent code means the
message sits in the queue until it expires or until somebody fixes the thing named — the
split above tells the operator reading the log which of those two it is going to be. 75 is
kept unused precisely because it is the number every sendmail-derived agent reads as
"defer this", and no other meaning in this program may ever be given it.

**A malformed *message* is never an error.** A newsletter with no `Subject`, a date on the
32nd of August, two `Subject` headers, a body declared us-ascii that is raw UTF-8, or no
body at all is stored and rendered. Refusing it would fix nothing and would park the
newsletter in the queue forever; an entry titled "(no subject)" is strictly better than a
message that never arrives. Non-zero is reserved for *our* side failing: unreadable stdin,
an unwritable state directory, bytes that are not a message.

**`EX_NOUSER` should be unreachable in production.** An address that belongs to no feed is
supposed to be refused with a 550 during the SMTP dialogue, by the same feed list that
generated `smtpd.conf`. Reaching `ingest` with one means the two have drifted apart, so
the message says so and names the config file. There is no catch-all feed and there is not
going to be one.

## Matching a recipient to a feed

`ingest` is told the envelope recipient (`%{rcpt}` in `smtpd.conf`) and looks it up in the
feed list. The rules, all deliberate:

- **Case-insensitive.** The domain is case-insensitive by RFC 5321 and the local part
  technically is not — but a feed address is a token *we* mint, so insisting on its case
  could only ever lose a newsletter to a mailer that upcased it.
- **`<address>` is unwrapped** and surrounding whitespace ignored, because some agents
  hand the recipient over in angle brackets and the mail is for the same feed either way.
- **`+tag` is stripped from the recipient** after an exact match fails, so
  `weekly.a41f9d+list@` reaches the feed that owns `weekly.a41f9d@`. The tag is stripped
  from the *recipient* only, never from the configuration: a tag can therefore never
  conjure a feed that was not configured. An address containing `+` can still be
  configured verbatim, and matches exactly and first.
- **A full `local@domain` is expected.** A bare local part matches nothing; pass
  `%{rcpt}`.
- **Anything else simply does not match**, and that is the point. OpenSMTPD sanitises its
  format specifiers before expanding them — characters it considers suspicious become
  `:` — so a mangled recipient arrives as something no legal feed address can equal. Keep
  feed addresses inside `[a-z0-9.-]` and this stays true. A `:` in the recipient makes
  `ingest` say so in the error, because it is the usual explanation.

## Configuration: the feed list

The list of feeds is **configuration, not state**: it is generated from Nix and no part of
this program ever adds to it. There is no sign-up flow, because there is nothing to sign
up to that is not in the repository.

The format is JSON for one reason: `builtins.toJSON` writes it on the Nix side and `json`
is stdlib on the Ruby side, so neither end gains a dependency. The path comes from
`--config`, then `$MAIL2RSS26_CONFIG`, then `/etc/mail2rss26/feeds.json`.

```json
{
  "version": 1,
  "stateDir": "/var/lib/mail2rss26",
  "feeds": {
    "lamplighter": {
      "title": "The Lamplighter",
      "id": "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21",
      "url": "https://feeds.lasocha.net/7c31e9a2b4d8f05e.atom",
      "addresses": ["weekly.a41f9d@feeds.lasocha.net"]
    }
  }
}
```

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `version` | integer | yes | Schema version; must be `1`. An old module and a new binary then fail on the first delivery with a clear message instead of half-understanding each other. |
| `stateDir` | string | no | Where the messages and rendered feeds live. Overridden by `--state-dir`; defaults to `/var/lib/mail2rss26`. Having it here keeps the `mda` line down to `mail2rss26 ingest --recipient %{rcpt}`. |
| `feeds` | object | yes | Keyed by feed name — the object shape an `attrsOf submodule` serialises to, which also makes a duplicate feed name unrepresentable rather than merely rejected. |
| `feeds.<name>` | — | — | The name is the directory under `stateDir` and must match `[a-z0-9][a-z0-9_-]*`, so `..`, `/` and hidden directories cannot be spelled. |
| `feeds.<name>.title` | string | yes | What a human sees in the reader. Becomes the feed's `<title>`. |
| `feeds.<name>.id` | string | yes | The feed's Atom `<id>`. **Permanent** — see below. |
| `feeds.<name>.url` | string | no | The public URL, written as `<link rel="self">`. Omit it and the feed is still valid, just without the link. |
| `feeds.<name>.addresses` | array of strings | yes, non-empty | The incoming addresses this feed accepts. An address claimed by two feeds is refused outright: guessing would file somebody's newsletter in the wrong place forever. |

### Three tokens, three lifecycles

The address, the URL and the `<id>` are three separate fields on purpose, and **none of
them may be derived from another**:

1. **The incoming address** is public in the worst sense — it ends up with whoever buys the
   newsletter's mailing list.
2. **The feed URL** is a secret, and it is **rotatable**: the day it leaks, change it. It
   must not be computable from the address, or a leaked address leaks what you read.
3. **The Atom `<id>`** is permanent and **never changes**. If it were the same string as
   the URL, rotating a leaked URL would make every reader treat a year of archive as new
   and show it all as unread. Entry ids are not derived from the feed's id either, for the
   same reason.

### From Nix (Phase 6, sketched here because the schema is a promise)

```nix
environment.etc."mail2rss26/feeds.json".text = builtins.toJSON {
  version = 1;
  stateDir = "/var/lib/mail2rss26";
  feeds = config.services.mail2rss26.feeds;
};
```

## State directory

```
/var/lib/mail2rss26/
└── lamplighter/                       one directory per feed, named by the config
    ├── 20260805T071244Z-pw-08.20260805071244@mail.pixelwharf.exa-45fe21151281f73c.eml
    ├── 20260812T060316Z-20260812060316.4c1b9a7e@mail.lamplighter-86791c3c9825e41c.eml
    ├── atom.xml                       what nginx serves
    └── .lock                          one delivery at a time
```

Files, not a database: a backup is a copy of a directory, and debugging is `cat`. The
`.eml` is stored byte for byte as it arrived. Both `atom.xml` and each `.eml` are written
to a temporary sibling, `fsync`ed and `rename`d into place, so a reader never fetches half
a document and a crash cannot leave a correctly named file full of zeroes.

The filename is `<timestamp>-<id>.eml` and both halves do work:

**The timestamp** is the entry's date as best known at delivery: the message's own `Date`
(or the `Received` our own OpenSMTPD stamped), and the delivery clock only for a message
that dated itself nowhere at all. It makes `ls` chronological — the directory sorts the
way it reads — and at render time it is handed back to the parser as a fallback date, so a
dateless newsletter is dated when it arrived instead of 1970. The clock is read **once**,
at delivery, and never again: rendering asks the clock nothing, which is what keeps the
output deterministic.

**The id** is the `Message-ID`, which is nearly free-form — mailers put spaces, slashes and
UTF-8 in it — so it is sanitised into `[A-Za-z0-9.@_-]`, truncated to something a human can
recognise, and followed by 64 bits of SHA-256 over the *original* value. The slug is for
your eyes; the digest is the identity, because sanitising alone is lossy and two ids that
flattened to the same name would make the second newsletter look like a redelivery of the
first. A message with no `Message-ID` of its own gets one derived from its bytes
(`sha256:…`), so redelivering it still collapses to one entry.

That makes **redelivery a no-op on disk**: before writing, `ingest` looks for a file whose
id half already matches and, if there is one, writes nothing at all. (The timestamps of two
deliveries may differ, which is why the match is on the id half rather than the whole
name.) The renderer deduplicates by `Message-ID` as well — the two mechanisms are
independent and both are cheap.

Feeds are truncated to the **50 most recent entries** at render time only. The `.eml` files
stay, so raising the limit republishes older entries rather than needing them re-delivered.

## Development

```bash
make test     # the Minitest suite in the dev shell — the fast loop
make check    # nix flake check: evaluation plus every check
make all      # what to run before a commit
```

`make` with no target lists everything. The test suite needs no network, no server and no
KVM; the fixtures in `test/fixtures/` are real newsletters and are the actual specification
of this program. Every newsletter that breaks it lands there next to the fix.

`nix flake check` runs two derivations. `checks.tests` is that suite, against the source
tree. `checks.package` is the other half and answers a question the suite structurally
cannot: it builds `packages.default` and runs the *packaged* wrapper under `env -i`,
because the suite runs with the interpreter's own gem directory in reach and a server
never will — see "Installing" for why that difference is the expensive one.

Trying it by hand needs a config file and a directory, nothing else:

```bash
mkdir -p /tmp/m2r/state
cat > /tmp/m2r/feeds.json <<'JSON'
{ "version": 1, "stateDir": "/tmp/m2r/state",
  "feeds": { "lamplighter": { "title": "The Lamplighter",
                              "id": "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21",
                              "addresses": ["weekly.a41f9d@feeds.lasocha.net"] } } }
JSON
cat test/fixtures/simple-multipart.eml \
  | ./bin/mail2rss26 ingest --config /tmp/m2r/feeds.json \
                            --recipient weekly.a41f9d@feeds.lasocha.net
```

## Installing

The flake is the only supported way to get this program. There is no `gem install` and
nothing to copy anywhere: `nix run` and a flake input are the two doors in, and both build
the same store path.

### Straight from the flake

```bash
nix run .#default -- ingest --help          # from a checkout
nix build .#default                          # ./result/bin/mail2rss26
```

`packages.default` is a single file in `$out/bin`: a wrapper around the interpreter, this
library and the one gem. It carries everything it needs itself, so it runs with an empty
environment —

```bash
env -i ./result/bin/mail2rss26 ingest --config /tmp/m2r/feeds.json \
       --state-dir /tmp/m2r/state --recipient weekly.a41f9d@feeds.lasocha.net < message.eml
```

— which is the property that matters, because an `mda(8)` line is very nearly that.

Two things about that wrapper are load-bearing rather than incidental.

**It `exec`s the interpreter**, so the Ruby process replaces the shell and *its* exit code
is what OpenSMTPD reads. The table above is the entire error-handling design; a wrapper
that returned a status of its own would quietly turn a deferred delivery into a discarded
one. There is a check that a `67` still arrives as a `67`.

**`GEM_PATH` is set, not extended**, and it names the bundled gems only. This is the one
sharp edge in packaging Ruby with Nix and it has now cut twice: setting `GEM_PATH` at all
removes the *interpreter's own* gem directory from the search path, and since Ruby 3.0 a
surprising number of things that feel like stdlib live there as **bundled gems** rather
than default gems — `rexml`, `minitest`, `csv`, `base64`. They import fine in the dev
shell and raise `LoadError` under the wrapper. The rule that falls out: `lib/` may require
default gems and `mail`, and anything else has to enter the `Gemfile` first. That is why
Atom is assembled from strings instead of with REXML, and it is checked rather than
remembered — `checks.package` runs the *built* wrapper under `env -i` and drives both
commands, because the other way to discover it is a `LoadError` in the middle of a
delivery.

The runtime closure is ~103 MB over 25 store paths, and it is the interpreter almost
exactly: Ruby and its own dependencies (glibc, OpenSSL, zlib, libyaml, libffi) account for
all but ~10 MB of it, while this program's own output is ~40 kB of Ruby. `bundix` is not
in it, and neither are the test suite, the fixtures, the `Makefile` or this file — the
package builds from a filtered source that is `bin/` and `lib/` and nothing else. The
copy that lands on a server is therefore the program and the machinery to run it.

### As an input to another flake

This is how it actually gets deployed: Rivendell takes it as an input, exactly the way it
takes each static site.

```nix
inputs.mail2rss26 = {
  url = "git+ssh://git@github.com/swistak35/mail2rss26?ref=main";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

`follows` is not politeness. This flake already pins the same `nixos-26.05` that Rivendell
does, and letting it resolve its own nixpkgs would put a second revision — and a second
~100 MB interpreter — into one closure for no benefit.

From Phase 6 the consumer enables `nixosModules.default` and never names the package. Until
then it is reachable directly, and the shape of the `mda` line is already fixed by the exit
codes and the recipient matching above:

```nix
{ pkgs, lib, inputs, ... }:
let
  mail2rss26 = inputs.mail2rss26.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  services.opensmtpd.serverConfiguration = ''
    action "newsletters" mda "${lib.getExe mail2rss26} ingest --recipient %{rcpt}" user mail2rss26
  '';
}
```

Everything else the delivery needs — the state directory, the feed list — comes from
`/etc/mail2rss26/feeds.json`, which is why that line has one option on it.

**Iterating without committing.** Bumping a lock to try a one-line change is a punishment;
point the input at the working tree instead.

```bash
nixos-rebuild switch --flake . --override-input mail2rss26 ~/projs/swistak35/mail2rss26
```

### What it needs at run time

A config file, a directory it may write to, and nothing else. No network, no listening
port, no daemon, no database, no state that is not a file under `stateDir`. The user it
runs as needs write access to that directory and read access to the config; the process
lives for the length of one delivery and then it is gone.
