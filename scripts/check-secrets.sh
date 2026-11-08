#!/bin/sh
# Fails if anything that looks like a key is staged (default) or tracked (--all).
# Uses gitleaks when installed, otherwise a pattern scan.
# To run it on every commit:  git config core.hooksPath .githooks
set -eu
cd "$(git rev-parse --show-toplevel)"

if command -v gitleaks >/dev/null 2>&1; then
  if [ "${1:-}" = "--all" ]; then exec gitleaks detect --no-banner --redact; fi
  exec gitleaks protect --staged --no-banner --redact
fi

PATTERN='sk-[A-Za-z0-9_-]{20,}|ngt_[A-Za-z0-9_-]{20,}|ed25519:[1-9A-HJ-NP-Za-km-z]{80,}|-----BEGIN [A-Z ]*PRIVATE KEY|(NEAR_AI_API_KEY|AGENT_CONNECT_API_KEY)=[^[:space:]#]+'

if [ "${1:-}" = "--all" ]; then
  files=$(git ls-files)
else
  files=$(git diff --cached --name-only --diff-filter=ACM)
fi

status=0
for f in $files; do
  case "$f" in
    .env.example|*/.env.example) ;;
    .env|.env.*|*/.env|*/.env.*) echo "refusing to commit env file: $f"; status=1; continue ;;
  esac
  [ -f "$f" ] || continue
  if grep -qIE "$PATTERN" "$f"; then
    echo "possible secret in $f (line numbers only, values hidden):"
    grep -nIE "$PATTERN" "$f" | cut -d: -f1 | sed 's/^/  line /'
    status=1
  fi
done
[ "$status" -eq 0 ] || echo "blocked: keys belong in .env only (see .env.example)"
exit "$status"
