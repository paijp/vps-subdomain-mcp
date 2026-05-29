IMAGE  ?= vps-mcp:latest
DOMAIN ?=

# Helper functions: parse "subdomain__email" stem
sub_of   = $(word 1,$(subst __, ,$(1)))
email_of = $(word 2,$(subst __, ,$(1)))

.DEFAULT_GOAL := help
.PHONY: help setup image install-binaries install-services list

# ── help ──────────────────────────────────────────────────────────────────────

help:
	@printf "vps-subdomain-mcp — VPS seminar container management\n\n"
	@printf "Setup (run once as root):\n"
	@printf "  make setup DOMAIN=example.com           Build image, install binaries,\n"
	@printf "                                          unit files, and nftables rules\n"
	@printf "  make image                              Build container image only\n"
	@printf "  make install-binaries                   Build and install Go proxy binaries\n"
	@printf "  make install-services DOMAIN=example.com  Install unit files and nftables\n\n"
	@printf "Container management:\n"
	@printf "  make DOMAIN=d alice__alice@ex.com.done  Create VPS for alice (subdomain=alice)\n"
	@printf "  make list                               List running VPS containers\n\n"
	@printf "Variables:\n"
	@printf "  DOMAIN  Base domain, e.g. example.com  (required for setup and container creation)\n"
	@printf "  IMAGE   Container image tag             (default: vps-mcp:latest)\n"

# ── setup ─────────────────────────────────────────────────────────────────────

setup: image install-binaries install-services

image:
	podman build -t $(IMAGE) container/

install-binaries:
	cd proxy && go build -o /usr/local/bin/list-containers  ./cmd/list-containers
	chown root:root /usr/local/bin/list-containers
	chmod 4755      /usr/local/bin/list-containers
	cd proxy && go build -o /usr/local/sbin/vps-proxy       ./cmd/vps-proxy
	cd proxy && go build -o /usr/local/sbin/vps-proxy-http  ./cmd/vps-proxy-http

install-services:
	@test -n "$(DOMAIN)" || \
	    { echo "Error: DOMAIN is required.  Example: make install-services DOMAIN=example.com"; exit 1; }
	mkdir -p /etc/vps-mcp
	printf 'DOMAIN=%s\n' "$(DOMAIN)" > /etc/vps-mcp/host.env
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
# Usage: make DOMAIN=example.com alice__alice@gmail.com.done
#
# The target filename encodes subdomain and notify-email separated by __.
# The .done file records that the container was successfully created and
# initialised; it is not re-created on subsequent make invocations.

%.done:
	@test -n "$(DOMAIN)" || \
	    { echo "Error: DOMAIN is required.  Example: make DOMAIN=example.com $@"; exit 1; }
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
