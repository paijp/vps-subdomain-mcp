// https://github.com/paijp/vps-subdomain-mcp

// Package activation implements systemd socket activation (sd_listen_fds).
// Uses only the standard library; no external dependencies.
package activation

import (
	"fmt"
	"net"
	"os"
	"strconv"
)

const listenFDsStart = 3

// Listeners returns net.Listeners from file descriptors passed by systemd.
// Returns nil, nil when not running under systemd (LISTEN_FDS unset).
func Listeners() ([]net.Listener, error) {
	pidStr := os.Getenv("LISTEN_PID")
	fdsStr := os.Getenv("LISTEN_FDS")
	if pidStr == "" || fdsStr == "" {
		return nil, nil
	}

	pid, err := strconv.Atoi(pidStr)
	// In the pipe architecture (list-containers | setpriv ... vps-proxy),
	// LISTEN_PID is the shell's PID, not vps-proxy's.  Accept the parent PID.
	if err != nil || (pid != os.Getpid() && pid != os.Getppid()) {
		return nil, nil
	}

	n, err := strconv.Atoi(fdsStr)
	if err != nil || n <= 0 {
		return nil, fmt.Errorf("invalid LISTEN_FDS: %q", fdsStr)
	}

	ls := make([]net.Listener, n)
	for i := range n {
		fd := listenFDsStart + i
		f := os.NewFile(uintptr(fd), fmt.Sprintf("listen-fd-%d", fd))
		if f == nil {
			return nil, fmt.Errorf("fd %d is invalid", fd)
		}
		l, err := net.FileListener(f)
		f.Close() // FileListener dups the fd; close the original
		if err != nil {
			return nil, fmt.Errorf("fd %d: %w", fd, err)
		}
		ls[i] = l
	}

	// Prevent child processes from seeing these env vars.
	os.Unsetenv("LISTEN_PID")
	os.Unsetenv("LISTEN_FDS")
	os.Unsetenv("LISTEN_FDNAMES")

	return ls, nil
}
