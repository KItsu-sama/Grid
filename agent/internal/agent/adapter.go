package agent

import (
	"context"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type WindowsAdapter struct {
	apps        map[string]string
	envReadable map[string]bool
}

func NewWindowsAdapter(apps map[string]string, envReadable []string) *WindowsAdapter {
	readable := make(map[string]bool, len(envReadable))
	for _, name := range envReadable {
		readable[name] = true
	}
	return &WindowsAdapter{apps: apps, envReadable: readable}
}

func (a *WindowsAdapter) Invoke(capability string, args map[string]any) (any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	switch capability {
	case "app.launch":
		appID := args["app"].(string)
		executable, ok := a.apps[appID]
		if !ok || strings.TrimSpace(executable) == "" {
			return nil, errors.New("app not in allowlist")
		}
		if err := exec.Command(executable).Start(); err != nil {
			return nil, err
		}
		return map[string]any{"launched": appID}, nil
	case "power.sleep":
		if err := runFixed(ctx, "rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"); err != nil {
			return nil, err
		}
		return map[string]any{"done": true}, nil
	case "power.shutdown":
		delay := int(args["delay_seconds"].(float64))
		if err := runFixed(ctx, "shutdown", "/s", "/t", strconv.Itoa(delay)); err != nil {
			return nil, err
		}
		return map[string]any{"scheduled_in": delay}, nil
	case "process.stop":
		pid := int(args["pid"].(float64))
		if pid <= 4 || pid == os.Getpid() {
			return nil, errors.New("refusing to stop protected process")
		}
		if err := runFixed(ctx, "taskkill", "/PID", strconv.Itoa(pid)); err != nil {
			return nil, err
		}
		return map[string]any{"stopped": pid}, nil
	case "process.read":
		output, err := exec.CommandContext(ctx, "tasklist", "/FO", "CSV", "/NH").Output()
		if err != nil {
			return nil, fmt.Errorf("tasklist failed: %w", err)
		}
		reader := csv.NewReader(strings.NewReader(string(output)))
		reader.FieldsPerRecord = -1
		processes := []map[string]any{}
		for {
			row, err := reader.Read()
			if err != nil {
				if errors.Is(err, io.EOF) {
					break
				}
				return nil, err
			}
			if len(row) >= 2 {
				pid, parseErr := strconv.Atoi(strings.TrimSpace(row[1]))
				if parseErr == nil {
					processes = append(processes, map[string]any{"pid": pid, "name": row[0]})
				}
			}
		}
		return processes, nil
	case "environment.read":
		name := args["name"].(string)
		if !a.envReadable[name] {
			return nil, errors.New("variable not readable")
		}
		value, present := os.LookupEnv(name)
		if !present {
			return map[string]any{"value": nil}, nil
		}
		return map[string]any{"value": value}, nil
	default:
		return nil, errUnsupported
	}
}

func runFixed(ctx context.Context, executable string, args ...string) error {
	command := exec.CommandContext(ctx, executable, args...)
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("%s failed: %s", executable, strings.TrimSpace(string(output)))
	}
	return nil
}
