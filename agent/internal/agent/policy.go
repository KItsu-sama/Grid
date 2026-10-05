package agent

import (
	"errors"
	"fmt"
	"math"
	"path"
	"sort"
)

type Grant struct {
	Pattern string `json:"pattern"`
	Effect  string `json:"effect"`
}

type ArgRule struct {
	Kind     string
	Required bool
	Default  any
	Minimum  float64
	Maximum  float64
	HasRange bool
	MaxLen   int
}

var catalogue = map[string]map[string]ArgRule{
	"device.info":      {},
	"power.sleep":      {},
	"power.shutdown":   {"delay_seconds": {Kind: "integer", Default: float64(30), Minimum: 5, Maximum: 3600, HasRange: true}},
	"process.read":     {},
	"process.stop":     {"pid": {Kind: "integer", Required: true, Minimum: 1, Maximum: math.MaxInt32, HasRange: true}},
	"environment.read": {"name": {Kind: "string", Required: true, MaxLen: 256}},
	"app.launch":       {"app": {Kind: "string", Required: true, MaxLen: 64}},
}

var sensitivePatterns = []string{"power.*", "environment.modify", "services.manage", "process.manage", "process.stop", "system.settings", "files.delete_recursive"}

var roleBaseline = map[string][]string{
	"MAIN":   {"files.*", "transfer.*", "media.*", "audio.*", "app.launch", "process.read", "device.info", "environment.read"},
	"WORKER": {"files.list", "files.stat", "files.read", "files.write", "files.mkdir", "transfer.*", "device.info"},
	"CLIENT": {"files.list", "files.stat", "files.read", "transfer.*", "media.*", "audio.*", "device.info"},
}

func Capabilities(apps map[string]string, envReadable []string) []string {
	caps := []string{"device.info", "environment.read", "power.sleep", "power.shutdown", "process.read", "process.stop"}
	if len(apps) > 0 {
		caps = append(caps, "app.launch")
	}
	sort.Strings(caps)
	return caps
}

func IsSensitive(capability string) bool { return matchesAny(sensitivePatterns, capability) }

func IsAllowed(device *Device, capability string, grants []Grant) bool {
	if device == nil || device.State != "approved" {
		return false
	}
	for _, grant := range grants {
		if grant.Effect == "deny" && matches(grant.Pattern, capability) {
			return false
		}
	}
	for _, grant := range grants {
		if grant.Effect == "allow" && matches(grant.Pattern, capability) {
			return true
		}
	}
	if IsSensitive(capability) {
		return false
	}
	return matchesAny(roleBaseline[device.Role], capability)
}

func Validate(capability string, args map[string]any) (map[string]any, error) {
	spec, ok := catalogue[capability]
	if !ok {
		return nil, fmt.Errorf("unknown capability %s", capability)
	}
	for key := range args {
		if _, ok := spec[key]; !ok {
			return nil, fmt.Errorf("unexpected argument: %s", key)
		}
	}
	clean := make(map[string]any, len(spec))
	for name, rule := range spec {
		value, present := args[name]
		if !present {
			if rule.Required {
				return nil, fmt.Errorf("missing argument: %s", name)
			}
			clean[name] = rule.Default
			continue
		}
		switch rule.Kind {
		case "string":
			text, ok := value.(string)
			if !ok || (rule.MaxLen > 0 && len(text) > rule.MaxLen) || (rule.Required && text == "") {
				return nil, fmt.Errorf("%s: wrong type or invalid length", name)
			}
		case "integer":
			number, ok := value.(float64)
			if !ok || math.Trunc(number) != number || (rule.HasRange && (number < rule.Minimum || number > rule.Maximum)) {
				return nil, fmt.Errorf("%s: wrong type or out of range", name)
			}
		}
		clean[name] = value
	}
	return clean, nil
}

func matchesAny(patterns []string, value string) bool {
	for _, pattern := range patterns {
		if matches(pattern, value) {
			return true
		}
	}
	return false
}

func matches(pattern, value string) bool {
	matched, err := path.Match(pattern, value)
	return err == nil && matched
}

var errUnsupported = errors.New("unsupported capability")
