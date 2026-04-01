// Package config provides shared configuration for all claude-toolkit tools.
//
// All tools in the toolkit read from a shared config directory (~/.claude-toolkit/
// by default, overridable via CLAUDE_TOOLKIT_DIR). This package provides the
// canonical paths and any shared configuration types.
package config

import (
	"os"
	"path/filepath"
)

// Dir returns the toolkit configuration directory.
// Uses CLAUDE_TOOLKIT_DIR env var if set, otherwise ~/.claude-toolkit/.
func Dir() string {
	if dir := os.Getenv("CLAUDE_TOOLKIT_DIR"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), ".claude-toolkit")
	}
	return filepath.Join(home, ".claude-toolkit")
}

// CCAuthDir returns the cc-auth vault directory.
// Uses CC_AUTH_DIR env var if set, otherwise ~/.cc-auth/.
func CCAuthDir() string {
	if dir := os.Getenv("CC_AUTH_DIR"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), ".cc-auth")
	}
	return filepath.Join(home, ".cc-auth")
}

// ClaudeDir returns the Claude Code configuration directory (~/.claude/).
func ClaudeDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), ".claude")
	}
	return filepath.Join(home, ".claude")
}

// SessionsDir returns the Claude Code sessions directory.
func SessionsDir() string {
	return filepath.Join(ClaudeDir(), "sessions")
}

// AXDir returns the autonomous-executor directory, if detectable.
// Uses AX_DIR env var only — no hardcoded fallback paths.
func AXDir() string {
	return os.Getenv("AX_DIR")
}

// AXRegistryPath returns the path to the ax registry.json, or empty string.
func AXRegistryPath() string {
	dir := AXDir()
	if dir == "" {
		return ""
	}
	p := filepath.Join(dir, "registry.json")
	if _, err := os.Stat(p); err != nil {
		return ""
	}
	return p
}
