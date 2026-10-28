#!/usr/bin/env bash
# End-to-end test entrypoint: evaluates the module against pinned options,
# generates the exact shell script the systemd unit would run, and executes it
# against a local HTTP server inside an unprivileged user+network namespace
# (ipset/iptables work there without root).
#
# This MUST run OUTSIDE the sandbox (user shell, CI workflow step): the nix
# build sandbox blocks unshare/netns, so it is deliberately NOT a flake check.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
outdir="$(mktemp -d)"; trap 'rm -rf "$outdir"' EXIT

# pinned flake HEAD of the checkout — never a copied store path
eval_nix="$here/eval.nix"
ev() { nix eval --impure --expr "(import $eval_nix { repo = \"$repo\"; ${1:-} }).script" --raw; }
ev_stop() { nix eval --impure --expr "(import $eval_nix { repo = \"$repo\"; }).postStop" --raw; }

# s1 installs with maxElem 4096; s2 (module default) exercises option-change commit
ev "maxElem = 4096;" > "$outdir/s1.sh"
ev "" > "$outdir/s2.sh"
ev "blocklistedIPs = [ ];" > "$outdir/s3.sh"
ev "blockDirection = \"inbound\";" > "$outdir/s4.sh"

ev_stop > "$outdir/stop.sh" # generated ExecStopPost for the upgrade-teardown test

# tools from the flake-locked devShell; `nix develop` gives the same env for
# debugging, but `nix flake check` does NOT build devShells
nix develop "${repo}#default" -c unshare -Urn bash "$here/run.sh" \
  "$outdir/s1.sh" "$outdir/s2.sh" "$outdir/s3.sh" "$outdir" "$outdir/s4.sh" "$outdir/stop.sh"
