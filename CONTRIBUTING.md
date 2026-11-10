# Contributing

Thanks for looking. TannX OS is small on purpose, so the rules are short.

- **One change per commit.** A commit does one thing and its message
  says why. Keep refactors and features apart.
- **`make test-all` must be green** before you commit. The gate is 49
  headless QEMU suites and takes several minutes; run a single suite
  (`make test-script`, `make test-usb-fat`, ...) while iterating and the
  whole gate before you push. Add a check to the gate for anything you
  add to the OS - a feature without a test does not ship.
- **ASCII only**, in OS strings and in documentation. No emoji, no
  box-drawing characters (use `-->`, `<--`, `^`, `v` in diagrams).
  Code, comments and docs are in English.
- **Protected strings**: `test.sh` greps the banner word, the prompt,
  the agent/task status words and a few messages. Change them only
  together with the test (`docs/ARCHITECTURE.md`, iron rule 2).
- **Size budget**: the kernel content must stay under 131072 bytes.
  Check the sentinel in the last sector, not just the build succeeding.
- **Honesty about hardware.** Say in the commit message whether a change
  was verified in QEMU only or also on a real machine. Never claim a
  bare-metal result you did not see.
- **Security model**: read `SECURITY.md` before touching the network
  paths, the syscall gate or the remote-control code. Anything that
  weakens the stated model needs a very good reason in the commit body.
- **Wishes**: a feature idea is best filed as a `wish <text>` in the
  running OS or as an issue. If you build one, log it in Part 3 of
  `docs/HISTORY.md`.

Bug reports: a serial log (`make test32` style, `-nographic`) and the
version from the boot banner help most. Security issues: see
`SECURITY.md`.

## Licensing of contributions

- **Inbound = outbound.** By submitting a contribution you license it
  under the project license, GPL-3.0-or-later.
- **Relicensing.** You also grant Tannenbaum Media a perpetual,
  worldwide, non-exclusive, royalty-free right to distribute your
  contribution under another license approved by the Open Source
  Initiative (for example MIT), so the project can change its license
  later without tracking down every contributor. Your contribution
  always stays available under GPL-3.0-or-later as well.
- **Sign-off (DCO).** Sign every commit with `git commit -s`. The
  `Signed-off-by:` line certifies the Developer Certificate of Origin
  1.1 (https://developercertificate.org): you wrote the change, or have
  the right to submit it under these terms.
- The name "TannX" and the fir-tree logo are not part of the license
  (see `NOTICE` and `THIRD_PARTY.md`); please do not use them for forks.
