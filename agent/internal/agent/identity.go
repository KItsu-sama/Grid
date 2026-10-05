package agent

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

type Identity struct {
	DeviceID string
	private  ed25519.PrivateKey
	path     string
}

func LoadIdentity(directory, deviceID string) (*Identity, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	path := filepath.Join(directory, "identity.json")
	data, err := os.ReadFile(path)
	if err == nil {
		var saved struct {
			DeviceID   string `json:"device_id"`
			PrivateKey string `json:"private_key"`
		}
		if err := json.Unmarshal(data, &saved); err != nil {
			return nil, err
		}
		if deviceID != "" && saved.DeviceID != deviceID {
			return nil, errors.New("Agent signing key is bound to a different PersonalGrid device ID")
		}
		seed, err := base64.StdEncoding.DecodeString(saved.PrivateKey)
		if err != nil || len(seed) != ed25519.SeedSize {
			return nil, errors.New("invalid Ed25519 private key in identity file")
		}
		return &Identity{DeviceID: saved.DeviceID, private: ed25519.NewKeyFromSeed(seed), path: path}, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	if deviceID == "" {
		id := make([]byte, 16)
		if _, err := rand.Read(id); err != nil {
			return nil, err
		}
		deviceID = fmtHex(id)
	}
	identity := &Identity{DeviceID: deviceID, private: privateKey, path: path}
	if err := identity.save(); err != nil {
		return nil, err
	}
	return identity, nil
}

func (i *Identity) PublicKey() string {
	return base64.StdEncoding.EncodeToString(i.private.Public().(ed25519.PublicKey))
}

func (i *Identity) Sign(message []byte) string {
	return base64.StdEncoding.EncodeToString(ed25519.Sign(i.private, message))
}

func VerifySignature(publicKey string, message []byte, signature string) bool {
	key, err := base64.StdEncoding.DecodeString(publicKey)
	if err != nil || len(key) != ed25519.PublicKeySize {
		return false
	}
	sig, err := base64.StdEncoding.DecodeString(signature)
	return err == nil && ed25519.Verify(ed25519.PublicKey(key), message, sig)
}

func (i *Identity) save() error {
	data, err := json.Marshal(map[string]string{
		"device_id":   i.DeviceID,
		"private_key": base64.StdEncoding.EncodeToString(i.private.Seed()),
	})
	if err != nil {
		return err
	}
	tmp := i.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, i.path)
}

func fmtHex(data []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, len(data)*2)
	for index, value := range data {
		out[index*2] = digits[value>>4]
		out[index*2+1] = digits[value&15]
	}
	return string(out)
}
