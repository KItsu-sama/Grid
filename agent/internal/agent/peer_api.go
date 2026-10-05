package agent

import (
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"
)

func (r *Runtime) PeerHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		peer, err := TailscaleWhois(request.RemoteAddr)
		if err != nil {
			writeJSON(w, http.StatusForbidden, map[string]any{"detail": "transport identity unavailable"})
			return
		}
		switch request.URL.Path {
		case "/v1/invoke":
			r.handlePeerInvoke(w, request, peer)
		case "/v1/hello":
			r.handlePeerHello(w, request, peer)
		case "/v1/rotate":
			r.handlePeerRotate(w, request, peer)
		default:
			writeJSON(w, http.StatusNotFound, map[string]any{"detail": "not found"})
		}
	})
}

func (r *Runtime) handlePeerInvoke(w http.ResponseWriter, request *http.Request, peer *PeerIdentity) {
	if request.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"detail": "method not allowed"})
		return
	}
	var body struct {
		Envelope  map[string]any `json:"envelope"`
		Signature string         `json:"signature"`
	}
	if err := decodeBody(request, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"detail": "malformed request"})
		return
	}
	writeJSON(w, http.StatusOK, r.HandleInvoke(body.Envelope, body.Signature, peer))
}

func (r *Runtime) handlePeerHello(w http.ResponseWriter, request *http.Request, peer *PeerIdentity) {
	if request.Method != http.MethodPost || !strings.EqualFold(peer.Owner, r.Config.OwnerLogin) || r.Config.OwnerLogin == "" {
		writeJSON(w, http.StatusForbidden, map[string]any{"detail": "peer is not on this Grid's identity"})
		return
	}
	var body struct {
		Device    map[string]any `json:"device"`
		Signature string         `json:"signature"`
	}
	if err := decodeBody(request, &body); err != nil || body.Device == nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"detail": "malformed hello"})
		return
	}
	canonical, err := canonicalJSON(body.Device)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"detail": "malformed hello"})
		return
	}
	deviceID := stringValue(body.Device["device_id"], "")
	publicKey := stringValue(body.Device["sign_pubkey"], "")
	timestamp, ok := body.Device["ts"].(float64)
	if deviceID == "" || publicKey == "" || !ok || time.Since(time.Unix(0, int64(timestamp*1e9))).Abs() > time.Minute ||
		!VerifySignature(publicKey, canonical, body.Signature) {
		_ = r.Audit.Record(deviceID, r.Identity.DeviceID, "hello", nil, "denied", "invalid device proof")
		writeJSON(w, http.StatusForbidden, map[string]any{"detail": "bad or stale device proof"})
		return
	}
	capabilities := []string{}
	if values, ok := body.Device["capabilities"].([]any); ok {
		for _, value := range values {
			if capability, ok := value.(string); ok && len(capabilities) < 64 {
				capabilities = append(capabilities, capability)
			}
		}
	}
	address := ""
	if len(peer.Addresses) > 0 {
		address = peer.Addresses[0]
	}
	device, err := r.Registry.Register(Device{DeviceID: deviceID, Name: truncate(stringValue(body.Device["name"], "Grid device"), 64),
		SignPubKey: publicKey, TransportID: peer.TransportID, WGPubKey: peer.WGKey, Address: address,
		Version: truncate(stringValue(body.Device["version"], ""), 32), Capabilities: capabilities})
	if err != nil {
		writeJSON(w, http.StatusForbidden, map[string]any{"detail": err.Error()})
		return
	}
	_ = r.Audit.Record(device.DeviceID, r.Identity.DeviceID, "hello", map[string]any{"name": device.Name}, "pending_approval", "")
	writeJSON(w, http.StatusOK, map[string]any{"state": device.State, "device_id": r.Identity.DeviceID,
		"name": r.Config.DeviceName, "sign_pubkey": r.Identity.PublicKey()})
}

func (r *Runtime) handlePeerRotate(w http.ResponseWriter, request *http.Request, peer *PeerIdentity) {
	if request.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"detail": "method not allowed"})
		return
	}
	var body struct {
		DeviceID  string `json:"device_id"`
		NewPubKey string `json:"new_pubkey"`
		Signature string `json:"signature"`
	}
	if err := decodeBody(request, &body); err != nil || body.DeviceID == "" || body.NewPubKey == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"detail": "malformed rotation"})
		return
	}
	device, err := r.Registry.Get(body.DeviceID)
	statement := []byte(fmt.Sprintf("grid-key-rotation:v1:%s:%s", body.DeviceID, body.NewPubKey))
	if err != nil || device == nil || device.State != "approved" || device.TransportID != peer.TransportID ||
		!VerifySignature(device.SignPubKey, statement, body.Signature) {
		writeJSON(w, http.StatusForbidden, map[string]any{"detail": "identity rotation proof rejected"})
		return
	}
	if _, err := r.Registry.db.Exec(`UPDATE devices SET sign_pubkey=? WHERE device_id=?`, body.NewPubKey, body.DeviceID); err != nil {
		writeError(w, err)
		return
	}
	_ = r.Audit.Record(body.DeviceID, r.Identity.DeviceID, "peer.rotate_key", map[string]any{}, "ok", "")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func peerAddress(status NetworkStatus) string {
	for _, address := range status.Addresses {
		ip := net.ParseIP(address)
		if ip != nil && ip.To4() != nil {
			return address
		}
	}
	return ""
}

func truncate(value string, max int) string {
	if len(value) > max {
		return value[:max]
	}
	return value
}
