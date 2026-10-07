package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/exec"
	"time"
)

// TailscaleStatus reflects the output of `tailscale status --json`
type TailscaleStatus struct {
	Self struct {
		HostName     string   `json:"HostName"`
		TailscaleIPs []string `json:"TailscaleIPs"`
		UserID       int      `json:"UserID"`
	} `json:"Self"`
	Peer map[string]*struct {
		HostName     string   `json:"HostName"`
		TailscaleIPs []string `json:"TailscaleIPs"`
		Online       bool     `json:"Online"`
	} `json:"Peer"`
}

// SyncthingDevice defines a remote node inside Syncthing's config structure
type SyncthingDevice struct {
	DeviceID    string   `json:"deviceID"`
	Name        string   `json:"name"`
	Addresses   []string `json:"addresses"`
	Compression string   `json:"compression"`
	Introducer  bool     `json:"introducer"`
}

// SyncthingConfig represents the complete configuration structure
type SyncthingConfig struct {
	Version int               `json:"version"`
	Devices []SyncthingDevice `json:"devices"`
	// Additional fields omitted for brevity during unmarshaling
	Extra map[string]interface{} `json:"-"`
}

// GridBridge manages the automation between Tailscale and Syncthing
type GridBridge struct {
	SyncthingURL string
	APIKey       string
	HTTPClient   *http.Client
}

func NewGridBridge(syncthingURL, apiKey string) *GridBridge {
	return &GridBridge{
		SyncthingURL: syncthingURL,
		APIKey:       apiKey,
		HTTPClient:   &http.Client{Timeout: 5 * time.Second},
	}
}

// GetTailscalePeers queries the local tailscaled daemon via CLI
func (g *GridBridge) GetTailscalePeers() (*TailscaleStatus, error) {
	cmd := exec.Command("tailscale", "status", "--json")
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to run tailscale status: %w", err)
	}

	var status TailscaleStatus
	if err := json.Unmarshal(output, &status); err != nil {
		return nil, fmt.Errorf("failed to parse tailscale status JSON: %w", err)
	}

	return &status, nil
}

// GetLocalSyncthingDeviceID fetches the device ID of this local instance
func (g *GridBridge) GetLocalSyncthingDeviceID(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", g.SyncthingURL+"/rest/svc/deviceid", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("X-API-Key", g.APIKey)

	resp, err := g.HTTPClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var res struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &res); err != nil {
		return "", err
	}

	return res.ID, nil
}

// AddSyncthingDevice appends a remote device ID paired with its Tailscale IP address
func (g *GridBridge) AddSyncthingDevice(ctx context.Context, targetDeviceID, nodeName, tailscaleIP string) error {
	// 1. Fetch current config
	req, err := http.NewRequestWithContext(ctx, "GET", g.SyncthingURL+"/rest/config", nil)
	if err != nil {
		return err
	}
	req.Header.Set("X-API-Key", g.APIKey)

	resp, err := g.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to fetch syncthing config: %w", err)
	}
	defer resp.Body.Close()

	var fullConfig map[string]interface{}
	body, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(body, &fullConfig); err != nil {
		return err
	}

	// Extract existing devices list
	devicesRaw, ok := fullConfig["devices"].([]interface{})
	if !ok {
		return fmt.Errorf("invalid devices section in config")
	}

	// 2. Check if device already exists
	for _, d := range devicesRaw {
		devMap, ok := d.(map[string]interface{})
		if ok && devMap["deviceID"] == targetDeviceID {
			log.Printf("[Grid Bridge] Device %s (%s) already exists in Syncthing config.", nodeName, targetDeviceID)
			return nil
		}
	}

	// 3. Construct new device entry configured to talk directly over Tailscale IP
	newDevice := map[string]interface{}{
		"deviceID":    targetDeviceID,
		"name":        nodeName,
		"addresses":   []string{fmt.Sprintf("tcp://%s:22000", tailscaleIP)},
		"compression": "metadata",
		"introducer":  false,
	}

	fullConfig["devices"] = append(devicesRaw, newDevice)

	// 4. PUT updated config back to Syncthing
	updatedJSON, err := json.Marshal(fullConfig)
	if err != nil {
		return err
	}

	putReq, err := http.NewRequestWithContext(ctx, "PUT", g.SyncthingURL+"/rest/config", bytes.NewBuffer(updatedJSON))
	if err != nil {
		return err
	}
	putReq.Header.Set("X-API-Key", g.APIKey)
	putReq.Header.Set("Content-Type", "application/json")

	putResp, err := g.HTTPClient.Do(putReq)
	if err != nil {
		return fmt.Errorf("failed to save updated syncthing config: %w", err)
	}
	defer putResp.Body.Close()

	if putResp.StatusCode != http.StatusOK && putResp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("syncthing returned non-200 status on config update: %d", putResp.StatusCode)
	}

	log.Printf("[Grid Bridge] Successfully paired Syncthing Device: %s @ %s (%s)", nodeName, tailscaleIP, targetDeviceID)
	return nil
}

func main() {
	ctx := context.Background()
	bridge := NewGridBridge("http://127.0.0.1:8384", "YOUR_SYNCTHING_API_KEY_HERE")

	// 1. Get Local Syncthing Device ID
	localID, err := bridge.GetLocalSyncthingDeviceID(ctx)
	if err != nil {
		log.Printf("[Grid Error] Could not retrieve local Syncthing ID: %v", err)
	} else {
		log.Printf("[Grid Core] Local Syncthing Device ID: %s", localID)
	}

	// 2. Query Tailscale Mesh Devices
	status, err := bridge.GetTailscalePeers()
	if err != nil {
		log.Fatalf("[Grid Error] %v", err)
	}

	log.Printf("[Grid Core] Discovered Tailnet Host: %s (%v)", status.Self.HostName, status.Self.TailscaleIPs)

	// 3. Iterate through active Tailscale peers
	for _, peer := range status.Peer {
		if !peer.Online || len(peer.TailscaleIPs) == 0 {
			continue
		}

		targetIP := peer.TailscaleIPs[0]
		log.Printf("[Grid Core] Found online peer: %s at %s", peer.HostName, targetIP)

		// Example: Exchange remote Syncthing device ID (e.g. obtained via Grid's own seed/join protocol)
		// and register it directly to the local Syncthing daemon
		remoteDeviceID := "EXAMPLE-SYNCTHING-DEVICE-ID-PASSED-FROM-JOIN-STEP"
		
		err := bridge.AddSyncthingDevice(ctx, remoteDeviceID, peer.HostName, targetIP)
		if err != nil {
			log.Printf("[Grid Warning] Failed to pair device %s: %v", peer.HostName, err)
		}
	}
}