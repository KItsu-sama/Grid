package agent

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"sync"
	"syscall"
	"time"
)

// ManagedProcess represents a background daemon managed by Grid.
type ManagedProcess struct {
	Name   string
	Path   string
	Args   []string
	Cmd    *exec.Cmd
	Cancel context.CancelFunc
}

// PrefixedWriter redirects child process stdout/stderr with a custom prefix.
type PrefixedWriter struct {
	Prefix string
	Writer io.Writer
}

func (pw *PrefixedWriter) Write(p []byte) (n int, err error) {
	if len(p) == 0 {
		return 0, nil
	}
	header := fmt.Sprintf("[%s] ", pw.Prefix)
	return pw.Writer.Write(append([]byte(header), p...))
}

// StartManagedProcess launches a child daemon with context tracking and log prefixing.
func StartManagedProcess(parentCtx context.Context, name string, path string, args []string) (*ManagedProcess, error) {
	ctx, cancel := context.WithCancel(parentCtx)
	cmd := exec.CommandContext(ctx, path, args...)

	cmd.Stdout = &PrefixedWriter{Prefix: name, Writer: os.Stdout}
	cmd.Stderr = &PrefixedWriter{Prefix: name, Writer: os.Stderr}

	log.Printf("[Grid Supervisor] Starting %s (%s)...", name, path)
	if err := cmd.Start(); err != nil {
		cancel()
		return nil, fmt.Errorf("failed to start %s: %w", name, err)
	}

	return &ManagedProcess{
		Name:   name,
		Path:   path,
		Args:   args,
		Cmd:    cmd,
		Cancel: cancel,
	}, nil
}

// WaitAndMonitor watches for unexpected termination of child processes.
func (mp *ManagedProcess) WaitAndMonitor(wg *sync.WaitGroup) {
	defer wg.Done()
	if mp == nil || mp.Cmd == nil {
		return
	}

	err := mp.Cmd.Wait()
	if err != nil {
		log.Printf("[Grid Supervisor] %s exited with error/status: %v", mp.Name, err)
	} else {
		log.Printf("[Grid Supervisor] %s exited cleanly.", mp.Name)
	}
}

// WaitForSyncthingHealth polls Syncthing's local REST interface until it is ready.
func WaitForSyncthingHealth(ctx context.Context, targetURL string, timeout time.Duration) error {
	log.Printf("[Grid Supervisor] Waiting for Syncthing API at %s...", targetURL)
	client := &http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, targetURL, nil)
			if err == nil {
				resp, err := client.Do(req)
				if err == nil {
					_ = resp.Body.Close()
					if resp.StatusCode == http.StatusOK {
						log.Println("[Grid Supervisor] Syncthing REST API is UP and ready!")
						return nil
					}
				}
			}
			time.Sleep(1 * time.Second)
		}
	}
	return fmt.Errorf("timeout waiting for Syncthing at %s", targetURL)
}

// StopGracefully attempts a soft signal stop, falling back to forceful termination.
func (mp *ManagedProcess) StopGracefully() {
	if mp == nil || mp.Cmd == nil || mp.Cmd.Process == nil {
		return
	}

	log.Printf("[Grid Supervisor] Stopping %s (PID: %d)...", mp.Name, mp.Cmd.Process.Pid)

	if runtime.GOOS == "windows" {
		_ = mp.Cmd.Process.Kill()
	} else {
		_ = mp.Cmd.Process.Signal(syscall.SIGINT)
	}

	if mp.Cancel != nil {
		mp.Cancel()
	}
}
