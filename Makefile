IMAGE ?= vps-mcp:latest

# After %.setupdone runs, DOMAIN and IP are stored in /etc/vps-mcp/host.env.
# Subsequent targets read them automatically — no need to pass DOMAIN on the
# command line.
DOMAIN ?= $(shell grep '^DOMAIN=' /etc/vps-mcp/host.env 2>/dev/null | cut -d= -f2)
IP     ?= $(shell grep '^IP='     /etc/vps-mcp/host.env 2>/dev/null | cut -d= -f2)

# Parse "word1__word2" stems
ip_of     = $(word 1,$(subst __, ,$(1)))
domain_of = $(word 2,$(subst __, ,$(1)))
sub_of    = $(word 1,$(subst __, ,$(1)))
email_of  = $(word 2,$(subst __, ,$(1)))

.DEFAULT_GOAL := help
.PHONY: help image install-binaries install-services list

# ── help ──────────────────────────────────────────────────────────────────────

help:
	@printf "vps-subdomain-mcp — VPS seminar container management\n\n"
	@printf "Host setup (run once as root):\n"
	@printf "  make 203.0.113.1__example.com.setupdone\n"
	@printf "      Configure hostname, BIND wildcard DNS, proxy services, nftables.\n"
	@printf "      After this, DOMAIN is read from /etc/vps-mcp/host.env automatically.\n\n"
	@printf "Rebuild components individually:\n"
	@printf "  make image                Build container image\n"
	@printf "  make install-binaries     Build and install Go proxy binaries\n"
	@printf "  make install-services     (Re)install unit files and nftables\n\n"
	@printf "Container management:\n"
	@printf "  make alice__alice@ex.com.done   Create VPS for alice\n"
	@printf "  make list                       List running VPS containers\n\n"
	@printf "Variables:\n"
	@printf "  IMAGE   Container image tag (default: vps-mcp:latest)\n"

# ── host setup ────────────────────────────────────────────────────────────────
# Usage: make 203.0.113.1__example.com.setupdone
#
# 1. Set hostname to ns1.<domain>
# 2. Write /etc/vps-mcp/host.env  (DOMAIN, IP)
# 3. Install BIND9, configure wildcard zone, reload
# 4. Build container image
# 5. Install Go proxy binaries
# 6. Install proxy systemd units + nftables

%.setupdone:
	$(eval _IP     := $(call ip_of,$*))
	$(eval _DOMAIN := $(call domain_of,$*))
	@test -n "$(_IP)"     || { echo "Error: format is  IP__DOMAIN.setupdone  e.g. 203.0.113.1__example.com.setupdone"; exit 1; }
	@test -n "$(_DOMAIN)" || { echo "Error: format is  IP__DOMAIN.setupdone  e.g. 203.0.113.1__example.com.setupdone"; exit 1; }
	hostnamectl set-hostname ns1.$(_DOMAIN)
	mkdir -p /etc/vps-mcp
	printf 'DOMAIN=%s\nIP=%s\n' "$(_DOMAIN)" "$(_IP)" > /etc/vps-mcp/host.env
	apt-get install -y bind9
	mkdir -p /etc/bind/zones
	sed -e 's|__IP__|$(_IP)|g' \
	    -e 's|__DOMAIN__|$(_DOMAIN)|g' \
	    -e "s|__SERIAL__|$$(date +%Y%m%d01)|g" \
	    host/bind/zone.tmpl > /etc/bind/zones/$(_DOMAIN).zone
	sed 's|__DOMAIN__|$(_DOMAIN)|g' \
	    host/bind/named.conf.local.tmpl > /etc/bind/named.conf.local
	systemctl enable --now named
	rndc reload 2>/dev/null || true
	$(MAKE) image
	$(MAKE) install-binaries
	$(MAKE) install-services DOMAIN=$(_DOMAIN)
	@touch $@

# ── image ─────────────────────────────────────────────────────────────────────

image:
	podman build -t $(IMAGE) container/

# ── install-binaries ──────────────────────────────────────────────────────────

install-binaries:
	cd proxy && go build -o /usr/local/bin/list-containers  ./cmd/list-containers
	chown root:root /usr/local/bin/list-containers
	chmod 4755      /usr/local/bin/list-containers
	cd proxy && go build -o /usr/local/sbin/vps-proxy       ./cmd/vps-proxy
	cd proxy && go build -o /usr/local/sbin/vps-proxy-http  ./cmd/vps-proxy-http

# ── install-services ──────────────────────────────────────────────────────────

install-services:
	@test -n "$(DOMAIN)" || \
	    { echo "Error: DOMAIN is required.  Example: make install-services DOMAIN=example.com"; exit 1; }
	mkdir -p /etc/vps-mcp
	printf 'DOMAIN=%s\nIP=%s\n' "$(DOMAIN)" "$(IP)" > /etc/vps-mcp/host.env
	install -m 644 host/systemd/vps-proxy.service      /etc/systemd/system/
	install -m 644 host/systemd/vps-proxy-http.service /etc/systemd/system/
	systemctl daemon-reload
	systemctl enable --now vps-proxy vps-proxy-http
	install -m 644 host/nftables/vps-mcp.nft /etc/nftables.d/vps-mcp.nft
	grep -qF 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null || \
	    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
	systemctl enable nftables
	nft -f /etc/nftables.d/vps-mcp.nft

# ── container creation ────────────────────────────────────────────────────────
# Usage: make alice__alice@gmail.com.done
# DOMAIN is read automatically from /etc/vps-mcp/host.env after setupdone.

%.done:
	@test -n "$(DOMAIN)" || \
	    { echo "Error: DOMAIN not set.  Run make IP__DOMAIN.setupdone first."; exit 1; }
	podman run -d \
	    --name     $(call sub_of,$*)-web \
	    --hostname $(call sub_of,$*).$(DOMAIN) \
	    --systemd  always \
	    --env      SUBDOMAIN=$(call sub_of,$*).$(DOMAIN) \
	    --env      NOTIFY_EMAIL=$(call email_of,$*) \
	    $(IMAGE)
	podman exec $(call sub_of,$*)-web /usr/local/bin/vps-mcp-init.sh
	@touch $@

# ── list ──────────────────────────────────────────────────────────────────────

list:
	@podman ps --filter "name=-web" --format "table {{.Names}}\t{{.Status}}\t{{.IPAddress}}"
