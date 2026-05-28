// Package routes maintains a live container-name → IP routing table
// by periodically running the list-containers binary.
package routes

import (
	"bufio"
	"bytes"
	"context"
	"log"
	"os/exec"
	"strings"
	"sync"
	"time"
)

const (
	refreshInterval = 5 * time.Second
	execTimeout     = 5 * time.Second
)

// Table holds a live mapping of container name → IP address.
type Table struct {
	mu  sync.RWMutex
	ips map[string]string
	bin string
}

// New creates a Table and starts a background goroutine that refreshes
// the routing table every 5 seconds by running bin (list-containers).
// The first refresh runs synchronously before New returns.
func New(bin string) *Table {
	t := &Table{bin: bin, ips: make(map[string]string)}
	if err := t.update(); err != nil {
		log.Printf("routes: initial update: %v", err)
	}
	go t.loop()
	return t
}

// LookupIP returns the IP for a running container, or ("", false) if unknown.
func (t *Table) LookupIP(containerName string) (string, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	ip, ok := t.ips[containerName]
	return ip, ok
}

func (t *Table) loop() {
	ticker := time.NewTicker(refreshInterval)
	defer ticker.Stop()
	for range ticker.C {
		if err := t.update(); err != nil {
			log.Printf("routes: %v", err)
		}
	}
}

func (t *Table) update() error {
	ctx, cancel := context.WithTimeout(context.Background(), execTimeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, t.bin).Output()
	if err != nil {
		return err
	}

	m := make(map[string]string)
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		fields := strings.SplitN(scanner.Text(), "\t", 3)
		if len(fields) >= 2 && fields[0] != "" && fields[1] != "" {
			m[fields[0]] = fields[1]
		}
	}

	t.mu.Lock()
	t.ips = m
	t.mu.Unlock()
	return nil
}
