package agent

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
)

const genesisHash = "0000000000000000000000000000000000000000000000000000000000000000"

type AuditEntry map[string]any

type AuditLog struct {
	path string
	mu   sync.Mutex
	last string
}

func OpenAudit(path string) (*AuditLog, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	log := &AuditLog{path: path, last: genesisHash}
	entries, err := log.Entries()
	if err != nil {
		return nil, err
	}
	if len(entries) > 0 {
		last, ok := entries[len(entries)-1]["hash"].(string)
		if !ok {
			return nil, os.ErrInvalid
		}
		log.last = last
	}
	return log, nil
}

func (a *AuditLog) Record(source, target, capability string, args any, result string, message string) error {
	entry := AuditEntry{
		"ts":         float64(time.Now().UnixNano()) / 1e9,
		"source":     source,
		"target":     target,
		"capability": capability,
		"args":       redact(args),
		"result":     result,
		"error":      nil,
	}
	if message != "" {
		entry["error"] = message
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	entry["hash"] = digest(a.last, entry)
	entry["prev"] = a.last
	data, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(a.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(append(data, '\n'))
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	a.last = entry["hash"].(string)
	return nil
}

func (a *AuditLog) Entries() ([]AuditEntry, error) {
	file, err := os.Open(a.path)
	if os.IsNotExist(err) {
		return []AuditEntry{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	entries := []AuditEntry{}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 8*1024*1024)
	for scanner.Scan() {
		if strings.TrimSpace(scanner.Text()) == "" {
			continue
		}
		var entry AuditEntry
		if err := json.Unmarshal(scanner.Bytes(), &entry); err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, scanner.Err()
}

func (a *AuditLog) Verify() (bool, int, error) {
	entries, err := a.Entries()
	if err != nil {
		return false, -1, err
	}
	previous := genesisHash
	for index, entry := range entries {
		if len(entry) < 2 {
			return false, index, nil
		}
		gotPrevious, _ := entry["prev"].(string)
		gotHash, _ := entry["hash"].(string)
		body := make(map[string]any, len(entry)-2)
		for key, value := range entry {
			if key != "prev" && key != "hash" {
				body[key] = value
			}
		}
		if gotPrevious != previous || digest(previous, body) != gotHash {
			return false, index, nil
		}
		previous = gotHash
	}
	return true, -1, nil
}

func digest(previous string, body map[string]any) string {
	data, _ := canonicalJSON(body)
	hash := sha256.Sum256(append([]byte(previous), data...))
	return hex.EncodeToString(hash[:])
}

func canonicalJSON(value any) ([]byte, error) {
	var buffer strings.Builder
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	encoded := strings.TrimSuffix(buffer.String(), "\n")
	var ascii strings.Builder
	for _, character := range encoded {
		if character <= 0x7f {
			ascii.WriteRune(character)
			continue
		}
		if character <= 0xffff {
			fmt.Fprintf(&ascii, `\u%04x`, character)
			continue
		}
		high, low := utf16.EncodeRune(character)
		fmt.Fprintf(&ascii, `\u%04x\u%04x`, high, low)
	}
	return []byte(ascii.String()), nil
}

func redact(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(typed))
		for key, item := range typed {
			switch key {
			case "content", "data", "token", "secret", "password":
				out[key] = "<redacted>"
			default:
				out[key] = redact(item)
			}
		}
		return out
	case []any:
		out := make([]any, len(typed))
		for index, item := range typed {
			out[index] = redact(item)
		}
		return out
	default:
		return value
	}
}
