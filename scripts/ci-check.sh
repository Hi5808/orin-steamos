#!/bin/bash
# Fast checks that need no image build: shell syntax, shellcheck, unit tests, and a
# scan for secrets / personal data. Used by CI (.github/workflows/ci.yml) and locally.
# usage: scripts/ci-check.sh            (gitleaks is used if installed)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0
step() { printf '\n== %s\n' "$*"; }
run() { if "$@"; then echo "ok: $*"; else echo "FAIL: $*"; fail=1; fi; }

mapfile -t sh_files < <(
  { ls build.sh flash.sh scripts/*.sh
    grep -rlE '^#!/bin/(ba)?sh' overlay/usr/bin overlay/usr/lib/steamos-orin 2>/dev/null; } | sort -u)

step "bash -n (${#sh_files[@]} files)"
for f in "${sh_files[@]}"; do bash -n "$f" || { echo "syntax error: $f"; fail=1; }; done
step "shellcheck"
if command -v shellcheck >/dev/null; then run shellcheck -x config.env "${sh_files[@]}"
else echo "shellcheck not installed (skipped)"; fi

step "unit tests"
if command -v node >/dev/null; then run node scripts/test-polkit-rules.js overlay/etc/polkit-1/rules.d/49-steamos-orin.rules
else echo "node not installed (polkit test skipped)"; fi
run python3 scripts/test-oom-tagger.py overlay/usr/lib/steamos-orin/oom-tagger
run python3 -c "import ast;ast.parse(open('overlay/usr/lib/steamos-orin/oom-tagger').read())"

step "secrets / personal data (tracked files)"
# Generic patterns only; add your own identifiers via EXTRA_PRIVATE_PATTERNS='name1|name2'.
pat='BEGIN [A-Z ]*PRIVATE KEY|tskey-[a-z]+-|(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+) AAAA[0-9A-Za-z+/]{40,}|^\s*psk\s*=|password\s*[:=]\s*["'"'"']?[A-Za-z0-9]{8,}'
[[ -n ${EXTRA_PRIVATE_PATTERNS:-} ]] && pat="$pat|$EXTRA_PRIVATE_PATTERNS"
if git ls-files -z | xargs -0 grep -nIiE "$pat" -- 2>/dev/null | grep -v '^scripts/ci-check.sh:' | grep -v '^.gitleaks.toml:'; then
  echo "FAIL: possible secret or personal data above"; fail=1
else echo "ok: no matches"; fi
for f in $(git ls-files); do
  case "$f" in *.img|*.img.raw|*.tar.*|*.tbz2|*.zip|*.ko|SECRETS.txt|*/SECRETS.txt) echo "FAIL: build artifact tracked: $f"; fail=1 ;; esac
done
if command -v gitleaks >/dev/null; then
  run gitleaks git --config .gitleaks.toml --redact --no-banner .
else echo "gitleaks not installed (skipped)"; fi

echo; if (( fail )); then echo "ci-check: FAILED"; exit 1; else echo "ci-check: all passed"; fi
