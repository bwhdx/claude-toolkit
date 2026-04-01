package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/bwhdx/claude-toolkit/cc-monitor/pkg/discovery"
)

// ── Styles ───────────────────────────────────────────────────────────────────

var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#FAFAFA")).
			Background(lipgloss.Color("#7D56F4")).
			Padding(0, 1)

	headerStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#FAFAFA")).
			MarginBottom(1)

	sectionStyle = lipgloss.NewStyle().
			BorderStyle(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("#555")).
			Padding(0, 1).
			MarginBottom(1)

	kindAXStyle          = lipgloss.NewStyle().Foreground(lipgloss.Color("#00BFFF"))
	kindInteractiveStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#00FF88"))
	kindHeadlessStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFAA00"))

	statusWorkingStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#00FF88"))
	statusActiveStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#00FF88"))
	statusDeadStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("#FF4444"))

	dimStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#666"))
	acctStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#00BFFF"))

	activeIndicator  = lipgloss.NewStyle().Foreground(lipgloss.Color("#00FF88")).Render("●")
	limitedIndicator = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFAA00")).Render("○")
	availIndicator   = lipgloss.NewStyle().Foreground(lipgloss.Color("#555")).Render("○")

	helpStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#555"))
)

// ── Messages ─────────────────────────────────────────────────────────────────

type tickMsg time.Time
type instancesMsg []discovery.Instance
type authMsg *discovery.AuthStatus
type accountsMsg []accountEntry

type accountEntry struct {
	Name    string `json:"name"`
	Email   string `json:"email"`
	Status  string `json:"status"`
	Limited bool   `json:"limited"`
}

// ── Model ────────────────────────────────────────────────────────────────────

type model struct {
	instances []discovery.Instance
	auth      *discovery.AuthStatus
	accounts  []accountEntry
	cfg       discovery.Config
	width     int
	height    int
	lastTick  time.Time
	quitting  bool
	interval  time.Duration
}

func initialModel(cfg discovery.Config, interval time.Duration) model {
	return model{
		cfg:      cfg,
		interval: interval,
		lastTick: time.Now(),
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(
		fetchInstances(m.cfg),
		fetchAuth(),
		fetchAccounts(),
		tick(m.interval),
	)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c", "esc":
			m.quitting = true
			return m, tea.Quit
		case "r":
			return m, tea.Batch(fetchInstances(m.cfg), fetchAuth(), fetchAccounts())
		}

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tickMsg:
		m.lastTick = time.Time(msg)
		return m, tea.Batch(
			fetchInstances(m.cfg),
			fetchAuth(),
			fetchAccounts(),
			tick(m.interval),
		)

	case instancesMsg:
		m.instances = []discovery.Instance(msg)

	case authMsg:
		m.auth = (*discovery.AuthStatus)(msg)

	case accountsMsg:
		m.accounts = []accountEntry(msg)
	}

	return m, nil
}

func (m model) View() string {
	if m.quitting {
		return ""
	}

	var b strings.Builder

	// Title bar
	title := titleStyle.Render(" CLAUDE CODE DASHBOARD ")
	timestamp := dimStyle.Render(m.lastTick.Format("2006-01-02 15:04:05"))

	// Account info
	accountInfo := ""
	if m.auth != nil && m.auth.LoggedIn {
		accountInfo = fmt.Sprintf("  Account: %s (%s)",
			acctStyle.Render(m.auth.Email),
			m.auth.SubscriptionType)
	}

	b.WriteString(title + "  " + timestamp + accountInfo + "\n\n")

	// Instances section
	b.WriteString(m.renderInstances())

	// Accounts section (if cc-auth is available)
	if len(m.accounts) > 0 {
		b.WriteString(m.renderAccounts())
	}

	// Help bar
	b.WriteString(helpStyle.Render("  [q] quit  [r] refresh") + "\n")

	return b.String()
}

func (m model) renderInstances() string {
	var b strings.Builder

	// Sort instances: ax first, then by PID
	instances := make([]discovery.Instance, len(m.instances))
	copy(instances, m.instances)
	sort.Slice(instances, func(i, j int) bool {
		iAX := instances[i].Kind.IsAX()
		jAX := instances[j].Kind.IsAX()
		if iAX != jAX {
			return iAX
		}
		return instances[i].PID < instances[j].PID
	})

	header := headerStyle.Render(fmt.Sprintf("  ACTIVE INSTANCES (%d)", len(instances)))
	b.WriteString(header + "\n")

	if len(instances) == 0 {
		b.WriteString(dimStyle.Render("  No Claude Code instances running.") + "\n\n")
		return b.String()
	}

	// Table header
	b.WriteString(dimStyle.Render(fmt.Sprintf("  %-8s %-16s %-38s %8s  %-8s", "PID", "KIND", "CWD", "DURATION", "STATUS")) + "\n")

	for _, inst := range instances {
		kind := renderKind(inst.Kind)
		status := renderStatus(inst.Status)
		cwd := shortenPath(inst.CWD, 38)
		dur := formatDuration(inst.DurationSeconds)

		b.WriteString(fmt.Sprintf("  %-8d %s %-38s %8s  %s\n",
			inst.PID, padRight(kind, 16), cwd, dur, status))

		if inst.AX != nil {
			detail := fmt.Sprintf("└─ %s", inst.AX.Initiative)
			if inst.AX.Phase != "" {
				detail += fmt.Sprintf("  P%s", inst.AX.Phase)
			}
			if inst.AX.Session != "" {
				detail += fmt.Sprintf("/S%s", inst.AX.Session)
			}
			if inst.Model != "" {
				detail += fmt.Sprintf("  %s", inst.Model)
			}
			if inst.AX.BudgetUSD > 0 {
				detail += fmt.Sprintf("/$%.0f", inst.AX.BudgetUSD)
			}
			b.WriteString(dimStyle.Render(fmt.Sprintf("  %8s %s", "", detail)) + "\n")
		}
	}
	b.WriteString("\n")

	return b.String()
}

func (m model) renderAccounts() string {
	var b strings.Builder

	header := headerStyle.Render(fmt.Sprintf("  ACCOUNTS (%d)", len(m.accounts)))
	b.WriteString(header + "\n")

	for _, acct := range m.accounts {
		indicator := availIndicator
		statusStr := dimStyle.Render("available")
		switch acct.Status {
		case "active":
			indicator = activeIndicator
			statusStr = statusActiveStyle.Render("ACTIVE")
		case "limited":
			indicator = limitedIndicator
			statusStr = kindHeadlessStyle.Render("limited")
		}

		email := acct.Email
		if len(email) > 28 {
			email = email[:25] + "..."
		}

		b.WriteString(fmt.Sprintf("  %s %-12s %-28s %s\n",
			indicator, acct.Name, email, statusStr))
	}
	b.WriteString("\n")

	return b.String()
}

// ── Commands ─────────────────────────────────────────────────────────────────

func tick(d time.Duration) tea.Cmd {
	return tea.Tick(d, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

func fetchInstances(cfg discovery.Config) tea.Cmd {
	return func() tea.Msg {
		instances, err := discovery.Discover(cfg)
		if err != nil {
			return instancesMsg(nil)
		}
		return instancesMsg(instances)
	}
}

func fetchAuth() tea.Cmd {
	return func() tea.Msg {
		out, err := exec.Command("claude", "auth", "status").Output()
		if err != nil {
			return authMsg(nil)
		}
		var status discovery.AuthStatus
		if err := json.Unmarshal(out, &status); err != nil {
			return authMsg(nil)
		}
		return authMsg(&status)
	}
}

func fetchAccounts() tea.Cmd {
	return func() tea.Msg {
		// Try to find cc-auth and get account list
		ccAuth := findCCAuth()
		if ccAuth == "" {
			return accountsMsg(nil)
		}

		out, err := exec.Command(ccAuth, "list", "--json").Output()
		if err != nil {
			return accountsMsg(nil)
		}

		var accounts []accountEntry
		if err := json.Unmarshal(out, &accounts); err != nil {
			return accountsMsg(nil)
		}
		return accountsMsg(accounts)
	}
}

func findCCAuth() string {
	// Check PATH first
	if p, err := exec.LookPath("cc-auth"); err == nil {
		return p
	}
	// Check sibling directory
	exe, err := os.Executable()
	if err == nil {
		sibling := filepath.Join(filepath.Dir(exe), "..", "cc-auth", "cc-auth")
		if _, err := os.Stat(sibling); err == nil {
			return sibling
		}
	}
	// Check relative to working dir
	home, _ := os.UserHomeDir()
	candidates := []string{
		filepath.Join(home, "Code", "claude-toolkit", "cc-auth", "cc-auth"),
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}

// ── Helpers ──────────────────────────────────────────────────────────────────

func renderKind(k discovery.Kind) string {
	s := string(k)
	if k.IsAX() {
		return kindAXStyle.Render(s)
	}
	switch k {
	case discovery.KindInteractive:
		return kindInteractiveStyle.Render(s)
	case discovery.KindHeadless:
		return kindHeadlessStyle.Render(s)
	default:
		return s
	}
}

func renderStatus(status string) string {
	switch status {
	case "working":
		return statusWorkingStyle.Render(status)
	case "active":
		return statusActiveStyle.Render(status)
	case "dead":
		return statusDeadStyle.Render(status)
	default:
		return status
	}
}

func padRight(s string, n int) string {
	// Account for ANSI escape codes in length calculation
	visible := stripAnsi(s)
	pad := n - len(visible)
	if pad <= 0 {
		return s
	}
	return s + strings.Repeat(" ", pad)
}

func stripAnsi(s string) string {
	var result strings.Builder
	inEscape := false
	for _, r := range s {
		if r == '\033' {
			inEscape = true
			continue
		}
		if inEscape {
			if r == 'm' {
				inEscape = false
			}
			continue
		}
		result.WriteRune(r)
	}
	return result.String()
}

func shortenPath(p string, maxLen int) string {
	if p == "" {
		return "-"
	}
	home, _ := os.UserHomeDir()
	if strings.HasPrefix(p, home) {
		p = "~" + p[len(home):]
	}
	if len(p) > maxLen {
		p = "..." + p[len(p)-maxLen+3:]
	}
	return p
}

func formatDuration(seconds int) string {
	if seconds <= 0 {
		return "-"
	}
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	if seconds < 3600 {
		return fmt.Sprintf("%dm", seconds/60)
	}
	h := seconds / 3600
	m := (seconds % 3600) / 60
	return fmt.Sprintf("%dh%dm", h, m)
}

// ── Main ─────────────────────────────────────────────────────────────────────

func main() {
	cfg := discovery.Config{}

	// Auto-detect ax registry via AX_DIR env var
	axDir := os.Getenv("AX_DIR")
	if axDir != "" {
		regPath := filepath.Join(axDir, "registry.json")
		if _, err := os.Stat(regPath); err == nil {
			cfg.AXRegistryPath = regPath
		}
	}

	interval := 5 * time.Second
	if len(os.Args) > 1 {
		for i, arg := range os.Args[1:] {
			if arg == "--interval" && i+2 < len(os.Args) {
				if d, err := time.ParseDuration(os.Args[i+2] + "s"); err == nil {
					interval = d
				}
			}
		}
	}

	p := tea.NewProgram(
		initialModel(cfg, interval),
		tea.WithAltScreen(),
	)

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
