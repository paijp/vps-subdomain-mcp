// vps-proxy-http: TCP passthrough proxy for port 80.
// Reads the first HTTP request bytes, extracts the Host header,
// and TCP-proxies the connection to the matching container without
// any header modification.  HTTPS redirect responsibility lies with
// the container's nginx.
// Must be run under vps-proxy80.socket (systemd socket activation).
package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"time"

	"github.com/paijp/vps-subdomain-mcp/proxy/internal/activation"
	"github.com/paijp/vps-subdomain-mcp/proxy/mapping"
	"github.com/paijp/vps-subdomain-mcp/proxy/routes"
)

func main() {
	domain := flag.String("domain", "", "base domain, e.g. example.com (required)")
	flag.Parse()

	if *domain == "" {
		fmt.Fprintln(os.Stderr, "vps-proxy-http: -domain is required")
		os.Exit(1)
	}

	table := routes.New(os.Stdin)
	go table.Run(context.Background())

	ls, err := activation.Listeners()
	if err != nil {
		log.Fatalf("activation: %v", err)
	}
	if len(ls) == 0 {
		log.Fatal("vps-proxy-http: no socket activation listener; run under vps-proxy80.socket")
	}
	ln := ls[0]
	log.Printf("vps-proxy-http: listening on %s (domain=%s)", ln.Addr(), *domain)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go handle(conn, *domain, table)
	}
}

func handle(conn net.Conn, domain string, table *routes.Table) {
	defer conn.Close()

	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	buf := make([]byte, 8192)
	n, err := conn.Read(buf)
	conn.SetReadDeadline(time.Time{})
	if err != nil || n == 0 {
		return
	}
	data := buf[:n]

	// Extract the Host header value from the raw HTTP request.
	var host string
	for _, line := range bytes.Split(data, []byte("\r\n")) {
		lower := strings.ToLower(string(line))
		if strings.HasPrefix(lower, "host:") {
			host = strings.TrimSpace(string(line[5:]))
			break
		}
	}
	if host == "" {
		return
	}

	containerName, err := mapping.ContainerName(host, domain)
	if err != nil {
		log.Printf("mapping %q: %v", host, err)
		return
	}

	ip, ok := table.LookupIP(containerName)
	if !ok && containerName != "default-web" {
		containerName = "default-web"
		ip, ok = table.LookupIP("default-web")
	}
	if !ok {
		log.Printf("no route: %s (no container, no default-web)", host)
		return
	}

	backend, err := net.DialTimeout("tcp", net.JoinHostPort(ip, "80"), 10*time.Second)
	if err != nil {
		log.Printf("dial %s: %v", ip, err)
		return
	}
	defer backend.Close()

	// Replay the buffered bytes, then copy bidirectionally.
	if _, err := backend.Write(data); err != nil {
		return
	}

	go io.Copy(backend, conn) //nolint:errcheck
	io.Copy(conn, backend)    //nolint:errcheck
}
