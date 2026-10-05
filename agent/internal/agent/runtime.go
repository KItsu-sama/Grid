package agent

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"
)

const AgentVersion = "0.2.0"

type Runtime struct {
	Config        Config
	Identity      *Identity
	Registry      *Registry
	Audit         *AuditLog
	Adapter       *WindowsAdapter
	AdminToken    string
	mu            sync.Mutex
	nonces        map[string]time.Time
	confirmations map[string]*Confirmation
}

type Confirmation struct {
	ID         string         `json:"id"`
	Source     string         `json:"source"`
	Capability string         `json:"capability"`
	Args       map[string]any `json:"args"`
	Hash       string         `json:"-"`
	Approved   bool           `json:"approved"`
	Expires    time.Time      `json:"-"`
}

type InvokeEnvelope struct {
	Source         string         `json:"source"`
	Target         string         `json:"target"`
	Capability     string         `json:"capability"`
	Args           map[string]any `json:"args"`
	Timestamp      float64        `json:"ts"`
	Nonce          string         `json:"nonce"`
	ConfirmationID string         `json:"confirmation_id"`
}

type InvokeResult struct {
	OK        bool   `json:"ok"`
	Value     any    `json:"value"`
	ErrorCode string `json:"error_code"`
	Error     string `json:"error"`
	Conflict  any    `json:"conflict"`
}

type PeerIdentity struct {
	TransportID string
	Owner       string
	WGKey       string
	Addresses   []string
}

func NewRuntime(config Config, deviceID string) (*Runtime, error) {
	if err := ensureConfigDefaults(&config); err != nil {
		return nil, err
	}
	identity, err := LoadIdentity(config.StateDir, deviceID)
	if err != nil {
		return nil, err
	}
	registryPath := config.StateDir
	auditPath := config.StateDir
	if config.GridRoot != "" {
		gridState := config.GridRoot + "/.grid"
		registryPath, auditPath = gridState, gridState+"/logs"
	}
	registry, err := OpenRegistry(registryPath + "/device_registry.db")
	if err != nil {
		return nil, err
	}
	audit, err := OpenAudit(auditPath + "/agent-audit.log")
	if err != nil {
		_ = registry.Close()
		return nil, err
	}
	token, err := config.AdminToken()
	if err != nil {
		_ = registry.Close()
		return nil, err
	}
	return &Runtime{Config: config, Identity: identity, Registry: registry, Audit: audit,
		Adapter: NewWindowsAdapter(config.Apps, config.EnvReadable), AdminToken: token,
		nonces: map[string]time.Time{}, confirmations: map[string]*Confirmation{}}, nil
}

func ensureConfigDefaults(config *Config) error {
	if config.StateDir == "" {
		return errors.New("agent state directory is empty")
	}
	if config.LocalPort <= 0 || config.LocalPort > 65535 {
		config.LocalPort = 8765
	}
	if config.PeerPort <= 0 || config.PeerPort > 65535 {
		config.PeerPort = 8766
	}
	if config.Role != "MAIN" && config.Role != "WORKER" && config.Role != "CLIENT" {
		config.Role = "CLIENT"
	}
	if config.DeviceName == "" {
		config.DeviceName = "PersonalGrid device"
	}
	if config.Roots == nil {
		config.Roots = map[string]string{}
	}
	if config.Apps == nil {
		config.Apps = map[string]string{}
	}
	return nil
}

func (r *Runtime) Capabilities() []string { return Capabilities(r.Config.Apps, r.Config.EnvReadable) }

func (r *Runtime) HandleInvoke(document map[string]any, signature string, peer *PeerIdentity) InvokeResult {
	requestBytes, _ := json.Marshal(document)
	var envelope InvokeEnvelope
	if err := json.Unmarshal(requestBytes, &envelope); err != nil || envelope.Args == nil || envelope.Source == "" || envelope.Target == "" || envelope.Capability == "" {
		return r.failed("?", "?", nil, "invalid_arguments", "malformed envelope", "error")
	}
	if peer == nil || !strings.EqualFold(peer.Owner, r.Config.OwnerLogin) || r.Config.OwnerLogin == "" {
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "unauthenticated", "peer is not on this Grid's identity", "denied")
	}
	if envelope.Target != r.Identity.DeviceID {
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "unauthenticated", "wrong target device", "denied")
	}
	device, err := r.Registry.Get(envelope.Source)
	if err != nil || device == nil || device.State != "approved" || device.Suspended {
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "unauthenticated", "device not approved or disconnected", "denied")
	}
	if device.TransportID != peer.TransportID {
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "unauthenticated", "transport identity does not match registered device", "denied")
	}
	signingBytes, err := envelope.SigningBytes()
	if err != nil || !VerifySignature(device.SignPubKey, signingBytes, signature) {
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "unauthenticated", "bad signature", "denied")
	}
	now := time.Now()
	if delta := now.Sub(time.Unix(0, int64(envelope.Timestamp*1e9))); delta > time.Minute || delta < -time.Minute {
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "unauthenticated", "stale request", "denied")
	}
	r.mu.Lock()
	for nonce, seen := range r.nonces {
		if now.Sub(seen) > 2*time.Minute {
			delete(r.nonces, nonce)
		}
	}
	if _, exists := r.nonces[envelope.Nonce]; exists || envelope.Nonce == "" {
		r.mu.Unlock()
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "unauthenticated", "replayed request", "denied")
	}
	r.nonces[envelope.Nonce] = now
	r.mu.Unlock()

	grants, err := r.Registry.Grants(envelope.Source)
	if err != nil || !IsAllowed(device, envelope.Capability, grants) {
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "permission_denied", "device may not use "+envelope.Capability, "denied")
	}
	if !contains(r.Capabilities(), envelope.Capability) {
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "unsupported_capability", envelope.Capability, "error")
	}
	clean, err := Validate(envelope.Capability, envelope.Args)
	if err != nil {
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "invalid_arguments", err.Error(), "error")
	}
	if IsSensitive(envelope.Capability) {
		confirmationID, approved := r.confirm(envelope, clean)
		if !approved {
			if confirmationID == "" {
				return r.failed(envelope.Source, envelope.Capability, envelope.Args, "internal_error", "could not create confirmation", "error")
			}
			result := r.failed(envelope.Source, envelope.Capability, envelope.Args, "confirmation_required", "confirmation required on the target device", "confirmation_required")
			result.Value = map[string]any{"confirmation_id": confirmationID}
			return result
		}
	}
	var result any
	if envelope.Capability == "device.info" {
		result = map[string]any{"device_id": r.Identity.DeviceID, "name": r.Config.DeviceName,
			"role": r.Config.Role, "platform": "windows", "version": AgentVersion, "capabilities": r.Capabilities()}
	} else {
		result, err = r.Adapter.Invoke(envelope.Capability, clean)
	}
	if err != nil {
		return r.failed(envelope.Source, envelope.Capability, envelope.Args, "error", err.Error(), "error")
	}
	_ = r.Audit.Record(envelope.Source, r.Identity.DeviceID, envelope.Capability, envelope.Args, "ok", "")
	return InvokeResult{OK: true, Value: result}
}

func (e InvokeEnvelope) SigningBytes() ([]byte, error) {
	return canonicalJSON(map[string]any{
		"source": e.Source, "target": e.Target, "capability": e.Capability, "args": e.Args,
		"ts": e.Timestamp, "nonce": e.Nonce, "confirmation_id": nullIfEmpty(e.ConfirmationID),
	})
}

func (r *Runtime) confirm(envelope InvokeEnvelope, args map[string]any) (string, bool) {
	hash, _ := canonicalJSON(args)
	digest := sha256.Sum256(hash)
	argsHash := hex.EncodeToString(digest[:])
	r.mu.Lock()
	defer r.mu.Unlock()
	if pending, ok := r.confirmations[envelope.ConfirmationID]; ok && pending.Approved && time.Now().Before(pending.Expires) &&
		pending.Source == envelope.Source && pending.Capability == envelope.Capability && pending.Hash == argsHash {
		delete(r.confirmations, envelope.ConfirmationID)
		return "", true
	}
	idBytes := make([]byte, 6)
	if _, err := rand.Read(idBytes); err != nil {
		return "", false
	}
	id := fmtHex(idBytes)
	r.confirmations[id] = &Confirmation{ID: id, Source: envelope.Source, Capability: envelope.Capability,
		Args: args, Hash: argsHash, Expires: time.Now().Add(120 * time.Second)}
	return id, false
}

func (r *Runtime) PendingConfirmations() []Confirmation {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	pending := []Confirmation{}
	for id, item := range r.confirmations {
		if now.Before(item.Expires) {
			pending = append(pending, *item)
		} else {
			delete(r.confirmations, id)
		}
	}
	return pending
}

func (r *Runtime) DecideConfirmation(id string, approve bool) error {
	r.mu.Lock()
	item, exists := r.confirmations[id]
	if !exists || time.Now().After(item.Expires) {
		delete(r.confirmations, id)
		r.mu.Unlock()
		return errors.New("unknown or expired confirmation")
	}
	if approve {
		item.Approved = true
	} else {
		delete(r.confirmations, id)
	}
	r.mu.Unlock()
	decision := "confirmation_denied"
	if approve {
		decision = "confirmation_approved"
	}
	return r.Audit.Record(item.Source, r.Identity.DeviceID, item.Capability, item.Args, decision, "")
}

func (r *Runtime) failed(source, capability string, args map[string]any, code, message, result string) InvokeResult {
	_ = r.Audit.Record(source, r.Identity.DeviceID, capability, args, result, code+": "+message)
	return InvokeResult{OK: false, ErrorCode: code, Error: message}
}

func contains(items []string, value string) bool {
	for _, item := range items {
		if item == value {
			return true
		}
	}
	return false
}

func nullIfEmpty(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func (r *Runtime) LocalHandler() http.Handler { return r.localHandler() }
