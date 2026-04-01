// Package discovery provides types and functions for finding Claude Code processes.
package discovery

import "time"

// Instance represents a discovered Claude Code process.
type Instance struct {
	PID             int        `json:"pid"`
	Alive           bool       `json:"alive"`
	Kind            Kind       `json:"kind"`
	CWD             string     `json:"cwd"`
	SessionID       string     `json:"session_id,omitempty"`
	StartedAt       *time.Time `json:"started_at,omitempty"`
	DurationSeconds int        `json:"duration_seconds"`
	Account         string     `json:"account,omitempty"`
	Model           string     `json:"model,omitempty"`
	Status          string     `json:"status"`
	CommandLine     string     `json:"-"` // raw cmdline, not exported to JSON
	AX              *AXInfo    `json:"ax,omitempty"`
}

// AXInfo contains metadata specific to instances managed by the autonomous-executor.
type AXInfo struct {
	Initiative string  `json:"initiative"`
	Phase      string  `json:"phase"`
	Session    string  `json:"session"`
	Role       string  `json:"role"`
	BudgetUSD  float64 `json:"budget_usd,omitempty"`
	DebugFile  string  `json:"debug_file,omitempty"`
}

// Kind classifies a Claude Code instance.
type Kind string

const (
	KindInteractive   Kind = "interactive"
	KindHeadless      Kind = "headless"
	KindIDE           Kind = "ide"
	KindAXWorker      Kind = "ax-worker"
	KindAXGate        Kind = "ax-gate"
	KindAXGateFix     Kind = "ax-gate-fix"
	KindAXSupervisor  Kind = "ax-supervisor"
	KindAXFinalReview Kind = "ax-final-review"
)

// IsAX returns true if this kind represents an ax-managed instance.
func (k Kind) IsAX() bool {
	switch k {
	case KindAXWorker, KindAXGate, KindAXGateFix, KindAXSupervisor, KindAXFinalReview:
		return true
	}
	return false
}

// SessionFile represents a Claude Code session metadata file (~/.claude/sessions/*.json).
type SessionFile struct {
	PID       int    `json:"pid"`
	SessionID string `json:"sessionId"`
	CWD       string `json:"cwd"`
	StartedAt int64  `json:"startedAt"` // epoch ms
}

// AXAgentFile represents an ax per-PID agent tracking file (.agent.{pid}.json).
type AXAgentFile struct {
	PID     int    `json:"pid"`
	Role    string `json:"role"`
	Phase   string `json:"phase,omitempty"`
	Session string `json:"session,omitempty"`
	Started string `json:"started,omitempty"`
}

// AuthStatus represents the output of `claude auth status`.
type AuthStatus struct {
	LoggedIn         bool   `json:"loggedIn"`
	AuthMethod       string `json:"authMethod"`
	APIProvider      string `json:"apiProvider"`
	Email            string `json:"email"`
	OrgID            string `json:"orgId"`
	OrgName          string `json:"orgName"`
	SubscriptionType string `json:"subscriptionType"`
}
