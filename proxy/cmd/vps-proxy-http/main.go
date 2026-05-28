// vps-proxy-http: HTTP reverse proxy for port 80.
// Forwards all HTTP requests to the container matching the Host header.
// No redirect logic; the container's own nginx handles HTTP→HTTPS if needed.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"

	"github.com/paijp/vps-subdomain-mcp/proxy/internal/activation"
	"github.com/paijp/vps-subdomain-mcp/proxy/mapping"
	"github.com/paijp/vps-subdomain-mcp/proxy/routes"
)

func main() {
	domain  := flag.String("domain", "", "base domain, e.g. example.com (required)")
	listBin := flag.String("list-containers", "/usr/local/bin/list-containers", "path to list-containers binary")
	listen  := flag.String("listen", ":80", "fallback listen address (used when not under systemd)")
	flag.Parse()

	if *domain == "" {
		fmt.Fprintln(os.Stderr, "vps-proxy-http: -domain is required")
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
	log.Printf("vps-proxy-http: listening on %s (domain=%s)", ln.Addr(), *domain)

	srv := &http.Server{
		Handler: &handler{domain: *domain, table: table},
	}
	if err := srv.Serve(ln); err != nil {
		log.Fatal(err)
	}
}

type handler struct {
	domain string
	table  *routes.Table
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	containerName, err := mapping.ContainerName(r.Host, h.domain)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	ip, ok := h.table.LookupIP(containerName)
	if !ok {
		http.Error(w, "container not running", http.StatusBadGateway)
		return
	}

	target := &url.URL{Scheme: "http", Host: net.JoinHostPort(ip, "80")}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("proxy error %s: %v", r.Host, err)
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}
	proxy.ServeHTTP(w, r)
}
