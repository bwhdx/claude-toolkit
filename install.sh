#!/usr/bin/env bash
set -euo pipefail

# claude-toolkit installer — builds Go binaries and symlinks tools to PATH

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-$HOME/.local/bin}"

echo "claude-toolkit installer"
echo "========================"
echo "Toolkit dir: $TOOLKIT_DIR"
echo "Install dir: $INSTALL_DIR"
echo ""

# Ensure install dir exists and is in PATH
mkdir -p "$INSTALL_DIR"
if ! echo "$PATH" | tr ':' '\n' | grep -qF "$INSTALL_DIR"; then
  echo "WARNING: $INSTALL_DIR is not in your PATH"
  echo "Add this to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\""
  echo ""
fi

# Build Go binaries
echo "Building cc-monitor..."
(cd "$TOOLKIT_DIR/cc-monitor" && go build -o "$INSTALL_DIR/cc-monitor" ./cmd/cc-monitor/)

echo "Building cc-dashboard..."
(cd "$TOOLKIT_DIR/cc-dashboard" && go build -o "$INSTALL_DIR/cc-dashboard" ./cmd/cc-dashboard/)

# Symlink bash tools
echo "Linking cc-auth..."
ln -sf "$TOOLKIT_DIR/cc-auth/cc-auth" "$INSTALL_DIR/cc-auth"

echo "Linking cc-jobs..."
ln -sf "$TOOLKIT_DIR/cc-jobs/cc-jobs" "$INSTALL_DIR/cc-jobs"

# Write toolkit discovery env file so consumers can find us
ENV_DIR="$HOME/.claude-toolkit"
mkdir -p "$ENV_DIR"
cat > "$ENV_DIR/env" <<ENVEOF
CLAUDE_TOOLKIT_DIR="$TOOLKIT_DIR"
CLAUDE_TOOLKIT_VERSION="$(cd "$TOOLKIT_DIR" && git describe --tags --always 2>/dev/null || echo "dev")"
ENVEOF

echo ""
echo "Installed:"
echo "  cc-auth      → $INSTALL_DIR/cc-auth"
echo "  cc-jobs      → $INSTALL_DIR/cc-jobs"
echo "  cc-monitor   → $INSTALL_DIR/cc-monitor"
echo "  cc-dashboard → $INSTALL_DIR/cc-dashboard"
echo "  env          → $ENV_DIR/env"
echo ""
echo "Done! Run 'cc-auth init' to set up multi-account management."
