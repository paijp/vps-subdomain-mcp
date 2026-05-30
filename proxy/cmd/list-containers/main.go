// list-containers: queries the Podman REST API and prints each container's
// name, IP address, and state to stdout (tab-separated).
//
// In one-shot mode (default): prints once and exits.
// In loop mode (--loop N):    prints every N seconds, with a "---" separator
//                              after each batch; runs until killed.
//
// Install to: /usr/local/sbin/list-containers  (root-owned, mode 0755)
// Run directly as root or via the pipe in vps-proxy*.service.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
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

var client = &http.Client{
	Timeout: timeout,
	Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: timeout}).DialContext(ctx, "unix", podmanSock)
		},
	},
}

// emit writes the current container list to out.  In loop mode the caller
// appends the "---" separator and flushes.
func emit(out *bufio.Writer) error {
	resp, err := client.Get("http://d/containers/json")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	var containers []container
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxResponse)).Decode(&containers); err != nil {
		return fmt.Errorf("parse: %v", err)
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
		fmt.Fprintf(out, "%s\t%s\t%s\n", name, ip, c.State)
	}
	return nil
}

func main() {
	loop := flag.Int("loop", 0, "seconds between updates (0=one-shot)")
	flag.Parse()

	out := bufio.NewWriter(os.Stdout)

	if *loop == 0 {
		if err := emit(out); err != nil {
			fmt.Fprintf(os.Stderr, "list-containers: %v\n", err)
			os.Exit(1)
		}
		out.Flush()
		return
	}

	// Loop mode: emit entries then "---" separator on each tick.
	tick := func() {
		if err := emit(out); err != nil {
			fmt.Fprintf(os.Stderr, "list-containers: %v\n", err)
			return
		}
		fmt.Fprintln(out, "---")
		out.Flush()
	}

	tick() // first run immediately
	ticker := time.NewTicker(time.Duration(*loop) * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		tick()
	}
}
