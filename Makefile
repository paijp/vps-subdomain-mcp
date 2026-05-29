IMAGE  ?= vps-mcp:latest
DOMAIN ?=

# Helper functions: parse "subdomain__email" stem
sub_of   = $(word 1,$(subst __, ,$(1)))
email_of = $(word 2,$(subst __, ,$(1)))

.DEFAULT_GOAL := help
.PHONY: help setup image install-binaries list

# ── help ──────────────────────────────────────────────────────────────────────

help:
	@printf "vps-subdomain-mcp — VPS seminar container management\n\n"
	@printf "Setup (run once as root):\n"
	@printf "  make setup                             Build image and install binaries\n"
	@printf "  make image                             Build container image only\n"
	@printf "  make install-binaries                  Build and install Go proxy binaries\n\n"
	@printf "Container management:\n"
	@printf "  make DOMAIN=d alice__alice@ex.com.done  Create VPS for alice (subdomain=alice)\n"
	@printf "  make list                               List running VPS containers\n\n"
	@printf "Variables:\n"
	@printf "  DOMAIN  Base domain, e.g. example.com  (required for container creation)\n"
	@printf "  IMAGE   Container image tag             (default: vps-mcp:latest)\n"

# ── setup ─────────────────────────────────────────────────────────────────────

setup: image install-binaries

image:
	podman build -t $(IMAGE) container/

install-binaries:
	cd proxy && go build -o /usr/local/bin/list-containers  ./cmd/list-containers
	chown root:root /usr/local/bin/list-containers
	chmod 4755      /usr/local/bin/list-containers
	cd proxy && go build -o /usr/local/sbin/vps-proxy       ./cmd/vps-proxy
	cd proxy && go build -o /usr/local/sbin/vps-proxy-http  ./cmd/vps-proxy-http

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
