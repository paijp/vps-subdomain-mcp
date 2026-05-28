// list-containers: setuid-root helper that queries the Podman REST API and
// prints each container's name, IP address, and state to stdout (tab-separated).
//
// Build (static binary, no CGO):
//   CGO_ENABLED=0 go build -o list-containers ./cmd/list-containers
//   chown root:root list-containers && chmod 4755 list-containers
//
// Install to: /usr/local/bin/list-containers
//
// No arguments consumed, no stdin read, no environment variables used.
// Only issues GET requests to the Podman API; never writes.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

const (
	podmanSock  = "/run/podman/podman.sock"
	maxResponse = 1 << 20 // 1 MiB cap on API response body
	timeout     = 5 * time.Second
)

type container struct {
	Names           []string `json:"Names"`
	State           string   `json:"State"`
	NetworkSettings struct {
		Networks map[string]struct {
			IPAddress string `json:"IPAddress"`
		} `json:"Networks"`
	} `json:"NetworkSettings"`
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "list-containers: "+format+"\n", a...)
	os.Exit(1)
}

func main() {
	client := &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{Timeout: timeout}).DialContext(ctx, "unix", podmanSock)
			},
		},
	}

	resp, err := client.Get("http://d/containers/json?all=true")
	if err != nil {
		fatal("%v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		fatal("HTTP %d", resp.StatusCode)
	}

	var containers []container
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxResponse)).Decode(&containers); err != nil {
		fatal("parse: %v", err)
	}

	for _, c := range containers {
		name := ""
		if len(c.Names) > 0 {
			name = c.Names[0]
			if len(name) > 0 && name[0] == '/' {
				name = name[1:]
			}
		}

		ip := ""
		for _, n := range c.NetworkSettings.Networks {
			if n.IPAddress != "" {
				ip = n.IPAddress
				break
			}
		}

		fmt.Printf("%s\t%s\t%s\n", name, ip, c.State)
	}
}
