package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/bwhdx/claude-toolkit/cc-monitor/pkg/discovery"
)

var (
	jsonOutput  = flag.Bool("json", false, "Output as JSON")
	watch       = flag.Bool("watch", false, "Continuously refresh")
	interval    = flag.Int("interval", 5, "Refresh interval in seconds (with --watch)")
	kindFilter  = flag.String("kind", "", "Filter by kind (ax, interactive, headless)")
	includeDead = flag.Bool("include-dead", false, "Include dead processes")
)

func main() {
	flag.Parse()

	cfg := buildConfig()

	if *watch {
		runWatch(cfg)
	} else {
		instances, err := discovery.Discover(cfg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		instances = filterInstances(instances)
		render(instances)
	}
}

func buildConfig() discovery.Config {
	cfg := discovery.Config{
		IncludeDead: *includeDead,
	}

	// Auto-detect ax registry via AX_DIR env var
	axDir := os.Getenv("AX_DIR")
	if axDir == "" {
		// No env var set — ax integration disabled
	} else {
		cfg.AXRegistryPath = filepath.Join(axDir, "registry.json")
	}

	return cfg
}

func filterInstances(instances []discovery.Instance) []discovery.Instance {
	if *kindFilter == "" {
		return instances
	}

	var filtered []discovery.Instance
	for _, inst := range instances {
		switch *kindFilter {
		case "ax":
			if inst.Kind.IsAX() {
				filtered = append(filtered, inst)
			}
		case "interactive":
			if inst.Kind == discovery.KindInteractive {
				filtered = append(filtered, inst)
			}
		case "headless":
			if inst.Kind == discovery.KindHeadless {
				filtered = append(filtered, inst)
			}
		default:
			if string(inst.Kind) == *kindFilter {
				filtered = append(filtered, inst)
			}
		}
	}
	return filtered
}

func runWatch(cfg discovery.Config) {
	for {
		if !*jsonOutput {
			// Clear screen
			fmt.Print("\033[2J\033[H")
		}

		instances, err := discovery.Discover(cfg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		} else {
			instances = filterInstances(instances)
			render(instances)
		}

		time.Sleep(time.Duration(*interval) * time.Second)
	}
}

func render(instances []discovery.Instance) {
	if *jsonOutput {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		enc.Encode(instances)
		return
	}

	renderTable(instances)
}

func renderTable(instances []discovery.Instance) {
	// Sort: ax instances first, then by PID
	sort.Slice(instances, func(i, j int) bool {
		iAX := instances[i].Kind.IsAX()
		jAX := instances[j].Kind.IsAX()
		if iAX != jAX {
			return iAX
		}
		return instances[i].PID < instances[j].PID
	})

	now := time.Now().Format("2006-01-02 15:04")

	// Header
	fmt.Printf("\033[1mCLAUDE CODE INSTANCES\033[0m — %s\n", now)
	fmt.Println()

	if len(instances) == 0 {
		fmt.Println("  No Claude Code instances found.")
		return
	}

	// Count by kind
	counts := make(map[string]int)
	for _, inst := range instances {
		if inst.Kind.IsAX() {
			counts["ax"]++
		} else {
			counts[string(inst.Kind)]++
		}
	}

	var parts []string
	for k, v := range counts {
		parts = append(parts, fmt.Sprintf("%d %s", v, k))
	}
	fmt.Printf("  %s (%s)\n\n", colorGreen(fmt.Sprintf("%d active", len(instances))), strings.Join(parts, ", "))

	// Table header
	fmt.Printf("  \033[2m%-8s %-16s %-40s %8s  %-8s\033[0m\n",
		"PID", "KIND", "CWD", "DURATION", "STATUS")

	for _, inst := range instances {
		kind := colorKind(inst.Kind)
		status := colorStatus(inst.Status)
		cwd := shortenPath(inst.CWD, 40)
		dur := formatDuration(inst.DurationSeconds)

		fmt.Printf("  %-8d %-16s %-40s %8s  %s\n",
			inst.PID, kind, cwd, dur, status)

		// AX detail line
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
			fmt.Printf("  %8s \033[2m%s\033[0m\n", "", detail)
		}
	}
	fmt.Println()
}

func colorKind(k discovery.Kind) string {
	s := string(k)
	if k.IsAX() {
		return fmt.Sprintf("\033[0;36m%s\033[0m", s) // cyan
	}
	switch k {
	case discovery.KindInteractive:
		return fmt.Sprintf("\033[0;32m%s\033[0m", s) // green
	case discovery.KindHeadless:
		return fmt.Sprintf("\033[0;33m%s\033[0m", s) // yellow
	default:
		return s
	}
}

func colorStatus(status string) string {
	switch status {
	case "working":
		return fmt.Sprintf("\033[0;32m%s\033[0m", status)
	case "active":
		return fmt.Sprintf("\033[0;32m%s\033[0m", status)
	case "stalled":
		return fmt.Sprintf("\033[0;33m%s\033[0m", status)
	case "dead":
		return fmt.Sprintf("\033[0;31m%s\033[0m", status)
	default:
		return status
	}
}

func colorGreen(s string) string {
	return fmt.Sprintf("\033[0;32m%s\033[0m", s)
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
