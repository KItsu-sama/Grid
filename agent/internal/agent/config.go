package agent

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	StateDir    string            `json:"state_dir"`
	DeviceName  string            `json:"device_name"`
	Role        string            `json:"role"`
	OwnerLogin  string            `json:"owner_login"`
	Roots       map[string]string `json:"roots"`
	Apps        map[string]string `json:"apps"`
	EnvReadable []string          `json:"env_readable"`
	LocalPort   int               `json:"local_port"`
	PeerPort    int               `json:"peer_port"`
	GridRoot    string            `json:"-"`
}

func LoadConfig(stateDir string) (Config, string, error) {
	gridRoot := os.Getenv("PERSONAL_GRID_ROOT")
	if stateDir == "" {
		stateDir = os.Getenv("GRID_STATE_DIR")
	}
	if stateDir == "" {
		if gridRoot != "" {
			stateDir = filepath.Join(gridRoot, ".grid", "agent")
		} else if local := os.Getenv("LOCALAPPDATA"); local != "" {
			stateDir = filepath.Join(local, "Grid")
		} else {
			home, err := os.UserHomeDir()
			if err != nil {
				return Config{}, "", err
			}
			stateDir = filepath.Join(home, ".grid")
		}
	}
	config := Config{StateDir: stateDir, DeviceName: "PersonalGrid device", Role: "CLIENT",
		Roots: map[string]string{}, Apps: map[string]string{}, LocalPort: 8765, PeerPort: 8766, GridRoot: gridRoot}
	if gridRoot != "" {
		devicePath := filepath.Join(gridRoot, ".grid", "device.json")
		data, err := os.ReadFile(devicePath)
		if err != nil {
			return Config{}, "", errors.New("PersonalGrid device record not found: " + devicePath)
		}
		var device map[string]any
		if err := json.Unmarshal(data, &device); err != nil {
			return Config{}, "", err
		}
		deviceID, _ := device["gridDeviceId"].(string)
		if strings.TrimSpace(deviceID) == "" {
			return Config{}, "", errors.New("PersonalGrid device record has no gridDeviceId")
		}
		config.DeviceName = stringValue(device["deviceName"], config.DeviceName)
		config.OwnerLogin = stringValue(device["tailscaleEmail"], "")
		config.Role = personalGridRole(device)
		if err := loadLocalAgentOptions(&config); err != nil {
			return Config{}, "", err
		}
		return config, deviceID, nil
	}
	data, err := os.ReadFile(filepath.Join(stateDir, "config.json"))
	if err == nil {
		if err := json.Unmarshal(data, &config); err != nil {
			return Config{}, "", err
		}
		config.StateDir = stateDir
	} else if !os.IsNotExist(err) {
		return Config{}, "", err
	}
	return config, "", nil
}

func loadLocalAgentOptions(config *Config) error {
	data, err := os.ReadFile(filepath.Join(config.StateDir, "config.json"))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var options struct {
		Apps        map[string]string `json:"apps"`
		EnvReadable []string          `json:"env_readable"`
		LocalPort   int               `json:"local_port"`
		PeerPort    int               `json:"peer_port"`
	}
	if err := json.Unmarshal(data, &options); err != nil {
		return err
	}
	if options.Apps != nil {
		config.Apps = options.Apps
	}
	if options.EnvReadable != nil {
		config.EnvReadable = options.EnvReadable
	}
	if options.LocalPort != 0 {
		config.LocalPort = options.LocalPort
	}
	if options.PeerPort != 0 {
		config.PeerPort = options.PeerPort
	}
	return nil
}

func personalGridRole(device map[string]any) string {
	role := strings.ToUpper(stringValue(device["gridRole"], ""))
	if role == "" {
		if isMain, _ := device["isMain"].(bool); isMain {
			role = "MAIN"
		} else {
			role = strings.ToUpper(stringValue(device["role"], "CLIENT"))
		}
	}
	if role != "MAIN" && role != "WORKER" && role != "CLIENT" {
		return "CLIENT"
	}
	return role
}

func stringValue(value any, fallback string) string {
	text, ok := value.(string)
	if !ok || strings.TrimSpace(text) == "" {
		return fallback
	}
	return text
}

func (c Config) AdminToken() (string, error) {
	path := filepath.Join(c.StateDir, "admin.token")
	if data, err := os.ReadFile(path); err == nil {
		return strings.TrimSpace(string(data)), nil
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if err := os.MkdirAll(c.StateDir, 0700); err != nil {
		return "", err
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", err
	}
	token := base64.RawURLEncoding.EncodeToString(secret)
	if err := os.WriteFile(path, []byte(token), 0600); err != nil {
		return "", err
	}
	return token, nil
}
