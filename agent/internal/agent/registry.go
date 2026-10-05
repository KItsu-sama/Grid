package agent

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type Device struct {
	DeviceID     string   `json:"device_id"`
	Name         string   `json:"name"`
	Role         string   `json:"role"`
	State        string   `json:"state"`
	SignPubKey   string   `json:"sign_pubkey"`
	TransportID  string   `json:"transport_id"`
	WGPubKey     string   `json:"wg_pubkey"`
	Address      string   `json:"address"`
	Version      string   `json:"version"`
	LastSeen     float64  `json:"last_seen"`
	Online       bool     `json:"online"`
	Capabilities []string `json:"capabilities"`
	Suspended    bool     `json:"suspended"`
}

type Registry struct {
	db *sql.DB
}

func OpenRegistry(path string) (*Registry, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	statements := []string{
		`CREATE TABLE IF NOT EXISTS devices (
			device_id TEXT PRIMARY KEY, name TEXT, role TEXT, state TEXT, sign_pubkey TEXT,
			transport_id TEXT, wg_pubkey TEXT, address TEXT, version TEXT, last_seen REAL,
			online INTEGER, capabilities TEXT, suspended INTEGER DEFAULT 0)`,
		`CREATE TABLE IF NOT EXISTS grants (
			controller_id TEXT, pattern TEXT, effect TEXT,
			PRIMARY KEY(controller_id, pattern))`,
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			_ = db.Close()
			return nil, err
		}
	}
	return &Registry{db: db}, nil
}

func (r *Registry) Close() error { return r.db.Close() }

func (r *Registry) Get(deviceID string) (*Device, error) {
	row := r.db.QueryRow(`SELECT device_id,name,role,state,sign_pubkey,transport_id,COALESCE(wg_pubkey,''),
		COALESCE(address,''),COALESCE(version,''),COALESCE(last_seen,0),COALESCE(online,0),
		COALESCE(capabilities,''),COALESCE(suspended,0) FROM devices WHERE device_id=?`, deviceID)
	return scanDevice(row)
}

func (r *Registry) List() ([]Device, error) {
	rows, err := r.db.Query(`SELECT device_id,name,role,state,sign_pubkey,transport_id,COALESCE(wg_pubkey,''),
		COALESCE(address,''),COALESCE(version,''),COALESCE(last_seen,0),COALESCE(online,0),
		COALESCE(capabilities,''),COALESCE(suspended,0) FROM devices ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	devices := []Device{}
	for rows.Next() {
		device, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		devices = append(devices, *device)
	}
	return devices, rows.Err()
}

type scanner interface{ Scan(...any) error }

func scanDevice(row scanner) (*Device, error) {
	var device Device
	var online, suspended int
	var capabilities string
	err := row.Scan(&device.DeviceID, &device.Name, &device.Role, &device.State, &device.SignPubKey,
		&device.TransportID, &device.WGPubKey, &device.Address, &device.Version, &device.LastSeen,
		&online, &capabilities, &suspended)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	device.Online, device.Suspended = online != 0, suspended != 0
	if capabilities != "" {
		device.Capabilities = strings.Split(capabilities, ",")
	} else {
		device.Capabilities = []string{}
	}
	return &device, nil
}

func (r *Registry) Register(device Device) (*Device, error) {
	existing, err := r.Get(device.DeviceID)
	if err != nil {
		return nil, err
	}
	if existing == nil {
		_, err = r.db.Exec(`INSERT INTO devices VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0)`, device.DeviceID,
			device.Name, "CLIENT", "pending", device.SignPubKey, device.TransportID, device.WGPubKey,
			device.Address, device.Version, time.Now().UnixNano()/1e9, 1, strings.Join(device.Capabilities, ","))
	} else if existing.SignPubKey != device.SignPubKey || existing.TransportID != device.TransportID {
		return nil, errors.New("identity or transport key mismatch for existing device")
	} else {
		_, err = r.db.Exec(`UPDATE devices SET name=?,wg_pubkey=?,address=?,version=?,capabilities=?,last_seen=? WHERE device_id=?`,
			device.Name, device.WGPubKey, device.Address, device.Version, strings.Join(device.Capabilities, ","),
			time.Now().UnixNano()/1e9, device.DeviceID)
	}
	if err != nil {
		return nil, err
	}
	return r.Get(device.DeviceID)
}

func (r *Registry) Approve(deviceID, role string) (*Device, error) {
	if role != "MAIN" && role != "WORKER" && role != "CLIENT" {
		return nil, errors.New("invalid role")
	}
	device, err := r.Get(deviceID)
	if err != nil || device == nil {
		return device, err
	}
	if device.State == "revoked" {
		return nil, errors.New("revoked devices must re-register with a new identity")
	}
	_, err = r.db.Exec(`UPDATE devices SET state='approved',role=? WHERE device_id=?`, role, deviceID)
	if err != nil {
		return nil, err
	}
	return r.Get(deviceID)
}

func (r *Registry) Revoke(deviceID string) (*Device, error) {
	if _, err := r.db.Exec(`UPDATE devices SET state='revoked' WHERE device_id=?`, deviceID); err != nil {
		return nil, err
	}
	if _, err := r.db.Exec(`DELETE FROM grants WHERE controller_id=?`, deviceID); err != nil {
		return nil, err
	}
	return r.Get(deviceID)
}

func (r *Registry) SetGrant(deviceID, pattern, effect string) error {
	if effect != "allow" && effect != "deny" {
		return errors.New("effect must be allow or deny")
	}
	_, err := r.db.Exec(`INSERT OR REPLACE INTO grants VALUES(?,?,?)`, deviceID, pattern, effect)
	return err
}

func (r *Registry) Grants(deviceID string) ([]Grant, error) {
	rows, err := r.db.Query(`SELECT pattern,effect FROM grants WHERE controller_id=?`, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	grants := []Grant{}
	for rows.Next() {
		var grant Grant
		if err := rows.Scan(&grant.Pattern, &grant.Effect); err != nil {
			return nil, err
		}
		grants = append(grants, grant)
	}
	return grants, rows.Err()
}
