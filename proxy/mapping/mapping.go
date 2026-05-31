// https://github.com/paijp/vps-subdomain-mcp

// Package mapping converts hostnames to Podman container names.
package mapping

import (
	"errors"
	"net"
	"regexp"
	"strings"
)

var labelRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$|^[a-z0-9]$`)

// ContainerName maps a hostname to a Podman container name.
//
//	"alice.example.com" → "alice-web"
//	"example.com"       → "default-web"
//	anything else       → error
func ContainerName(host, domain string) (string, error) {
	host = normalize(host)
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))

	if host == domain {
		return "default-web", nil
	}

	suffix := "." + domain
	if !strings.HasSuffix(host, suffix) {
		return "", errors.New("host not in domain")
	}
	sub := strings.TrimSuffix(host, suffix)

	if strings.Contains(sub, ".") {
		return "", errors.New("multi-level subdomain not allowed")
	}
	if !labelRe.MatchString(sub) {
		return "", errors.New("invalid subdomain label")
	}
	return sub + "-web", nil
}

func normalize(host string) string {
	host = strings.ToLower(host)
	host = strings.TrimSuffix(host, ".")
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	return host
}
