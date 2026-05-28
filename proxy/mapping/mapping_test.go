package mapping_test

import (
	"testing"

	"github.com/paijp/vps-subdomain-mcp/proxy/mapping"
)

const domain = "example.com"

func TestContainerName(t *testing.T) {
	cases := []struct {
		host    string
		want    string
		wantErr bool
	}{
		{"alice.example.com", "alice-web", false},
		{"bob.example.com", "bob-web", false},
		{"example.com", "default-web", false},
		// normalization
		{"Alice.Example.Com", "alice-web", false},
		{"alice.example.com.", "alice-web", false},  // trailing dot
		{"alice.example.com:80", "alice-web", false}, // with port
		// errors
		{"alice.bob.example.com", "", true},   // multi-level
		{"other.domain.com", "", true},        // wrong domain
		{"alice_.example.com", "", true},      // invalid char
		{"-alice.example.com", "", true},      // leading hyphen
		{"alice-.example.com", "", true},      // trailing hyphen
		{"alice--bob.example.com", "alice--bob-web", false}, // double hyphen OK
		{"a.example.com", "a-web", false},     // single char
	}

	for _, c := range cases {
		got, err := mapping.ContainerName(c.host, domain)
		if c.wantErr {
			if err == nil {
				t.Errorf("ContainerName(%q) = %q, want error", c.host, got)
			}
		} else {
			if err != nil {
				t.Errorf("ContainerName(%q) error: %v", c.host, err)
			} else if got != c.want {
				t.Errorf("ContainerName(%q) = %q, want %q", c.host, got, c.want)
			}
		}
	}
}
