#!/usr/bin/env bash
#
# Install git hooks — blocks secrets at commit time.
#
#   ./scripts/install-hooks.sh
#
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.git/hooks/pre-commit"

cat > "$HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
set -euo pipefail

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "⚠️  gitleaks is not installed; skipping the secret scan."
  echo "    This repo will be made public — please install it:  brew install gitleaks"
  exit 0
fi

echo "🔎 Scanning for secrets..."
if ! gitleaks protect --staged --redact --config "$(git rev-parse --show-toplevel)/.gitleaks.toml"; then
  echo ""
  echo "❌ The commit contains what looks like a secret. Aborting the commit."
  echo "   If it is a false positive, add it to the allowlist in .gitleaks.toml."
  exit 1
fi
HOOK_EOF

chmod +x "$HOOK"
echo "✅ pre-commit hook installed: $HOOK"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo ""
  echo "⚠️  gitleaks is missing. Install it:"
  echo "      brew install gitleaks"
fi
