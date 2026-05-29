// vps-proxy: TLS SNI passthrough proxy for port 443.
// Reads the TLS ClientHello, extracts the SNI hostname, and TCP-proxies
// the connection to the matching container without decrypting the traffic.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"time"

	"github.com/paijp/vps-subdomain-mcp/proxy/internal/activation"
	"github.com/paijp/vps-subdomain-mcp/proxy/mapping"
	"github.com/paijp/vps-subdomain-mcp/proxy/routes"
	"github.com/paijp/vps-subdomain-mcp/proxy/sni"
)

func main() {
	domain  := flag.String("domain", "", "base domain, e.g. example.com (required)")
	listBin := flag.String("list-containers", "/usr/local/bin/list-containers", "path to list-containers binary")
	listen  := flag.String("listen", ":443", "fallback listen address (used when not under systemd)")
	flag.Parse()

	if *domain == "" {
		fmt.Fprintln(os.Stderr, "vps-proxy: -domain is required")
		os.Exit(1)
	}

	table := routes.New(*listBin)

	ls, err := activation.Listeners()
	if err != nil {
		log.Fatalf("activation: %v", err)
	}
	var ln net.Listener
	if len(ls) > 0 {
		ln = ls[0]
	} else {
		ln, err = net.Listen("tcp", *listen)
		if err != nil {
			log.Fatalf("listen %s: %v", *listen, err)
		}
	}
	log.Printf("vps-proxy: listening on %s (domain=%s)", ln.Addr(), *domain)

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

	// Read TLS record header (5 bytes).
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	hdr := make([]byte, 5)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return
	}
	if hdr[0] != 0x16 { // not a TLS handshake record
		return
	}
	recLen := int(hdr[3])<<8 | int(hdr[4])
	if recLen > 16384 { // RFC 8446 §5.1: max TLS record payload
		return
	}

	// Read the record body.
	body := make([]byte, recLen)
	if _, err := io.ReadFull(conn, body); err != nil {
		return
	}
	conn.SetReadDeadline(time.Time{})

	full := append(hdr, body...) // header + body for SNI parsing and replay

	hostname, err := sni.Extract(full)
	if err != nil {
		log.Printf("sni: %v", err)
		return
	}

	containerName, err := mapping.ContainerName(hostname, domain)
	if err != nil {
		log.Printf("mapping %q: %v", hostname, err)
		return
	}

	ip, ok := table.LookupIP(containerName)
	if !ok {
		log.Printf("no route: %s → %s", hostname, containerName)
		return
	}

	backend, err := net.DialTimeout("tcp", net.JoinHostPort(ip, "443"), 10*time.Second)
	if err != nil {
		log.Printf("dial %s: %v", ip, err)
		return
	}
	defer backend.Close()

	// PROXY protocol v1: convey the real client IP to the container's nginx so
	// that backend ACLs (e.g. allow 160.79.104.0/21 on /token) work correctly.
	//
	// Security properties:
	//  1. We never read, trust, or forward any PROXY header from the client.
	//  2. Client-supplied PROXY headers are naturally rejected: the SNI parser
	//     returns early when data[0] != 0x16 (PROXY v1 starts with 'P'=0x50,
	//     PROXY v2 starts with 0x0D — neither is a TLS handshake record).
	//  3. The header we generate is derived solely from conn.RemoteAddr().
	//  4. Write order: PROXY header → peeked TLS data → io.Copy.
	if _, err := fmt.Fprintf(backend, "PROXY TCP4 %s %s %d %d\r\n",
		conn.RemoteAddr().(*net.TCPAddr).IP,
		conn.LocalAddr().(*net.TCPAddr).IP,
		conn.RemoteAddr().(*net.TCPAddr).Port,
		conn.LocalAddr().(*net.TCPAddr).Port,
	); err != nil {
		return
	}

	// Replay the already-read TLS bytes, then copy bidirectionally.
	if _, err := backend.Write(full); err != nil {
		return
	}

	go io.Copy(backend, conn) //nolint:errcheck
	io.Copy(conn, backend)    //nolint:errcheck
}
