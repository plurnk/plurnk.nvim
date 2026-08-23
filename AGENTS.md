# plurnk.nvim Agent Guidance

Read `../POSSUMTECH.md` before working in this repository. Stop if it is
unavailable.

This repository owns the open-source PLURNK Neovim client. Preserve the
client boundary: it consumes `plurnk-service` through the public AG-UI+
contract and does not depend on the terminal client as a subprocess.


## Releasing

The complete source-release gate and tag contract (nvim#5):

1. **Gate**: clean, signed `main` on canonical Gitea; `./tests/runner.sh`
   green against the sibling accepted `../plurnk-service` checkout. There is
   no other artifact — no npm ceremony for a source-consumed plugin.
2. **Tag**: a GPG-signed annotated tag `vX.Y.0` created on the canonical
   Gitea source. First message line `PLURNK.nvim X.Y.0`; add one line naming
   the platform the suite exercised, e.g.
   `exercised: @plurnk/plurnk-service@1.8.0 · @plurnk/plurnk@0.75.0`.
   Next release after v0.28.0 is v0.29.0; pre-1.0 breaking changes advance
   the minor like any other release.
3. **Mirror**: push `main` and the tag unchanged to the GitHub mirror.
   Tags are created on Gitea only, never on the mirror first.
4. **Immutability**: published tags are never moved or deleted. Historic
   lightweight tags (through v0.27.0, including the mis-ordered `v0.2.0`
   of 2026-07-10) stay as they are — being lightweight they are invisible
   to plain `git describe`, which resolves from the signed v0.28.0+ line.
