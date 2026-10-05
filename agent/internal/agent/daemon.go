package agent

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func RunDaemon(config Config, deviceID string) error {
	runtime, err := NewRuntime(config, deviceID)
	if err != nil {
		return err
	}
	defer runtime.Registry.Close()
	localAddress := fmt.Sprintf("127.0.0.1:%d", config.LocalPort)
	localListener, err := net.Listen("tcp", localAddress)
	if err != nil {
		return fmt.Errorf("cannot bind local API %s: %w", localAddress, err)
	}
	localServer := &http.Server{Handler: runtime.LocalHandler(), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := localServer.Serve(localListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintln(os.Stderr, "local API:", err)
		}
	}()
	status := TailscaleStatus()
	peerIP := peerAddress(status)
	if status.Running && status.LoggedIn && peerIP != "" && status.Owner != "" && strings.EqualFold(status.Owner, config.OwnerLogin) {
		address := net.JoinHostPort(peerIP, fmt.Sprint(config.PeerPort))
		listener, err := net.Listen("tcp", address)
		if err != nil {
			_ = localServer.Close()
			return fmt.Errorf("cannot bind peer API %s: %w", address, err)
		}
		peerServer := &http.Server{Handler: runtime.PeerHandler(), ReadHeaderTimeout: 5 * time.Second}
		go func() {
			if err := peerServer.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
				fmt.Fprintln(os.Stderr, "peer API:", err)
			}
		}()
		defer peerServer.Close()
		fmt.Printf("PersonalGrid Agent %s listening locally and on %s\n", AgentVersion, address)
	} else {
		fmt.Printf("PersonalGrid Agent %s listening locally; peer API disabled (Tailscale is not ready or owner differs)\n", AgentVersion)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	select {
	case <-ctx.Done():
	case <-runtime.shutdown:
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return localServer.Shutdown(shutdown)
}
