package agent

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
)

func (r *Runtime) localHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if subtle.ConstantTimeCompare([]byte(request.Header.Get("Authorization")), []byte("Bearer "+r.AdminToken)) != 1 {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"detail": "unauthorized"})
			return
		}
		r.routeLocal(w, request)
	})
}

func (r *Runtime) routeLocal(w http.ResponseWriter, request *http.Request) {
	parts := splitPath(request.URL.Path)
	if len(parts) == 1 && parts[0] == "shutdown" {
		if request.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"detail": "method not allowed"})
			return
		}
		select {
		case r.shutdown <- struct{}{}:
		default:
		}
		writeJSON(w, http.StatusAccepted, map[string]any{"ok": true, "shutting_down": true})
		return
	}
	if len(parts) == 1 && parts[0] == "status" && request.Method == http.MethodGet {
		devices, err := r.Registry.List()
		if err != nil {
			writeError(w, err)
			return
		}
		network := TailscaleStatus()
		states := map[string]int{"pending": 0, "approved": 0, "revoked": 0}
		for _, device := range devices {
			states[device.State]++
		}
		writeJSON(w, http.StatusOK, map[string]any{"device_id": r.Identity.DeviceID, "name": r.Config.DeviceName,
			"role": r.Config.Role, "network": network, "capabilities": r.Capabilities(), "devices": states})
		return
	}
	if len(parts) == 1 && parts[0] == "devices" && request.Method == http.MethodGet {
		devices, err := r.Registry.List()
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, devices)
		return
	}
	if len(parts) == 1 && parts[0] == "audit" && request.Method == http.MethodGet {
		entries, err := r.Audit.Entries()
		if err != nil {
			writeError(w, err)
			return
		}
		limit, err := strconv.Atoi(request.URL.Query().Get("limit"))
		if err != nil || limit == 0 {
			limit = 50
		}
		if limit < 0 {
			limit = 0
		}
		if limit < len(entries) {
			entries = entries[len(entries)-limit:]
		}
		ok, bad, err := r.Audit.Verify()
		if err != nil {
			writeError(w, err)
			return
		}
		response := map[string]any{"chain_ok": ok, "entries": entries}
		if !ok {
			response["bad_entry"] = bad
		}
		writeJSON(w, http.StatusOK, response)
		return
	}
	if len(parts) == 1 && parts[0] == "confirmations" && request.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, r.PendingConfirmations())
		return
	}
	if len(parts) == 3 && parts[0] == "confirmations" && request.Method == http.MethodPost {
		if parts[2] != "approve" && parts[2] != "deny" {
			writeJSON(w, http.StatusNotFound, map[string]any{"detail": "not found"})
			return
		}
		if err := r.DecideConfirmation(parts[1], parts[2] == "approve"); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"detail": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if len(parts) >= 3 && parts[0] == "devices" {
		device, err := r.resolveDevice(parts[1])
		if err != nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"detail": "unknown device"})
			return
		}
		if len(parts) == 3 && parts[2] == "approve" && request.Method == http.MethodPost {
			body := map[string]any{}
			if err := decodeBody(request, &body); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]any{"detail": "malformed request"})
				return
			}
			role := strings.ToUpper(stringValue(body["role"], "CLIENT"))
			approved, err := r.Registry.Approve(device.DeviceID, role)
			if err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]any{"detail": err.Error()})
				return
			}
			_ = r.Audit.Record("local-admin", device.DeviceID, "admin.approve", map[string]any{"role": role}, "ok", "")
			writeJSON(w, http.StatusOK, approved)
			return
		}
		if len(parts) == 3 && parts[2] == "revoke" && request.Method == http.MethodPost {
			revoked, err := r.Registry.Revoke(device.DeviceID)
			if err != nil {
				writeError(w, err)
				return
			}
			_ = r.Audit.Record("local-admin", device.DeviceID, "admin.revoke", map[string]any{}, "ok", "")
			writeJSON(w, http.StatusOK, revoked)
			return
		}
		if len(parts) == 3 && parts[2] == "grants" && request.Method == http.MethodPost {
			body := map[string]any{}
			if err := decodeBody(request, &body); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]any{"detail": "malformed request"})
				return
			}
			pattern, _ := body["pattern"].(string)
			effect, _ := body["effect"].(string)
			if pattern == "" || (effect != "allow" && effect != "deny") {
				writeJSON(w, http.StatusBadRequest, map[string]any{"detail": "pattern and allow/deny effect are required"})
				return
			}
			if err := r.Registry.SetGrant(device.DeviceID, pattern, effect); err != nil {
				writeError(w, err)
				return
			}
			grants, err := r.Registry.Grants(device.DeviceID)
			if err != nil {
				writeError(w, err)
				return
			}
			_ = r.Audit.Record("local-admin", device.DeviceID, "admin.grant", body, "ok", "")
			writeJSON(w, http.StatusOK, map[string]any{"grants": grants})
			return
		}
	}
	writeJSON(w, http.StatusNotFound, map[string]any{"detail": "not found"})
}

func (r *Runtime) resolveDevice(selector string) (*Device, error) {
	device, err := r.Registry.Get(selector)
	if err != nil || device != nil {
		return device, err
	}
	devices, err := r.Registry.List()
	if err != nil {
		return nil, err
	}
	var match *Device
	for index := range devices {
		candidate := &devices[index]
		if strings.HasPrefix(candidate.DeviceID, selector) || candidate.Name == selector {
			if match != nil {
				return nil, nil
			}
			match = candidate
		}
	}
	return match, nil
}

func splitPath(path string) []string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 1 && parts[0] == "" {
		return nil
	}
	return parts
}

func decodeBody(request *http.Request, destination any) error {
	defer request.Body.Close()
	data, err := io.ReadAll(io.LimitReader(request.Body, (1<<20)+1))
	if err != nil {
		return err
	}
	if len(data) > 1<<20 {
		return errors.New("request body is too large")
	}
	return json.Unmarshal(data, destination)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, err error) {
	writeJSON(w, http.StatusInternalServerError, map[string]any{"detail": err.Error()})
}
