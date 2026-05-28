// Package sni extracts the SNI hostname from a TLS ClientHello record.
package sni

import (
	"encoding/binary"
	"errors"
)

var (
	ErrNotTLS         = errors.New("not a TLS handshake record")
	ErrNotClientHello = errors.New("not a ClientHello message")
	ErrNoSNI          = errors.New("no SNI extension")
	ErrTruncated      = errors.New("record truncated")
)

// Extract returns the SNI hostname from raw TLS data.
// data must include the 5-byte TLS record header.
// Every byte access is bounds-checked; malformed input returns an error, never panics.
func Extract(data []byte) (string, error) {
	// TLS record header: type(1) + legacy_version(2) + length(2)
	if len(data) < 5 {
		return "", ErrTruncated
	}
	if data[0] != 0x16 { // handshake
		return "", ErrNotTLS
	}
	recLen := int(binary.BigEndian.Uint16(data[3:5]))
	if len(data) < 5+recLen {
		return "", ErrTruncated
	}
	hs := data[5 : 5+recLen]

	// Handshake header: msg_type(1) + length(3)
	if len(hs) < 4 {
		return "", ErrTruncated
	}
	if hs[0] != 0x01 { // ClientHello
		return "", ErrNotClientHello
	}
	hsLen := int(hs[1])<<16 | int(hs[2])<<8 | int(hs[3])
	if len(hs) < 4+hsLen {
		return "", ErrTruncated
	}
	ch := hs[4 : 4+hsLen]

	// ClientHello body: skip fixed fields then variable-length ones
	p := 0
	skip := func(n int) bool { // advance p by n; return false if out of bounds
		if p+n > len(ch) {
			return false
		}
		p += n
		return true
	}
	readU8 := func() (int, bool) {
		if p >= len(ch) {
			return 0, false
		}
		v := int(ch[p])
		p++
		return v, true
	}
	readU16 := func() (int, bool) {
		if p+2 > len(ch) {
			return 0, false
		}
		v := int(binary.BigEndian.Uint16(ch[p:]))
		p += 2
		return v, true
	}

	if !skip(2 + 32) { // client_version + random
		return "", ErrTruncated
	}
	sidLen, ok := readU8() // session_id length
	if !ok || !skip(sidLen) {
		return "", ErrTruncated
	}
	csLen, ok := readU16() // cipher_suites length
	if !ok || !skip(csLen) {
		return "", ErrTruncated
	}
	cmLen, ok := readU8() // compression_methods length
	if !ok || !skip(cmLen) {
		return "", ErrTruncated
	}

	// Extensions
	extTotal, ok := readU16()
	if !ok {
		return "", ErrNoSNI
	}
	if p+extTotal > len(ch) {
		return "", ErrTruncated
	}
	exts := ch[p : p+extTotal]

	for i := 0; i+4 <= len(exts); {
		extType := binary.BigEndian.Uint16(exts[i:])
		extLen := int(binary.BigEndian.Uint16(exts[i+2:]))
		i += 4
		if i+extLen > len(exts) {
			return "", ErrTruncated
		}
		if extType == 0x0000 { // server_name
			d := exts[i : i+extLen]
			if len(d) < 5 {
				return "", ErrTruncated
			}
			listLen := int(binary.BigEndian.Uint16(d[0:]))
			if len(d) < 2+listLen {
				return "", ErrTruncated
			}
			d = d[2 : 2+listLen]
			if d[0] != 0x00 { // name_type: host_name
				return "", ErrNoSNI
			}
			nameLen := int(binary.BigEndian.Uint16(d[1:]))
			if len(d) < 3+nameLen {
				return "", ErrTruncated
			}
			return string(d[3 : 3+nameLen]), nil
		}
		i += extLen
	}
	return "", ErrNoSNI
}
