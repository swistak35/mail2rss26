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
                    --recipient '%{rcpt}'"
```

## Status

**Phase 6 of the plan, in part.** `ingest` works end to end against a local directory —
recipient → feed, message stored, feed re-rendered, an exit-code contract written against
what OpenSMTPD does with the number rather than what `sysexits(3)` calls it — the whole
thing is packaged (`nix run .#default -- ingest` works from the flake alone), and there is
now a `nixosModules.default` and a `nixosTest`.

**The `nixosTest` has never been executed.** It needs `/dev/kvm`, which the workstation
does not have. It evaluates, its Python type-checks and lints, every derivation it depends
on builds, and the `smtpd.conf` it generates is accepted by the real `smtpd -n` — but
nothing has watched it pass, and nothing here has been deployed. Phase 7 is the first time
any of this meets a machine.

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
mail system ever learns about a delivery, and it is not a comment in the log — it is an
*instruction*. It decides whether the message is kept in the queue and tried again or
thrown away and bounced. That is the entire error-handling subsystem of this project,
obtained for free, and it only works if the codes say what we mean.

### What OpenSMTPD does with the number

Everything below follows from twenty lines of OpenSMTPD 7.8.0, `usr.sbin/smtpd/smtpd.c`:

```c
if (WIFSIGNALED(status)) {
        mda_status = MDA_TEMPFAIL;      /* killed by a signal → defer */
} else if (WIFEXITED(status)) {
        if (WEXITSTATUS(status) != 0) {
                mda_sysexit = WEXITSTATUS(status);
                if (mda_sysexit == EX_OSERR || mda_sysexit == EX_TEMPFAIL)
                        mda_status = MDA_TEMPFAIL;   /* 71 or 75 → defer */
                else
                        mda_status = MDA_PERMFAIL;   /* everything else → bounce */
        }
}
```

**Only two exit codes defer: 71 (`EX_OSERR`) and 75 (`EX_TEMPFAIL`).** Every other
non-zero status is a *permanent* failure: the envelope leaves the queue, the sender gets a
bounce, and the newsletter is gone. A delivery killed by a signal defers.

That is the whole of it, and it is worth sitting with, because the obvious way to choose an
exit code — reach for the `sysexits(3)` value that best *describes* what went wrong — is
wrong here, and this program did it. Until Phase 6 the table below claimed that smtpd
deferred on any non-zero exit and that the numbers were advice to whoever read the log.
Under that assumption `74` (`EX_IOERR`) was the row documented as "a retry helps" — and it
was precisely the row that destroyed a newsletter, because a full disk bounced the mail
instead of queueing it. N3 says "an error is a non-zero exit; the message stays in
OpenSMTPD's queue and is not lost". It did not.

**Where an informative code and correct behaviour conflict, behaviour wins.** The
description goes on stderr, which smtpd copies into the mail log and into the bounce, and
which is the only bug report a delivery ever files. Nobody has ever debugged anything from
a bare `78` that they could not have debugged from a line of English. The sysexits
vocabulary is real and it is tempting and it fits in a table beautifully; it just cannot be
used to *speak*, because smtpd only understands two words. **Do not tidy these numbers back
into prettiness.**

### The table

The question each row answers is not "what kind of failure is this?" but **"must this
message survive?"** — that is, would a corrected system (a fixed `feeds.json`, a fixed
`mda` line, a disk with room on it, a bug fix released this afternoon) deliver this exact
envelope? If yes, the answer is 75 and nothing else.

| Code | What happened | smtpd does | Why |
| ---: | --- | --- | --- |
| 0 | Message stored and the feed re-rendered. Also the answer for a message we already had. | delivered | — |
| 67 | No feed is configured for this recipient, or `--feed` names a feed that does not exist. Nothing was written. | **bounce** | There is no feed and there is not going to be one. See below. |
| 75 | Anything else that went wrong: a broken `mda` line, an unreadable or invalid feed list, `ENOSPC` / `EROFS` / `EACCES` on the state directory, a broken pipe, zero bytes on stdin, an unclassified exception. | **defer** | Somebody can fix it, and the queue holds the newsletter until they do. |

Three codes, and that is the entire list. The reasoning per condition:

- **A broken `mda` command line** (a renamed option, a missing `--recipient`, a mistyped
  command word) was `64`. It defers now. It is permanent only in the sense that it will
  never fix *itself*; an operator edits `smtpd.conf`, and the queue then delivers
  everything that arrived meanwhile. Bouncing gave zero recovery window, and the symptom of
  a bouncing `mda` line is *the absence of mail*, which is the single hardest thing to
  notice. Deferring is not silent: `smtpctl show queue` stops being empty and the message
  is in the mail log once per delivery.
- **An unreadable or invalid feed list** was `78`, and it is the same shape of problem one
  file over. The envelope that hit it was accepted at SMTP time because `smtpd.conf` said
  the address was good — and `smtpd.conf` and `feeds.json` come from the same Nix option —
  so a corrected file delivers it. This is the "OpenSMTPD's queue is our retry mechanism"
  payoff being collected rather than described.
- **Transient I/O** was `74`, which is the bug this contract was rewritten to fix. A
  newsletter arriving while the disk is full now stays queued and lands after the cleanup.
- **Zero bytes on stdin** was `65`, on the reasoning that "the next attempt hands over the
  same nothing". That reasoning does not survive contact with SMTP: a queued message cannot
  be zero bytes, because `DATA` carries headers and smtpd stamps a `Received:` of its own
  on top of them. Zero bytes on stdin therefore never means "this envelope is empty" — it
  means the pipe between the queue and this process is broken, while the queue file still
  holds a whole newsletter. Bouncing would discard a message on the strength of evidence
  about our own plumbing.
- **An unclassified exception** was `70`, and it is the one row where the choice is a
  judgement rather than a deduction. A crash we did not classify may well be deterministic
  in the bytes of this particular newsletter, in which case every retry crashes identically
  and the envelope expires in a few days — deferring bought nothing but noise, and the
  message is lost anyway, later and more loudly. But that is not knowable from inside the
  crash, and the two ways of being wrong do not cost the same. Defer a genuinely permanent
  crash: four days of queue, then the bounce that would have happened immediately. Bounce a
  crash that gets fixed this afternoon: the newsletter is gone, unrecoverably, while the
  fix sits there. Undecidable plus asymmetric costs is exactly the situation N3 exists for,
  and "a swallowed exception is a lost newsletter" is a convention of this project — a
  bounce is the loudest possible way of swallowing one. It defers.
- **71 (`EX_OSERR`) is not used.** It defers identically to 75 and would be marginally more
  descriptive for the I/O cases. It is left out because a second defer code buys no
  behaviour at all, only the *appearance* of a taxonomy — and it was that appearance which
  made returning `74` look reasonable in the first place. One defer code cannot drift.

### Where the line is

The table has one bounce in it, and that is a finding rather than an oversight: this
program has exactly one failure mode that no operator action can make deliverable. The
test for any condition added later is the same question — *would a corrected system deliver
this exact envelope?* — and if the answer is yes, it defers.

The cost of that line is real and should be stated: a permanently broken `mda` line now
retries until the queue expires the envelope (OpenSMTPD's default is four days) rather than
failing immediately. What it buys is that every one of those four days is a day the mail
can still be saved. The failure mode it replaces was losing the mail at once.

**`EX_NOUSER` should be unreachable in production.** An address that belongs to no feed is
supposed to be refused with a 550 during the SMTP dialogue, by the same feed list that
generated `smtpd.conf`. Reaching `ingest` with one means the two have drifted apart, so the
message says so and names the config file. A bounce is right here: there is no feed, there
is not going to be one — there is no catch-all and no sign-up — and deferring would only
retry until the queue expired it, which is the same bounce four days later plus four days
of pointless attempts. The realistic drift is a feed being *removed* while its address
lingers in `smtpd.conf`, and telling the sender is the correct outcome for that.

`nix/vm-test.nix` pins both halves against a real OpenSMTPD — a delivery that bounces
because the recipient has no feed, and a delivery that stays in the queue because this
program returned 75 — on the day there is a machine to run it on. `test/ingest_test.rb`
pins the property itself, without KVM, in
`test_a_transient_io_failure_exits_with_a_code_opensmtpd_will_defer`.

**A malformed *message* is never an error.** A newsletter with no `Subject`, a date on the
32nd of August, two `Subject` headers, a body declared us-ascii that is raw UTF-8, or no
body at all is stored and rendered — exit 0. Refusing it would fix nothing and would park
the newsletter in the queue until it expired; an entry titled "(no subject)" is strictly
better than a message that never arrives. Non-zero is reserved for *our* side failing: a
broken pipe, an unwritable state directory, a feed list that will not load.

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
  format specifiers before expanding them — so a mangled recipient arrives as something no
  legal feed address can equal. Keep feed addresses inside `[a-z0-9.-]` and this stays
  true. A `:` in the recipient makes `ingest` say so in the error, because it is the usual
  explanation.

  The substituted set is exact, and worth knowing because the expansion goes into a shell
  command line: `MAILADDR_ESCAPE` in `smtpd.h` is ``!#$%&'*?`{|}~``, and every one of those
  characters becomes `:`. Note what is *not* in it — space, `"`, `;`, `\`, `<`, `>`. That
  is why the `mda` line quotes `'%{rcpt}'`: a single quote can never survive the
  substitution, so single quotes around it cannot be closed by anything.

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

### Where the file comes from

Nobody writes this file. `nixosModules.default` generates it from
`services.mail2rss26.feeds` — one `toJSON` of the option, which is the whole reason the
schema keys feeds by name — and installs it at `/etc/mail2rss26/feeds.json`, the path
`Config` looks in when nothing overrides it. See "The NixOS module" below.

Everything in it is validated twice: by the module at evaluation time (feed names, empty
address lists, an address claimed by two feeds) and by `Config` on every delivery. The
first is the cheap place to find out; the second is the one that has to be right, because
a feed name becomes a directory and an address decides which feed a stranger's mail lands
in.

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
make test        # the Minitest suite in the dev shell — the fast loop
make check-fast  # the two checks that do not need KVM — what to run before a commit
make check       # nix flake check: evaluation plus every check, KVM included
make all         # what to run before a commit
```

`make` with no target lists everything. The test suite needs no network, no server and no
KVM; the fixtures in `test/fixtures/` are real newsletters and are the actual specification
of this program. Every newsletter that breaks it lands there next to the fix.

`nix flake check` runs three derivations, and one of them is not like the others.

`checks.tests` is that suite, against the source tree. `checks.package` answers a question
the suite structurally cannot: it builds `packages.default` and runs the *packaged*
wrapper under `env -i`, because the suite runs with the interpreter's own gem directory in
reach and a server never will — see "Installing" for why that difference is the expensive
one. Neither needs KVM and **neither may ever grow a VM**: N5 says the fast loop runs
without one.

`checks.vm-test` is the `nixosTest` — a real OpenSMTPD, a real SMTP conversation from the
test driver, and assertions on the `atom.xml` that comes out. It boots a machine, so from
Phase 6 on **`nix flake check` as a whole needs `/dev/kvm`** and fails without it:

```
error: ... Reason: missing system features
       Required features: {kvm, nixos-test}
```

That message, and specifically the word `kvm`, is how you tell a missing hypervisor from a
broken check. Without KVM, run the fast pair instead — that is what `make check-fast` is:

```bash
nix build .#checks.x86_64-linux.tests .#checks.x86_64-linux.package
```

The evaluation half of `nix flake check` is still worth having on its own, and it does not
need KVM either:

```bash
nix eval .#checks.x86_64-linux.vm-test.drvPath   # the test evaluates
nix build .#checks.x86_64-linux.vm-test.nodes.mail.system.build.toplevel
```

The second one builds the whole system closure of the machine the test boots, which is
where module mistakes actually live. Building a NixOS system needs no KVM; only booting
one does.

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
one. `checks.package` asserts that a `67` still arrives as a `67` and that a state
directory the delivery cannot write to still arrives as a `75`.

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

The consumer then enables `nixosModules.default` and never names the package again.

## The NixOS module

`nixosModules.default` is deliberately **thin**, and staying thin is the point rather than
a stage it will grow out of. It covers a system user, a state directory, the generated
feed list, and the exact command OpenSMTPD should run. The domain, the nginx vhost, the
ACME entry and the whole of `smtpd.conf` belong to the machine, not to this repository — a
module that lives in someone else's flake drifts towards being an option framework all by
itself.

Four options are settable:

| Option | Default | Why it exists |
| --- | --- | --- |
| `enable` | `false` | — |
| `package` | this flake's `packages.default` | The override door. `lib.getExe` reads `mainProgram` off it. |
| `stateDir` | `/var/lib/mail2rss26` | nginx has to be pointed at it from the other repository, and spelling one path in two flakes is how they drift. |
| `feeds` | `{ }` | `feeds.json` has to be generated from something, and the schema is an `attrsOf submodule` precisely so this is one `toJSON` and nothing else. Per feed: `title`, `id`, `addresses`, and optionally `url`. |

Three more are **read-only outputs**, not knobs. They exist so the OpenSMTPD configuration
in the other repository can be written without hard-coding a single string this module
owns — which is the one failure this module is in a position to prevent, since a
`feeds.json` and an `smtpd.conf` that disagree are exactly what produces the `EX_NOUSER`
the table above calls unreachable.

| Output | What it is |
| --- | --- |
| `user` | The system user deliveries run as: the `user` keyword on the `action`. |
| `mdaCommand` | The full `mda` command, absolute path and `'%{rcpt}'` included. |
| `addresses` | Every configured address, flattened and sorted, for the `smtpd.conf` tables. |

Enabling it also creates `/etc/mail2rss26/feeds.json` (which is `Config::DEFAULT_PATH`,
which is why the `mda` line carries no `--config`) and a `mail2rss26-render.service`: a
oneshot that re-renders every feed at boot and whenever the feed list changes. It is what
makes a brand-new feed a valid empty document the day it is deployed instead of a 404
until its first newsletter, and it is where a malformed feed list fails loudly — at the
`nixos-rebuild switch` that introduced it, rather than during a delivery hours later.

### What the machine side looks like

```nix
{ config, lib, ... }:
let
  m2r = config.services.mail2rss26;
in
{
  services.mail2rss26 = {
    enable = true;
    feeds.lamplighter = {
      title = "The Lamplighter";
      id = "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21";
      url = "https://feeds.lasocha.net/7c31e9a2b4d8f05e.atom";
      addresses = [ "weekly.a41f9d@feeds.lasocha.net" ];
    };
  };

  services.opensmtpd = {
    enable = true;
    serverConfiguration = ''
      listen on eth0

      table m2r_addresses { ${lib.concatMapStringsSep ", " (a: "\"${a}\"") m2r.addresses} }
      table m2r_virtual { ${lib.concatMapStringsSep ", " (a: "\"${a}\" = ${m2r.user}") m2r.addresses} }

      action "m2r" mda "${m2r.mdaCommand}" virtual <m2r_virtual> user ${m2r.user}
      match from any for rcpt-to <m2r_addresses> action "m2r"
    '';
  };
}
```

**Both tables are load-bearing and they are not redundant.**

The *list* is what the `match` rule tests. An envelope that matches no rule is refused with
`550 Invalid recipient` during the dialogue, which is F5 exactly and by number, and it is
why no message for an unconfigured address is ever queued.

The *mapping* is what OpenSMTPD expands the recipient through. Without it, `smtpd` looks
the local part up in the system user database and fails, because there is no user called
`weekly.a41f9d` — `lka_session.c` logs "user-part does not match system user" and the
recipient is refused. `user mail2rss26` on the action does **not** rescue this: it only
skips the `.forward` lookup, it does not skip the lookup of the recipient. This is the
least obvious fact in the whole setup, and it is the reason `nix/vm-test.nix` exists.

Everything else the delivery needs — the state directory, the feed list — comes from
`/etc/mail2rss26/feeds.json`, which is why the `mda` line carries one option.

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
