package agent

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func testRuntime(t *testing.T) *Runtime {
	t.Helper()
	config := Config{StateDir: t.TempDir(), DeviceName: "target", Role: "MAIN", OwnerLogin: "owner@example.com",
		Apps: map[string]string{}, Roots: map[string]string{}, LocalPort: 8765, PeerPort: 8766}
	runtime, err := NewRuntime(config, "target-device")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = runtime.Registry.Close() })
	return runtime
}

func TestIdentityLoadsPythonSeedAndBindsDeviceID(t *testing.T) {
	directory := t.TempDir()
	seed := make([]byte, 32)
	for index := range seed {
		seed[index] = byte(index)
	}
	data, err := json.Marshal(map[string]string{"device_id": "device-one", "private_key": base64.StdEncoding.EncodeToString(seed)})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "identity.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	identity, err := LoadIdentity(directory, "device-one")
	if err != nil {
		t.Fatal(err)
	}
	message := []byte("grid request")
	if !VerifySignature(identity.PublicKey(), message, identity.Sign(message)) {
		t.Fatal("identity signature did not verify")
	}
	if _, err := LoadIdentity(directory, "device-two"); err == nil {
		t.Fatal("identity was rebound to a different Grid device")
	}
}

func TestPersonalGridConfigKeepsDeviceAuthorityAndLoadsAdapterOptions(t *testing.T) {
	gridRoot := t.TempDir()
	stateDir := filepath.Join(gridRoot, ".grid", "agent")
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		t.Fatal(err)
	}
	device := map[string]any{"gridDeviceId": "authoritative-id", "gridRole": "WORKER",
		"deviceName": "grid-name", "tailscaleEmail": "owner@example.com"}
	data, err := json.Marshal(device)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(gridRoot, ".grid"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gridRoot, ".grid", "device.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	options := map[string]any{"device_name": "untrusted-override", "role": "MAIN", "owner_login": "other@example.com",
		"apps": map[string]string{"editor": `C:\\Windows\\notepad.exe`}, "env_readable": []string{"TEMP"}, "local_port": 9875}
	data, err = json.Marshal(options)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "config.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PERSONAL_GRID_ROOT", gridRoot)
	config, deviceID, err := LoadConfig(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	if deviceID != "authoritative-id" || config.DeviceName != "grid-name" || config.Role != "WORKER" || config.OwnerLogin != "owner@example.com" {
		t.Fatalf("local config overrode device authority: id=%q config=%+v", deviceID, config)
	}
	if config.Apps["editor"] == "" || len(config.EnvReadable) != 1 || config.LocalPort != 9875 {
		t.Fatalf("agent options did not load: %+v", config)
	}
}

func TestRegistryApprovalAndDenyGrant(t *testing.T) {
	registry, err := OpenRegistry(filepath.Join(t.TempDir(), "device_registry.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer registry.Close()
	device, err := registry.Register(Device{DeviceID: "source", Name: "phone", SignPubKey: "key", TransportID: "node"})
	if err != nil || device.State != "pending" {
		t.Fatalf("new device state = %v, error = %v", device, err)
	}
	device, err = registry.Approve(device.DeviceID, "MAIN")
	if err != nil || device.State != "approved" {
		t.Fatalf("approval failed: %v", err)
	}
	if !IsAllowed(device, "device.info", nil) {
		t.Fatal("MAIN baseline did not permit device.info")
	}
	if err := registry.SetGrant(device.DeviceID, "audio.*", "deny"); err != nil {
		t.Fatal(err)
	}
	grants, err := registry.Grants(device.DeviceID)
	if err != nil || IsAllowed(device, "audio.volume.set", grants) {
		t.Fatal("explicit deny did not override role permissions")
	}
}

func TestAuditChainRedactsSecretsAndDetectsTampering(t *testing.T) {
	log, err := OpenAudit(filepath.Join(t.TempDir(), "logs", "agent-audit.log"))
	if err != nil {
		t.Fatal(err)
	}
	if err := log.Record("phone", "pc", "files.write", map[string]any{"data": "secret-content"}, "ok", ""); err != nil {
		t.Fatal(err)
	}
	entries, err := log.Entries()
	if err != nil || entries[0]["args"].(map[string]any)["data"] != "<redacted>" {
		t.Fatal("audit data was not redacted")
	}
	if ok, _, err := log.Verify(); err != nil || !ok {
		t.Fatalf("new audit chain did not verify: %v", err)
	}
	entries[0]["result"] = "tampered"
	data, err := json.Marshal(entries[0])
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(log.path, append(data, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	if ok, bad, err := log.Verify(); err != nil || ok || bad != 0 {
		t.Fatalf("tampering was not detected: ok=%v bad=%d err=%v", ok, bad, err)
	}
}

func TestCanonicalJSONMatchesPythonUnicodeEscaping(t *testing.T) {
	encoded, err := canonicalJSON(map[string]any{"name": "café 😀"})
	if err != nil {
		t.Fatal(err)
	}
	if string(encoded) != `{"name":"caf\u00e9 \ud83d\ude00"}` {
		t.Fatalf("canonical JSON = %s", encoded)
	}
}

func TestSignedInvokeAuthorizationReplayAndConfirmation(t *testing.T) {
	runtime := testRuntime(t)
	source, err := LoadIdentity(t.TempDir(), "source-device")
	if err != nil {
		t.Fatal(err)
	}
	device, err := runtime.Registry.Register(Device{DeviceID: source.DeviceID, Name: "phone", SignPubKey: source.PublicKey(), TransportID: "stable-phone"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := runtime.Registry.Approve(device.DeviceID, "MAIN"); err != nil {
		t.Fatal(err)
	}
	peer := &PeerIdentity{TransportID: "stable-phone", Owner: "OWNER@example.com"}
	result := signedInvoke(t, runtime, source, peer, "device.info", map[string]any{}, "nonce-one", "")
	if !result.OK {
		t.Fatalf("signed device.info call failed: %+v", result)
	}
	replay := signedInvoke(t, runtime, source, peer, "device.info", map[string]any{}, "nonce-one", "")
	if replay.ErrorCode != "unauthenticated" || replay.Error != "replayed request" {
		t.Fatalf("replay was not rejected: %+v", replay)
	}
	if err := runtime.Registry.SetGrant(source.DeviceID, "power.sleep", "allow"); err != nil {
		t.Fatal(err)
	}
	confirmation := signedInvoke(t, runtime, source, peer, "power.sleep", map[string]any{}, "nonce-two", "")
	if confirmation.ErrorCode != "confirmation_required" {
		t.Fatalf("sensitive operation did not require confirmation: %+v", confirmation)
	}
	id, ok := confirmation.Value.(map[string]any)["confirmation_id"].(string)
	if !ok || id == "" {
		t.Fatal("confirmation ID was not returned")
	}
	if err := runtime.DecideConfirmation(id, true); err != nil {
		t.Fatal(err)
	}
	if len(runtime.PendingConfirmations()) != 1 || !runtime.PendingConfirmations()[0].Approved {
		t.Fatal("local confirmation decision was not persisted in memory")
	}
}

func TestLocalAPIRequiresBearerToken(t *testing.T) {
	runtime := testRuntime(t)
	server := httptest.NewServer(runtime.LocalHandler())
	defer server.Close()
	response, err := http.Get(server.URL + "/devices")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated API status = %d", response.StatusCode)
	}
	request, _ := http.NewRequest(http.MethodGet, server.URL+"/devices", nil)
	request.Header.Set("Authorization", "Bearer "+runtime.AdminToken)
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("authenticated API status = %d", response.StatusCode)
	}
}

func signedInvoke(t *testing.T, runtime *Runtime, identity *Identity, peer *PeerIdentity, capability string,
	args map[string]any, nonce, confirmationID string) InvokeResult {
	t.Helper()
	envelope := InvokeEnvelope{Source: identity.DeviceID, Target: runtime.Identity.DeviceID, Capability: capability,
		Args: args, Timestamp: float64(time.Now().UnixNano()) / 1e9, Nonce: nonce, ConfirmationID: confirmationID}
	message, err := envelope.SigningBytes()
	if err != nil {
		t.Fatal(err)
	}
	document := map[string]any{"source": envelope.Source, "target": envelope.Target, "capability": envelope.Capability,
		"args": envelope.Args, "ts": envelope.Timestamp, "nonce": envelope.Nonce, "confirmation_id": nullIfEmpty(confirmationID)}
	return runtime.HandleInvoke(document, identity.Sign(message), peer)
}
