package discovery

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Config holds discovery configuration.
type Config struct {
	// AXRegistryPath is the path to the ax registry.json file.
	// If empty, ax integration is disabled.
	AXRegistryPath string

	// SessionDir overrides the default ~/.claude/sessions/ directory.
	SessionDir string

	// IncludeDead includes dead processes in results (marked alive=false).
	IncludeDead bool
}

// Discover finds all Claude Code instances on the machine.
func Discover(cfg Config) ([]Instance, error) {
	var (
		mu        sync.Mutex
		instances []Instance
	)

	// Resolve session directory
	sessionDir := cfg.SessionDir
	if sessionDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("get home dir: %w", err)
		}
		sessionDir = filepath.Join(home, ".claude", "sessions")
	}

	// Run discovery sources concurrently
	var wg sync.WaitGroup
	var errs []error
	var errMu sync.Mutex

	// Source 1: OS process scan
	var osPIDs map[int]string // pid -> cmdline
	wg.Add(1)
	go func() {
		defer wg.Done()
		pids, err := scanProcesses()
		if err != nil {
			errMu.Lock()
			errs = append(errs, fmt.Errorf("process scan: %w", err))
			errMu.Unlock()
			return
		}
		mu.Lock()
		osPIDs = pids
		mu.Unlock()
	}()

	// Source 2: Session files
	var sessions map[int]SessionFile // pid -> session
	wg.Add(1)
	go func() {
		defer wg.Done()
		sf, err := scanSessionFiles(sessionDir)
		if err != nil {
			errMu.Lock()
			errs = append(errs, fmt.Errorf("session scan: %w", err))
			errMu.Unlock()
			return
		}
		mu.Lock()
		sessions = sf
		mu.Unlock()
	}()

	// Source 3: AX agent files
	var axAgents map[int]axAgentWithMeta // pid -> agent info + initiative
	wg.Add(1)
	go func() {
		defer wg.Done()
		if cfg.AXRegistryPath == "" {
			return
		}
		agents, err := scanAXAgents(cfg.AXRegistryPath)
		if err != nil {
			errMu.Lock()
			errs = append(errs, fmt.Errorf("ax scan: %w", err))
			errMu.Unlock()
			return
		}
		mu.Lock()
		axAgents = agents
		mu.Unlock()
	}()

	wg.Wait()

	// Build a union of all discovered PIDs
	allPIDs := make(map[int]bool)
	for pid := range osPIDs {
		allPIDs[pid] = true
	}
	for pid := range sessions {
		allPIDs[pid] = true
	}
	for pid := range axAgents {
		allPIDs[pid] = true
	}

	now := time.Now()

	for pid := range allPIDs {
		alive := pidAlive(pid)
		if !alive && !cfg.IncludeDead {
			continue
		}

		inst := Instance{
			PID:    pid,
			Alive:  alive,
			Kind:   KindInteractive, // default
			Status: "unknown",
		}

		// Enrich from session file
		if sf, ok := sessions[pid]; ok {
			inst.SessionID = sf.SessionID
			inst.CWD = sf.CWD
			if sf.StartedAt > 0 {
				t := time.UnixMilli(sf.StartedAt)
				inst.StartedAt = &t
				inst.DurationSeconds = int(now.Sub(t).Seconds())
			}
		}

		// Enrich from command line
		if cmdline, ok := osPIDs[pid]; ok {
			inst.CommandLine = cmdline
		}

		// Classify and enrich from ax
		if agent, ok := axAgents[pid]; ok {
			inst.Kind = roleToKind(agent.Role)
			inst.AX = &AXInfo{
				Initiative: agent.Initiative,
				Phase:      agent.Phase,
				Session:    agent.Session,
				Role:       agent.Role,
			}
			if agent.Started != "" {
				t, err := time.Parse(time.RFC3339, agent.Started)
				if err == nil {
					inst.StartedAt = &t
					inst.DurationSeconds = int(now.Sub(t).Seconds())
				}
			}
		} else if inst.CommandLine != "" {
			inst.Kind = classifyFromCmdline(inst.CommandLine)
		}

		// Parse model and budget from cmdline
		if inst.CommandLine != "" {
			if model := extractFlag(inst.CommandLine, "--model"); model != "" {
				inst.Model = model
			}
			if budget := extractFlag(inst.CommandLine, "--max-budget-usd"); budget != "" {
				if b, err := strconv.ParseFloat(budget, 64); err == nil && inst.AX != nil {
					inst.AX.BudgetUSD = b
				}
			}
			if df := extractFlag(inst.CommandLine, "--debug-file"); df != "" && inst.AX != nil {
				inst.AX.DebugFile = df
			}
		}

		// Determine status
		if alive {
			inst.Status = "active"
			if inst.Kind.IsAX() {
				inst.Status = "working"
			}
		} else {
			inst.Status = "dead"
		}

		instances = append(instances, inst)
	}

	return instances, nil
}

// scanProcesses finds all running claude processes.
func scanProcesses() (map[int]string, error) {
	out, err := exec.Command("ps", "ax", "-o", "pid,args").Output()
	if err != nil {
		return nil, err
	}

	pids := make(map[int]string)
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "PID") {
			continue
		}

		// Split into PID and rest
		parts := strings.SplitN(line, " ", 2)
		if len(parts) < 2 {
			continue
		}

		pid, err := strconv.Atoi(strings.TrimSpace(parts[0]))
		if err != nil {
			continue
		}

		args := strings.TrimSpace(parts[1])

		// Filter: must be a claude process (binary name contains "claude")
		// but not our own scanning process, and not editors/grep
		if !isClaudeProcess(args) {
			continue
		}

		pids[pid] = args
	}

	return pids, nil
}

// isClaudeProcess checks if a command line represents a Claude Code process.
// The binary name "claude" must appear as the command (first field) or as a
// path-prefixed binary (e.g. /usr/local/bin/claude), not as an argument to
// another command like grep or vim.
func isClaudeProcess(cmdline string) bool {
	parts := strings.Fields(cmdline)
	if len(parts) == 0 {
		return false
	}

	// The command is the first field in ps output
	cmd := parts[0]

	// Check if the binary IS claude (exact name or path ending in /claude)
	return cmd == "claude" || strings.HasSuffix(cmd, "/claude")
}

// scanSessionFiles reads all session metadata from ~/.claude/sessions/.
func scanSessionFiles(dir string) (map[int]SessionFile, error) {
	sessions := make(map[int]SessionFile)

	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return sessions, nil
		}
		return nil, err
	}

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}

		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			continue
		}

		var sf SessionFile
		if err := json.Unmarshal(data, &sf); err != nil {
			continue
		}

		if sf.PID > 0 {
			sessions[sf.PID] = sf
		}
	}

	return sessions, nil
}

type axAgentWithMeta struct {
	AXAgentFile
	Initiative string
}

// axRegistryEntry represents one initiative in registry.json.
type axRegistryEntry struct {
	ID     string `json:"id"`
	Repo   string `json:"repo"`
	Path   string `json:"path"`
	Status string `json:"status"`
}

// scanAXAgents reads agent tracking files across all registered initiatives.
func scanAXAgents(registryPath string) (map[int]axAgentWithMeta, error) {
	agents := make(map[int]axAgentWithMeta)

	data, err := os.ReadFile(registryPath)
	if err != nil {
		if os.IsNotExist(err) {
			return agents, nil
		}
		return nil, err
	}

	var registry struct {
		Initiatives []axRegistryEntry `json:"initiatives"`
	}
	if err := json.Unmarshal(data, &registry); err != nil {
		return nil, fmt.Errorf("parse registry: %w", err)
	}

	for _, init := range registry.Initiatives {
		if init.Status != "Active" {
			continue
		}

		logsDir := filepath.Join(init.Path, "logs")
		entries, err := os.ReadDir(logsDir)
		if err != nil {
			continue
		}

		for _, entry := range entries {
			name := entry.Name()
			if !strings.HasPrefix(name, ".agent.") || !strings.HasSuffix(name, ".json") {
				continue
			}

			agentData, err := os.ReadFile(filepath.Join(logsDir, name))
			if err != nil {
				continue
			}

			var agent AXAgentFile
			if err := json.Unmarshal(agentData, &agent); err != nil {
				continue
			}

			if agent.PID > 0 {
				agents[agent.PID] = axAgentWithMeta{
					AXAgentFile: agent,
					Initiative:  init.ID,
				}
			}
		}
	}

	return agents, nil
}

// classifyFromCmdline determines instance kind from the process command line.
func classifyFromCmdline(cmdline string) Kind {
	// Headless detection: -p flag with stream-json output
	if strings.Contains(cmdline, " -p ") && strings.Contains(cmdline, "--output-format") {
		return KindHeadless
	}
	// Simpler headless detection: just -p flag
	if strings.Contains(cmdline, " -p ") || strings.Contains(cmdline, " --print ") {
		return KindHeadless
	}
	return KindInteractive
}

// roleToKind maps an ax agent role to a Kind.
func roleToKind(role string) Kind {
	switch role {
	case "worker":
		return KindAXWorker
	case "gate":
		return KindAXGate
	case "gate_fix", "gate-fix":
		return KindAXGateFix
	case "supervisor":
		return KindAXSupervisor
	case "final_review", "final-review":
		return KindAXFinalReview
	default:
		return KindAXWorker
	}
}

// extractFlag extracts the value after a CLI flag from a command line string.
func extractFlag(cmdline, flag string) string {
	idx := strings.Index(cmdline, flag+" ")
	if idx == -1 {
		idx = strings.Index(cmdline, flag+"=")
		if idx == -1 {
			return ""
		}
		return strings.Fields(cmdline[idx+len(flag)+1:])[0]
	}
	rest := cmdline[idx+len(flag)+1:]
	fields := strings.Fields(rest)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

// pidAlive checks if a process is running.
func pidAlive(pid int) bool {
	process, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = process.Signal(syscall.Signal(0))
	return err == nil
}
