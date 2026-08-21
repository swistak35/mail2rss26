# The one runtime check that is not the production server: a real OpenSMTPD, a
# real SMTP conversation, and a real `atom.xml` at the end of it.
#
# ==========================================================================
# THIS TEST HAS NEVER BEEN EXECUTED. It is written, it evaluates, and its
# dependencies build; running it needs /dev/kvm, which the workstation does not
# have (VirtualBox holds AMD-V — see the plan's BLOCKER 1). Everything below is
# derived from smtpd.conf(5) and from reading OpenSMTPD 7.8.0's source, not
# from watching it pass. Treat a red run as new information rather than as a
# regression, and see the notes on each subtest for what a failure would mean.
# ==========================================================================
#
# What it is here to answer, in order of how much the plan wants to know:
#
#   1. What OpenSMTPD actually hands `mda` for the recipient. The plan parks
#      this as an open question for exactly this phase, and `ingest` requires a
#      full `local@domain`, so being wrong about it is a production outage that
#      evaluation cannot catch. The `probe.invalid` domain below delivers to a
#      script that records *every* format specifier rather than assuming one.
#
#   2. F5 — mail for an address no feed claims is refused with a 550 during the
#      SMTP dialogue, not accepted and then dropped. No other test covers this,
#      because no other test speaks SMTP.
#
#   3. F1/F3/F4 and F6 through the real path: a message that arrives over the
#      wire becomes an entry, and the same message twice is still one entry.
#
#   4. That the exit-code contract behaves the way smtpd.c says it does. 71 and
#      75 defer; every other non-zero status is *permanent* and the newsletter
#      bounces. Phase 6 rewrote the contract around that fact — N3 was being
#      violated by construction — so the last subtest drives both sides of the
#      new line with the *real* program: an envelope that bounces because the
#      recipient has no feed, and an envelope that stays in the queue because
#      the program answered 75. See the exit-code section of README.md.
{ self, pkgs }:

let
  # The real domain, not an invented one: the fixtures' To: headers already
  # name it and a test whose configuration is a different shape from production
  # is a test of something else. Nothing here resolves or leaves the VM.
  domain = "feeds.lasocha.net";

  weekly = "weekly.a41f9d@${domain}";
  okazje = "okazje.3f1c@${domain}";

  # Configured in smtpd.conf and in *no* feed. This is the drift the README
  # calls unreachable in production — smtpd.conf and feeds.json disagreeing —
  # and it is the only way to make the real program exit non-zero on demand.
  drifted = "ghost.9c2e@${domain}";

  # Reserved by RFC 2606, so it can never accidentally mean anything. Mail for
  # it goes to the recorder rather than to us.
  probeDomain = "probe.invalid";

  # Likewise, but delivered by a stand-in that only ever exits 75. It is the
  # control: the smallest possible thing that can answer "does smtpd defer on
  # 75 at all", with none of this program in the way.
  tempfailDomain = "tempfail.invalid";

  # And the same question asked of the real binary. Mail here is delivered by
  # the actual mda command with its --config pointed at a file that is not
  # there, which is the commonest operator mistake there is and which the new
  # contract answers with 75 rather than the old, descriptive, *bouncing* 78.
  brokenConfigDomain = "brokenconfig.invalid";

  user = "mail2rss26";
  stateDir = "/var/lib/mail2rss26";

  # Deliberately *not* under stateDir: a directory next to the feeds would be
  # something the renderer has to know to ignore.
  probeDir = "/var/lib/mail2rss26-probe";

  hostPort = 2525;

  feedId = "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21";
  feedUrl = "https://feeds.lasocha.net/7c31e9a2b4d8f05e.atom";

  # A delivery agent's PATH is "/usr/bin:/bin" (`_PATH_DEFPATH`, hard-coded in
  # mda_unpriv.c), which on NixOS holds `env` and `sh` and nothing else. Every
  # command in these scripts is therefore an absolute store path or a shell
  # builtin — the same constraint the real mda line lives under, and the reason
  # `checks.package` runs the wrapper under `env -i`.
  cat = "${pkgs.coreutils}/bin/cat";

  # Records what smtpd expanded, one tab-separated line per delivery, and then
  # throws the message away. This is the instrument, not the subject.
  probe = pkgs.writeShellScript "mail2rss26-rcpt-probe" ''
    set -e

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "rcpt=$1" "rcpt.user=$2" "rcpt.domain=$3" \
      "dest=$4" "dest.user=$5" "dest.domain=$6" \
      "sender=$7" "user.username=$8" \
      "env.ORIGINAL_RECIPIENT=$ORIGINAL_RECIPIENT" \
      "env.RECIPIENT=$RECIPIENT" \
      "env.EXTENSION=$EXTENSION" \
      >> ${probeDir}/expansions

    # smtpd(8) expects the delivery agent to read the whole message. One that
    # exits without reading gets EPIPE, which smtpd reports as a failed
    # delivery and retries — forever.
    ${cat} > /dev/null
  '';

  # 75 is EX_TEMPFAIL, the number every sendmail-descended agent reads as
  # "defer this". Whether OpenSMTPD is one of them is the second half of the
  # plan's open question, and this is the smallest possible thing that answers
  # it.
  tempfail = pkgs.writeShellScript "mail2rss26-always-tempfail" ''
    ${cat} > /dev/null
    echo attempt >> ${probeDir}/tempfail-attempts
    exit 75
  '';

  quoted = value: "\"${value}\"";
  commaJoin = builtins.concatStringsSep ", ";
in
pkgs.testers.runNixOSTest {
  name = "mail2rss26";

  nodes.mail =
    { config, ... }:
    let
      m2r = config.services.mail2rss26;

      # Every address the feed list claims, plus the drifted one. Note that
      # `m2r.addresses` is read out of the module rather than repeated here:
      # keeping smtpd.conf and feeds.json from disagreeing is the single thing
      # that read-only option exists for, and this is it being used.
      accepted = m2r.addresses ++ [ drifted ];
    in
    {
      imports = [ self.nixosModules.default ];

      services.mail2rss26 = {
        enable = true;
        feeds = {
          lamplighter = {
            title = "The Lamplighter";
            id = feedId;
            url = feedUrl;
            addresses = [ weekly ];
          };
          # A second feed that never receives anything, so that "the message
          # landed in the right directory" is a claim with teeth, and so that
          # the render-at-activation unit is seen to bring an empty feed into
          # existence.
          okazje = {
            title = "Wielkie Okazje";
            id = "urn:uuid:1f0f2f6c-3c6a-4a3f-9d0b-2a1b8f4c7e35";
            addresses = [ okazje ];
          };
        };
      };

      services.opensmtpd = {
        enable = true;
        # Puts the ruleset decisions in the journal, which is where the answer
        # goes when one of the assertions below turns out to be wrong.
        extraServerArgs = [ "-v" ];

        # This is the shape Phase 7 will copy into Rivendell, so it is written
        # the way that repository would write it: nothing about mail2rss26 is
        # spelled out twice, every value comes from the module.
        serverConfiguration = ''
          # Phase 0 established that a minimal dialect is enough for real
          # senders — no AUTH, no STARTTLS, no PIPELINING to speak of — so
          # this announces nothing and relays nothing (N2).
          listen on 0.0.0.0

          # Two tables over the same addresses, and they do different jobs.
          #
          # The list is the *match* criterion. An address that is in no rule
          # matches nothing, and an envelope that matches nothing is refused
          # with "550 Invalid recipient" during the dialogue — which is F5,
          # exactly and by number.
          #
          # The mapping is the *expansion*. Without it, OpenSMTPD resolves the
          # recipient's local part against the system user database and fails
          # when there is no user called `weekly.a41f9d` (lka_session.c: "user
          # -part does not match system user"). `user ${user}` on the action
          # does not help — it only skips the .forward lookup, it does not skip
          # the lookup of the recipient. This is the single least obvious thing
          # in this file and it is the reason the test exists.
          table m2r_addresses { ${commaJoin (map quoted accepted)} }
          table m2r_virtual { ${commaJoin (map (address: "\"${address}\" = ${user}") accepted)} }

          # Everything for the three throwaway domains goes to one system user
          # as well, via catch-alls.
          table aux_virtual { "@${probeDomain}" = ${user}, "@${tempfailDomain}" = ${user}, "@${brokenConfigDomain}" = ${user} }

          action "m2r" mda "${m2r.mdaCommand}" \
                 virtual <m2r_virtual> user ${user}

          action "probe" mda "${probe} '%{rcpt}' '%{rcpt.user}' '%{rcpt.domain}' '%{dest}' '%{dest.user}' '%{dest.domain}' '%{sender}' '%{user.username}'" \
                 virtual <aux_virtual> user ${user}

          action "tempfail" mda "${tempfail}" virtual <aux_virtual> user ${user}

          # The real mda command, with the feed list pointed somewhere empty.
          # Nothing about it is a stand-in: this is `mail2rss26 ingest` failing
          # the way a bad deploy makes it fail, and the assertion is that the
          # newsletter is still in the queue afterwards.
          action "brokenconfig" mda "${m2r.mdaCommand} --config /var/empty/no-such-feeds.json" \
                 virtual <aux_virtual> user ${user}

          match from any for rcpt-to <m2r_addresses> action "m2r"
          match from any for domain "${probeDomain}" action "probe"
          match from any for domain "${tempfailDomain}" action "tempfail"
          match from any for domain "${brokenConfigDomain}" action "brokenconfig"
        '';
      };

      systemd.tmpfiles.settings.mail2rss26-test.${probeDir}.d = {
        inherit user;
        group = user;
        mode = "0755";
      };

      networking.firewall.allowedTCPPorts = [ 25 ];

      # How the driver reaches the guest at all. The test driver runs on the
      # host and has no route onto the guest's VLAN; qemu's user-mode network
      # already exists for eth0, so one hostfwd is the whole bridge — and it
      # means the SMTP client is genuinely outside the machine, the way a
      # sending mail exchanger is.
      virtualisation.forwardPorts = [
        {
          from = "host";
          host.port = hostPort;
          guest.port = 25;
        }
      ];

      # Note what is *not* here: python3. It is not in a NixOS base system's
      # PATH (Phase 0 found that out the hard way on Rivendell) and nothing
      # puts it there — the Python in this test is the *driver's*, which runs
      # on the host. Everything that runs on the guest is a shell builtin, an
      # absolute store path, or a tool the test framework already installs.
    };

  testScript = ''
    import smtplib
    from xml.etree import ElementTree

    ATOM = "{http://www.w3.org/2005/Atom}"
    STATE = "${stateDir}"
    PROBE = "${probeDir}"

    WEEKLY = "${weekly}"
    DRIFTED = "${drifted}"
    STRANGER = "nobody.at.all@${domain}"

    # The fixture, byte for byte, out of the same directory the Minitest suite
    # reads it from. A message invented here would be a tenth specification of
    # this program next to the nine in test/fixtures.
    with open("${../test/fixtures/simple-multipart.eml}", "rb") as handle:
        RAW = handle.read()

    # SMTP wants CRLF and the fixture on disk is LF. smtplib normalises line
    # endings only for str payloads, and this one goes over as bytes so that
    # nothing re-encodes it on the way.
    MESSAGE = RAW.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")


    def send(sender, recipient, body=MESSAGE):
        """One SMTP conversation, from the host, to the guest's port 25."""
        with smtplib.SMTP("127.0.0.1", ${toString hostPort}, timeout=60) as smtp:
            smtp.sendmail(sender, recipient, body)


    def drained():
        """Block until OpenSMTPD's queue is empty.

        An envelope leaves the queue only once the delivery has been reported,
        so an empty queue means the mda has run and smtpd has heard about it.
        """
        mail.wait_until_fails("smtpctl show queue | grep -q .")


    def atom(feed):
        """The feed as the reader would get it, parsed on the driver side.

        Parsing here rather than grepping is the point: a document that does
        not parse fails the test, which is F2 checked rather than assumed.
        """
        return ElementTree.fromstring(mail.succeed(f"cat {STATE}/{feed}/atom.xml"))


    def child(node, tag):
        found = node.find(ATOM + tag)
        assert found is not None, f"<{tag}> is missing"
        return found


    def entries(feed):
        return atom(feed).findall(ATOM + "entry")


    def eml_count(feed=""):
        return int(mail.succeed(f"find {STATE}/{feed} -name '*.eml' | wc -l").strip())


    def expansions():
        """Every recorded mda expansion, oldest first."""
        raw = mail.succeed(f"cat {PROBE}/expansions")
        records = []
        for line in raw.splitlines():
            if line.strip():
                records.append(dict(field.split("=", 1) for field in line.split("\t")))
        return records


    mail.wait_for_unit("multi-user.target")
    mail.wait_for_unit("opensmtpd.service")
    mail.wait_for_open_port(25)

    with subtest("the module wires itself up before any mail arrives"):
        # A feed exists because it is in the configuration, so it must be
        # fetchable the moment it is deployed rather than 404 until its first
        # newsletter. That is what the render-at-activation unit is for, and
        # this is the only place it is checked.
        mail.wait_for_unit("mail2rss26-render.service")

        assert mail.succeed(f"stat -c '%U:%G:%a' {STATE}").strip() == "mail2rss26:mail2rss26:755"

        for feed, title in (("lamplighter", "The Lamplighter"), ("okazje", "Wielkie Okazje")):
            document = atom(feed)
            assert document.tag == ATOM + "feed", f"{feed} is not an Atom feed"
            assert child(document, "title").text == title
            assert document.findall(ATOM + "entry") == [], f"{feed} has entries already"

        assert child(atom("lamplighter"), "id").text == "${feedId}"
        assert child(atom("lamplighter"), "link").get("href") == "${feedUrl}"

        # The config file the module generated is the one the binary reads:
        # same path, no environment variable, no --config on the mda line.
        mail.succeed("test -f /etc/mail2rss26/feeds.json")

    with subtest("F5: an address no feed claims is refused during the dialogue"):
        # If this fails with a 5xx that is not 550, the ruleset matched
        # something it should not have and the message got as far as expansion;
        # if it fails with a 250, F5 is simply not implemented by this
        # smtpd.conf and the `rcpt-to` table is the thing to look at.
        try:
            send("newsletter@lamplighter.example", STRANGER)
        except smtplib.SMTPRecipientsRefused as refused:
            code, detail = refused.recipients[STRANGER]
            print("refused:", code, detail)
            assert code == 550, f"expected 550, got {code}: {detail!r}"
        else:
            raise Exception(f"{STRANGER} was accepted; nothing is supposed to accept it")

        assert eml_count() == 0, "a refused recipient wrote something anyway"

    with subtest("F1/F3/F4: a newsletter delivered over SMTP becomes an entry"):
        send("bounce-8827.a41f9d@mail.lamplighter.example", WEEKLY)
        drained()
        mail.wait_until_succeeds(f"grep -q '<entry>' {STATE}/lamplighter/atom.xml")

        found = entries("lamplighter")
        assert len(found) == 1, f"expected one entry, got {len(found)}"
        entry = found[0]

        # F4: title from Subject, date from Date, author from From.
        assert child(entry, "title").text == "Issue 42: The quiet parts of a slow web"
        assert child(entry, "updated").text == "2026-08-12T06:03:16Z"
        author = child(entry, "author")
        assert child(author, "name").text == "The Lamplighter"
        assert child(author, "email").text == "newsletter@lamplighter.example"
        assert child(entry, "id").text == "mid:20260812060316.4c1b9a7e@mail.lamplighter.example"

        # F3: the html part, not the text one, and passed through rather than
        # cleaned. ElementTree hands it back unescaped, so this is the markup a
        # reader would render.
        content = child(entry, "content")
        assert content.get("type") == "html"
        assert "<ol>" in content.text
        assert "quiet parts of a slow web" in content.text

        # The message went to the feed that claims the address and to no other.
        assert eml_count("lamplighter") == 1
        assert entries("okazje") == []
        assert eml_count("okazje") == 0

    with subtest("F6: the same newsletter delivered twice is still one entry"):
        before = mail.succeed(f"sha256sum {STATE}/lamplighter/atom.xml").split()[0]
        stored = mail.succeed(f"ls {STATE}/lamplighter").strip()

        send("bounce-8827.a41f9d@mail.lamplighter.example", WEEKLY)
        drained()

        after = mail.succeed(f"sha256sum {STATE}/lamplighter/atom.xml").split()[0]
        # N6 as well as F6: not "one entry again" but the same bytes, so no
        # reader is told anything happened.
        assert before == after, "a redelivery rewrote the feed"
        assert mail.succeed(f"ls {STATE}/lamplighter").strip() == stored
        assert len(entries("lamplighter")) == 1
        assert eml_count("lamplighter") == 1

    with subtest("what OpenSMTPD hands the mda: the %{rcpt} question"):
        # The plan's open question, answered by observation. Everything is
        # printed, because the value of this subtest is as much the record in
        # the log as the assertions.
        probed = "weekly.a41f9d@${probeDomain}"
        send("newsletter@lamplighter.example", probed)
        drained()
        mail.wait_until_succeeds(f"test -s {PROBE}/expansions")

        record = expansions()[-1]
        for key, value in record.items():
            print(f"  {key} = {value!r}")

        # The assertion the whole recipient matcher rests on: %{rcpt} is a
        # full local@domain. If it turns out to be a bare local part, the fix
        # is in smtpd.conf (a different specifier) and not in the Ruby, which
        # requires the full form on purpose.
        assert record["rcpt"] == probed, f"%{{rcpt}} was {record['rcpt']!r}"
        assert record["rcpt.user"] == "weekly.a41f9d"
        assert record["rcpt.domain"] == "${probeDomain}"
        assert record["env.ORIGINAL_RECIPIENT"] == probed

        # ":" is what smtpd substitutes for the characters it distrusts, so a
        # colon in an expansion of a perfectly ordinary address would mean the
        # alphabet feed addresses may use is narrower than the README claims.
        assert ":" not in record["rcpt"], "a plain address came back sanitised"

    with subtest("a +tag survives as something the feed lookup can undo"):
        tagged = "weekly.a41f9d+list@${probeDomain}"
        send("newsletter@lamplighter.example", tagged)
        drained()

        record = expansions()[-1]
        for key, value in record.items():
            print(f"  {key} = {value!r}")

        # Deliberately weaker than the subtest above. Whether the tag rides
        # along in %{rcpt}, in %{dest} or only in $EXTENSION is smtpd's
        # business; what has to hold is that the local part still reduces to
        # the address a feed claims, which is what Config.without_tag does.
        assert record["rcpt"].endswith("@${probeDomain}")
        assert record["rcpt"].split("@")[0].split("+")[0] == "weekly.a41f9d"

    with subtest("N3: the failures that must survive stay in the queue"):
        # The property the whole exit-code contract exists for, driven against
        # a real queue. OpenSMTPD 7.8.0 decides it in smtpd.c: EX_OSERR (71)
        # and EX_TEMPFAIL (75) become MDA_TEMPFAIL, *every other* non-zero
        # status becomes MDA_PERMFAIL and the envelope is bounced rather than
        # kept. Phase 6 rewrote the contract around that: this program now
        # answers 75 for everything an operator can put right, and 67 — a
        # bounce — only for a recipient that has no feed and never will.
        #
        # Before Phase 6 the second half of this subtest would have failed: a
        # missing feed list answered 78, which is a MDA_PERMFAIL, so every
        # newsletter arriving during a bad deploy was destroyed instead of
        # queued. That is the N3 violation, and this is the assertion that
        # would have caught it.
        #
        # The envelope sender is empty throughout. A permanent failure would
        # otherwise enqueue a bounce to a domain this VM cannot reach, and that
        # bounce would sit in the queue and break every later `drained()`.

        # The bounce side, produced by the real program: DRIFTED is in
        # smtpd.conf's tables and in no feed, so `ingest` exits 67 (EX_NOUSER).
        before = eml_count()
        send("", DRIFTED)
        drained()

        # `drained()` returning at all is the assertion: the queue emptied, so
        # smtpd gave up on the envelope rather than holding it. If this hangs
        # instead, 67 is deferring and the bounce/defer line in README.md is
        # drawn in the wrong place.
        assert eml_count() == before, "an unknown recipient wrote something"

        # smtpd copies the agent's output into the log, which is the only bug
        # report a delivery ever files — and, now that a single number carries
        # every deferring failure, the only place the *reason* survives at all.
        # The message names the two files that have drifted apart.
        mail.succeed("journalctl -u opensmtpd.service | grep -q 'no feed is configured'")

        # The defer side, also produced by the real program: the same mda
        # command with its feed list pointed at a file that does not exist.
        # Everything from here on stays in the queue, which is why this subtest
        # is last.
        send("", "anything@${brokenConfigDomain}")
        mail.wait_until_succeeds(
            "journalctl -u opensmtpd.service | grep -q 'cannot read config'"
        )
        mail.succeed("smtpctl show queue | grep -q .")

        # An envelope smtpd is *holding* has a retry time in the future; one it
        # has given up on is not there at all. This is the difference between
        # "the newsletter is waiting for the operator" and "the newsletter is
        # gone", and it is the whole of N3.
        queue = mail.succeed("smtpctl show queue")
        print(queue)
        assert "${brokenConfigDomain}" in queue, (
            "a delivery that exited 75 is not in the queue: it was bounced, not deferred"
        )

        # And the control, with none of this program in the way: a stand-in
        # that reads the message and does nothing but exit 75.
        send("", "anything@${tempfailDomain}")
        mail.wait_until_succeeds(f"test -s {PROBE}/tempfail-attempts")
        mail.succeed("smtpctl show queue | grep -q .")
  '';
}
