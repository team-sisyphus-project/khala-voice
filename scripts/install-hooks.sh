#!/usr/bin/env bash
#
# git 훅 설치 — 커밋 단계에서 시크릿을 막는다.
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
  echo "⚠️  gitleaks 가 설치되어 있지 않아 시크릿 검사를 건너뜁니다."
  echo "    이 리포는 공개될 예정이라 반드시 설치하세요:  brew install gitleaks"
  exit 0
fi

echo "🔎 시크릿 검사 중..."
if ! gitleaks protect --staged --redact --config "$(git rev-parse --show-toplevel)/.gitleaks.toml"; then
  echo ""
  echo "❌ 커밋에 시크릿으로 보이는 값이 있습니다. 커밋을 중단합니다."
  echo "   오탐이면 .gitleaks.toml 의 allowlist 에 추가하세요."
  exit 1
fi
HOOK_EOF

chmod +x "$HOOK"
echo "✅ pre-commit 훅 설치됨: $HOOK"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo ""
  echo "⚠️  gitleaks 가 없습니다. 설치하세요:"
  echo "      brew install gitleaks"
fi
