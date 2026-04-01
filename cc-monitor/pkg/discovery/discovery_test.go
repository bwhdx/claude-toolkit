package discovery

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSessionFileParsing(t *testing.T) {
	dir := t.TempDir()

	// Write a valid session file
	sf := SessionFile{
		PID:       12345,
		SessionID: "test-session-uuid",
		CWD:       "/Users/test/project",
		StartedAt: 1743523200000, // epoch ms
	}
	data, _ := json.Marshal(sf)
	os.WriteFile(filepath.Join(dir, "12345.json"), data, 0644)

	sessions, err := scanSessionFiles(dir)
	if err != nil {
		t.Fatalf("scanSessionFiles error: %v", err)
	}

	if len(sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(sessions))
	}

	s, ok := sessions[12345]
	if !ok {
		t.Fatal("session for PID 12345 not found")
	}
	if s.SessionID != "test-session-uuid" {
		t.Errorf("expected session ID 'test-session-uuid', got '%s'", s.SessionID)
	}
	if s.CWD != "/Users/test/project" {
		t.Errorf("expected CWD '/Users/test/project', got '%s'", s.CWD)
	}
}

func TestSessionFileParsingIgnoresInvalid(t *testing.T) {
	dir := t.TempDir()

	// Write invalid JSON
	os.WriteFile(filepath.Join(dir, "bad.json"), []byte("not json"), 0644)
	// Write non-JSON file
	os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("hello"), 0644)
	// Write valid but empty PID
	os.WriteFile(filepath.Join(dir, "empty.json"), []byte(`{"pid":0}`), 0644)

	sessions, err := scanSessionFiles(dir)
	if err != nil {
		t.Fatalf("scanSessionFiles error: %v", err)
	}

	if len(sessions) != 0 {
		t.Fatalf("expected 0 sessions, got %d", len(sessions))
	}
}

func TestSessionFileParsingMissingDir(t *testing.T) {
	sessions, err := scanSessionFiles("/nonexistent/path")
	if err != nil {
		t.Fatalf("should not error on missing dir: %v", err)
	}
	if len(sessions) != 0 {
		t.Fatalf("expected empty map, got %d sessions", len(sessions))
	}
}

func TestClassifyFromCmdline(t *testing.T) {
	tests := []struct {
		cmdline string
		want    Kind
	}{
		{"claude -p --output-format stream-json --verbose", KindHeadless},
		{"claude -p some prompt", KindHeadless},
		{"claude --print some prompt", KindHeadless},
		{"claude", KindInteractive},
		{"/usr/local/bin/claude", KindInteractive},
	}

	for _, tt := range tests {
		got := classifyFromCmdline(tt.cmdline)
		if got != tt.want {
			t.Errorf("classifyFromCmdline(%q) = %q, want %q", tt.cmdline, got, tt.want)
		}
	}
}

func TestRoleToKind(t *testing.T) {
	tests := []struct {
		role string
		want Kind
	}{
		{"worker", KindAXWorker},
		{"gate", KindAXGate},
		{"gate_fix", KindAXGateFix},
		{"gate-fix", KindAXGateFix},
		{"supervisor", KindAXSupervisor},
		{"final_review", KindAXFinalReview},
		{"final-review", KindAXFinalReview},
		{"unknown", KindAXWorker},
	}

	for _, tt := range tests {
		got := roleToKind(tt.role)
		if got != tt.want {
			t.Errorf("roleToKind(%q) = %q, want %q", tt.role, got, tt.want)
		}
	}
}

func TestKindIsAX(t *testing.T) {
	axKinds := []Kind{KindAXWorker, KindAXGate, KindAXGateFix, KindAXSupervisor, KindAXFinalReview}
	for _, k := range axKinds {
		if !k.IsAX() {
			t.Errorf("%q.IsAX() = false, want true", k)
		}
	}

	nonAXKinds := []Kind{KindInteractive, KindHeadless, KindIDE}
	for _, k := range nonAXKinds {
		if k.IsAX() {
			t.Errorf("%q.IsAX() = true, want false", k)
		}
	}
}

func TestExtractFlag(t *testing.T) {
	cmdline := "claude -p --model sonnet --max-budget-usd 50 --debug-file /tmp/out.log prompt"

	if got := extractFlag(cmdline, "--model"); got != "sonnet" {
		t.Errorf("extractFlag --model = %q, want 'sonnet'", got)
	}
	if got := extractFlag(cmdline, "--max-budget-usd"); got != "50" {
		t.Errorf("extractFlag --max-budget-usd = %q, want '50'", got)
	}
	if got := extractFlag(cmdline, "--debug-file"); got != "/tmp/out.log" {
		t.Errorf("extractFlag --debug-file = %q, want '/tmp/out.log'", got)
	}
	if got := extractFlag(cmdline, "--nonexistent"); got != "" {
		t.Errorf("extractFlag --nonexistent = %q, want ''", got)
	}
}

func TestAXAgentFileParsing(t *testing.T) {
	dir := t.TempDir()
	initDir := filepath.Join(dir, "logs")
	os.MkdirAll(initDir, 0755)

	// Write agent tracking file
	agent := AXAgentFile{
		PID:     54321,
		Role:    "worker",
		Phase:   "2",
		Session: "2A",
		Started: "2026-04-01T15:30:00Z",
	}
	data, _ := json.Marshal(agent)
	os.WriteFile(filepath.Join(initDir, ".agent.54321.json"), data, 0644)

	// Write registry
	registry := map[string]interface{}{
		"initiatives": []map[string]interface{}{
			{
				"id":     "test-initiative",
				"repo":   "/tmp/repo",
				"path":   dir,
				"status": "Active",
			},
		},
	}
	regData, _ := json.Marshal(registry)
	regPath := filepath.Join(dir, "registry.json")
	os.WriteFile(regPath, regData, 0644)

	agents, err := scanAXAgents(regPath)
	if err != nil {
		t.Fatalf("scanAXAgents error: %v", err)
	}

	if len(agents) != 1 {
		t.Fatalf("expected 1 agent, got %d", len(agents))
	}

	a, ok := agents[54321]
	if !ok {
		t.Fatal("agent for PID 54321 not found")
	}
	if a.Role != "worker" {
		t.Errorf("expected role 'worker', got '%s'", a.Role)
	}
	if a.Initiative != "test-initiative" {
		t.Errorf("expected initiative 'test-initiative', got '%s'", a.Initiative)
	}
}

func TestIsClaudeProcess(t *testing.T) {
	tests := []struct {
		cmdline string
		want    bool
	}{
		{"/usr/local/bin/claude -p --model sonnet", true},
		{"claude -p some prompt", true},
		{"/opt/homebrew/bin/claude", true},
		{"grep claude somefile", false},
		{"vim /path/to/claude.md", false},
		{"node /usr/lib/python", false},
		{"", false},
	}

	for _, tt := range tests {
		got := isClaudeProcess(tt.cmdline)
		if got != tt.want {
			t.Errorf("isClaudeProcess(%q) = %v, want %v", tt.cmdline, got, tt.want)
		}
	}
}
