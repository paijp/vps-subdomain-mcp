// Package routes maintains a live container-name → IP routing table
// by reading tab-separated entries from an io.Reader (typically stdin).
package routes

import (
	"bufio"
	"context"
	"io"
	"log"
	"strings"
	"sync"
)

type entry struct {
	name string
	ip   string
}

// Table holds a live mapping of container name → IP address.
type Table struct {
	mu     sync.RWMutex
	byName map[string]string
	reader io.Reader
}

// New creates a Table that reads container updates from r.
// Call Run(ctx) in a goroutine to start consuming the reader.
func New(r io.Reader) *Table {
	return &Table{
		reader: r,
		byName: make(map[string]string),
	}
}

// LookupIP returns the IP for a running container, or ("", false) if unknown.
func (t *Table) LookupIP(containerName string) (string, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	ip, ok := t.byName[containerName]
	return ip, ok
}

// Run reads tab-separated container entries from the reader until it is closed
// or ctx is cancelled.  A "---" line triggers an atomic batch update of the
// routing table.  On pipe close, the last known routes are retained.
func (t *Table) Run(ctx context.Context) {
	scanner := bufio.NewScanner(t.reader)
	var batch []entry
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return
		default:
		}
		line := scanner.Text()
		if line == "---" {
			t.apply(batch)
			batch = nil
			continue
		}
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) >= 2 && parts[0] != "" && parts[1] != "" {
			batch = append(batch, entry{name: parts[0], ip: parts[1]})
		}
	}
	log.Println("routes: stdin closed, keeping last known routes")
}

func (t *Table) apply(batch []entry) {
	m := make(map[string]string, len(batch))
	for _, e := range batch {
		m[e.name] = e.ip
	}
	t.mu.Lock()
	t.byName = m
	t.mu.Unlock()
}
