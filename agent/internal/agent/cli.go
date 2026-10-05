package agent

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func RunCLI(stateDir string, jsonOutput bool, args []string) error {
	if len(args) == 0 {
		return errors.New("a command is required")
	}
	if args[0] == "init" {
		return runInit(stateDir, args[1:])
	}
	config, deviceID, err := LoadConfig(stateDir)
	if err != nil {
		return err
	}
	if len(args) == 2 && args[0] == "daemon" && args[1] == "run" {
		return RunDaemon(config, deviceID)
	}
	token, err := config.AdminToken()
	if err != nil {
		return err
	}
	request := func(method, route string, body any) (any, error) {
		var data []byte
		if body != nil {
			data, err = json.Marshal(body)
			if err != nil {
				return nil, err
			}
		}
		req, err := http.NewRequest(method, fmt.Sprintf("http://127.0.0.1:%d%s", config.LocalPort, route), bytes.NewReader(data))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		response, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
		if err != nil {
			return nil, errors.New("cannot reach the Grid daemon; is `grid-agent daemon run` running?")
		}
		defer response.Body.Close()
		var value any
		if err := json.NewDecoder(response.Body).Decode(&value); err != nil {
			return nil, err
		}
		if response.StatusCode >= http.StatusBadRequest {
			message := "request failed"
			if document, ok := value.(map[string]any); ok {
				message = stringValue(document["detail"], message)
			}
			return nil, fmt.Errorf("error %d: %s", response.StatusCode, message)
		}
		return value, nil
	}
	show := func(value any) {
		if jsonOutput {
			data, _ := json.MarshalIndent(value, "", "  ")
			fmt.Println(string(data))
		}
	}
	switch args[0] {
	case "network":
		if len(args) != 2 || args[1] != "status" {
			return errors.New("supported native network command: status")
		}
		value, err := request(http.MethodGet, "/status", nil)
		if err != nil {
			return err
		}
		if jsonOutput {
			show(value)
			return nil
		}
		status := value.(map[string]any)
		network := status["network"].(map[string]any)
		state := "DOWN"
		if network["running"] == true && network["logged_in"] == true {
			state = "UP"
		}
		fmt.Printf("device   %s [%s] %s\nnetwork  %s (%s) %v owner=%s\n", status["name"], status["role"],
			shortID(stringValue(status["device_id"], "")), state, network["detail"], network["addresses"], network["owner"])
		return nil
	case "device":
		if len(args) < 2 {
			return errors.New("usage: grid-agent device list|approve|revoke|grant")
		}
		switch args[1] {
		case "list":
			value, err := request(http.MethodGet, "/devices", nil)
			if err != nil {
				return err
			}
			if jsonOutput {
				show(value)
			} else {
				rows := value.([]any)
				if len(rows) == 0 {
					fmt.Println("(none)")
				}
				for _, row := range rows {
					device := row.(map[string]any)
					fmt.Printf("%s  %-24s %-8s %s\n", shortID(stringValue(device["device_id"], "")), device["name"], device["role"], device["state"])
				}
			}
			return nil
		case "approve":
			if len(args) < 3 {
				return errors.New("usage: grid-agent device approve <id|name> [--role ROLE]")
			}
			role := strings.ToUpper(optionValue(args[3:], "--role", "CLIENT"))
			value, err := request(http.MethodPost, "/devices/"+url.PathEscape(args[2])+"/approve", map[string]string{"role": role})
			if err != nil {
				return err
			}
			if jsonOutput {
				show(value)
			} else {
				device := value.(map[string]any)
				fmt.Printf("approved %s as %s\n", device["name"], device["role"])
			}
			return nil
		case "revoke":
			if len(args) < 3 {
				return errors.New("usage: grid-agent device revoke <id|name>")
			}
			value, err := request(http.MethodPost, "/devices/"+url.PathEscape(args[2])+"/revoke", nil)
			if err != nil {
				return err
			}
			if jsonOutput {
				show(value)
			} else {
				fmt.Printf("revoked %s\n", value.(map[string]any)["name"])
			}
			return nil
		case "grant":
			if len(args) < 4 {
				return errors.New("usage: grid-agent device grant <id|name> <pattern> [--deny]")
			}
			effect := "allow"
			if contains(args[4:], "--deny") {
				effect = "deny"
			}
			value, err := request(http.MethodPost, "/devices/"+url.PathEscape(args[2])+"/grants",
				map[string]string{"pattern": args[3], "effect": effect})
			if err != nil {
				return err
			}
			show(value)
			return nil
		}
	case "confirm":
		if len(args) == 2 && args[1] == "list" {
			value, err := request(http.MethodGet, "/confirmations", nil)
			if err != nil {
				return err
			}
			show(value)
			return nil
		}
		if len(args) == 3 && (args[1] == "approve" || args[1] == "deny") {
			value, err := request(http.MethodPost, "/confirmations/"+url.PathEscape(args[2])+"/"+args[1], nil)
			if err != nil {
				return err
			}
			show(value)
			return nil
		}
		return errors.New("usage: grid-agent confirm list|approve|deny <id>")
	case "audit":
		limit := optionValue(args[1:], "--limit", "20")
		value, err := request(http.MethodGet, "/audit?limit="+url.QueryEscape(limit), nil)
		if err != nil {
			return err
		}
		if jsonOutput {
			show(value)
		} else {
			result := value.(map[string]any)
			state := "BROKEN"
			if result["chain_ok"] == true {
				state = "OK"
			}
			fmt.Printf("chain %s\n", state)
			for _, item := range result["entries"].([]any) {
				entry := item.(map[string]any)
				fmt.Printf("%.0f  %-8s %-24s %s\n", entry["ts"], shortID(stringValue(entry["source"], "")), entry["capability"], entry["result"])
			}
		}
		return nil
	}
	return fmt.Errorf("unsupported command: %s", strings.Join(args, " "))
}

func runInit(stateDir string, args []string) error {
	if os.Getenv("PERSONAL_GRID_ROOT") != "" {
		return errors.New("Agent init is managed by PersonalGrid setup; use Grid.ps1 setup first")
	}
	if stateDir == "" {
		return errors.New("init requires --state-dir")
	}
	name := optionValue(args, "--name", "")
	role := strings.ToUpper(optionValue(args, "--role", "CLIENT"))
	owner := optionValue(args, "--owner", "")
	if name == "" || owner == "" || (role != "MAIN" && role != "WORKER" && role != "CLIENT") {
		return errors.New("init requires --name, --owner, and a valid --role")
	}
	config := Config{StateDir: stateDir, DeviceName: name, Role: role, OwnerLogin: owner,
		Roots: map[string]string{}, Apps: map[string]string{}, LocalPort: 8765, PeerPort: 8766}
	for index := 0; index+1 < len(args); index++ {
		if args[index] == "--root" {
			index++
			rootName, rootPath, ok := strings.Cut(args[index], "=")
			if !ok || rootName == "" || rootPath == "" {
				return errors.New("root must use NAME=PATH")
			}
			config.Roots[rootName] = rootPath
		}
	}
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(stateDir, "config.json"), data, 0600); err != nil {
		return err
	}
	runtime, err := NewRuntime(config, "")
	if err != nil {
		return err
	}
	defer runtime.Registry.Close()
	fmt.Printf("initialised %s (%s) in %s\n", config.DeviceName, runtime.Identity.DeviceID, stateDir)
	return nil
}

func optionValue(args []string, option, fallback string) string {
	for index := 0; index+1 < len(args); index++ {
		if args[index] == option {
			return args[index+1]
		}
	}
	return fallback
}

func shortID(value string) string {
	if len(value) > 8 {
		return value[:8]
	}
	return value
}
