package sni_test

import (
	"crypto/tls"
	"net"
	"testing"

	"github.com/paijp/vps-subdomain-mcp/proxy/sni"
)

// captureClientHello dials a TLS connection to a net.Pipe and captures the
// raw ClientHello bytes sent by crypto/tls.
func captureClientHello(t *testing.T, host string) []byte {
	t.Helper()
	client, server := net.Pipe()

	helloCh := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 4096)
		n, _ := server.Read(buf)
		helloCh <- append([]byte(nil), buf[:n]...)
		server.Close()
	}()
	go func() {
		c := tls.Client(client, &tls.Config{
			ServerName:         host,
			InsecureSkipVerify: true, //nolint:gosec // test only
		})
		c.Handshake() //nolint:errcheck // server immediately closes; error expected
		client.Close()
	}()

	return <-helloCh
}

func TestExtract_RealClientHello(t *testing.T) {
	const host = "alice.example.com"
	data := captureClientHello(t, host)
	got, err := sni.Extract(data)
	if err != nil {
		t.Fatalf("Extract error: %v", err)
	}
	if got != host {
		t.Errorf("got %q, want %q", got, host)
	}
}

func TestExtract_Truncation(t *testing.T) {
	data := captureClientHello(t, "alice.example.com")
	// Every prefix shorter than the full record must not panic.
	for n := 0; n < len(data); n++ {
		if _, err := sni.Extract(data[:n]); err == nil {
			t.Errorf("Extract(data[:%d]) returned nil error, expected non-nil", n)
		}
	}
}

func TestExtract_InvalidInputs(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		want error
	}{
		{"empty", []byte{}, sni.ErrTruncated},
		{"too short", []byte{0x16, 0x03, 0x01}, sni.ErrTruncated},
		{"not TLS", []byte{0x17, 0x03, 0x01, 0x00, 0x01, 0x00}, sni.ErrNotTLS},
		{"not clienthello", func() []byte {
			// Build a minimal handshake record with msg_type = 0x02 (ServerHello)
			b := make([]byte, 5+4+2)
			b[0] = 0x16
			b[3] = 0x00
			b[4] = 6 // record len = 6
			b[5] = 0x02 // ServerHello
			// handshake length = 2
			b[7] = 0x00
			b[8] = 0x02
			return b
		}(), sni.ErrNotClientHello},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := sni.Extract(c.data)
			if err != c.want {
				t.Errorf("got %v, want %v", err, c.want)
			}
		})
	}
}
