package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"time"
)

type NetworkStatus struct {
	Running   bool     `json:"running"`
	LoggedIn  bool     `json:"logged_in"`
	Addresses []string `json:"addresses"`
	Owner     string   `json:"owner"`
	Detail    string   `json:"detail"`
}

func TailscaleStatus() NetworkStatus {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "tailscale", "status", "--json").Output()
	if err != nil {
		return NetworkStatus{Detail: "tailscale status unavailable"}
	}
	var status map[string]any
	if json.Unmarshal(output, &status) != nil {
		return NetworkStatus{Detail: "invalid tailscale status response"}
	}
	backend, _ := status["BackendState"].(string)
	self, _ := status["Self"].(map[string]any)
	userID := scalarString(self["UserID"])
	users, _ := status["User"].(map[string]any)
	user, _ := users[userID].(map[string]any)
	addresses := []string{}
	if values, ok := self["TailscaleIPs"].([]any); ok {
		for _, value := range values {
			if address, ok := value.(string); ok {
				addresses = append(addresses, address)
			}
		}
	}
	return NetworkStatus{Running: backend == "Running", LoggedIn: userID != "" && userID != "0",
		Addresses: addresses, Owner: stringValue(user["LoginName"], ""), Detail: backend}
}

func TailscaleWhois(address string) (*PeerIdentity, error) {
	if host, _, err := net.SplitHostPort(address); err == nil {
		address = host
	}
	address = strings.TrimSuffix(address, "/32")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "tailscale", "whois", "--json", address).Output()
	if err != nil {
		return nil, err
	}
	var response map[string]any
	if err := json.Unmarshal(output, &response); err != nil {
		return nil, err
	}
	node, _ := response["Node"].(map[string]any)
	profile, _ := response["UserProfile"].(map[string]any)
	identity := &PeerIdentity{TransportID: stringValue(node["StableID"], ""),
		Owner: stringValue(profile["LoginName"], ""), WGKey: stringValue(node["Key"], "")}
	if values, ok := node["Addresses"].([]any); ok {
		for _, value := range values {
			if address, ok := value.(string); ok {
				identity.Addresses = append(identity.Addresses, strings.TrimSuffix(address, "/32"))
			}
		}
	}
	if identity.TransportID == "" || identity.Owner == "" {
		return nil, errors.New("tailscale whois returned no stable device or owner identity")
	}
	return identity, nil
}

func scalarString(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case float64:
		return fmt.Sprint(typed)
	case json.Number:
		return typed.String()
	default:
		return ""
	}
}
