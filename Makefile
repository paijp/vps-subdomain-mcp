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
	@printf "      Hostname, BIND wildcard DNS, vpsmcp-net, proxy sockets, nftables.\n"
	@printf "      After this, DOMAIN is read from /etc/vps-mcp/host.env automatically.\n\n"
	@printf "Rebuild components individually:\n"
	@printf "  make image                Build container image\n"
	@printf "  make install-binaries     Build and install Go proxy binaries\n"
	@printf "  make install-services     (Re)install socket units and nftables\n\n"
	@printf "Container management:\n"
	@printf "  make alice__alice@ex.com.done      Create VPS for alice\n"
	@printf "  make default__admin@ex.com.done    Create default container (serves parent domain)\n"
	@printf "  make list                          List running VPS containers\n\n"
	@printf "Variables:\n"
	@printf "  IMAGE   Container image tag (default: vps-mcp:latest)\n"

# ── host setup ────────────────────────────────────────────────────────────────
# Usage: make 203.0.113.1__example.com.setupdone
#
# 1. Set hostname to ns1.<domain>
# 2. Write /etc/vps-mcp/host.env  (DOMAIN, IP)
# 3. Install BIND9, configure wildcard zone with secondary NS, reload
# 4. Create vpsmcp-net Podman network (10.89.0.0/24, DNS disabled)
# 5. Build container image
# 6. Install Go proxy binaries
# 7. Install proxy socket units + nftables (with proxy user UID substitution)

%.setupdone:
	$(eval _IP     := $(call ip_of,$*))
	$(eval _DOMAIN := $(call domain_of,$*))
	@test -n "$(_IP)"     || { echo "Error: format is  IP__DOMAIN.setupdone  e.g. 203.0.113.1__example.com.setupdone"; exit 1; }
	@test -n "$(_DOMAIN)" || { echo "Error: format is  IP__DOMAIN.setupdone  e.g. 203.0.113.1__example.com.setupdone"; exit 1; }
	hostnamectl set-hostname ns1.$(_DOMAIN)
	mkdir -p /etc/vps-mcp
	printf 'DOMAIN=%s\nIP=%s\n' "$(_DOMAIN)" "$(_IP)" > /etc/vps-mcp/host.env
	if command -v apt-get >/dev/null 2>&1; then \
	    apt-get install -y bind9 podman golang-go postfix opendkim opendkim-tools; \
	    BIND_ZONE_DIR=/etc/bind/zones; \
	    BIND_CONF=/etc/bind/named.conf.local; \
	elif command -v dnf >/dev/null 2>&1; then \
	    dnf install -y epel-release || dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$$(rpm -E %rhel).noarch.rpm"; \
	    dnf install -y bind bind-utils podman golang postfix opendkim; \
	    BIND_ZONE_DIR=/var/named; \
	    mkdir -p /etc/named; \
	    BIND_CONF=/etc/named/named.conf.local; \
	    install -m 644 host/bind/named.conf.tmpl /etc/named.conf; \
	else echo "Error: no supported package manager (apt-get or dnf)"; exit 1; fi; \
	mkdir -p $$BIND_ZONE_DIR; \
	sed -e 's|__IP__|$(_IP)|g' \
	    -e 's|__DOMAIN__|$(_DOMAIN)|g' \
	    -e "s|__SERIAL__|$$(date +%Y%m%d01)|g" \
	    host/bind/zone.tmpl > $$BIND_ZONE_DIR/$(_DOMAIN).zone; \
	sed -e 's|__DOMAIN__|$(_DOMAIN)|g' \
	    -e "s|__BIND_ZONE_DIR__|$$BIND_ZONE_DIR|g" \
	    host/bind/named.conf.local.tmpl > $$BIND_CONF; \
	chgrp named $$BIND_ZONE_DIR/$(_DOMAIN).zone $$BIND_CONF 2>/dev/null || true; \
	chmod 640 $$BIND_ZONE_DIR/$(_DOMAIN).zone $$BIND_CONF 2>/dev/null || true
	systemctl enable --now named
	rndc reload 2>/dev/null || true
	rndc notify 2>/dev/null || true
	mkdir -p /etc/opendkim/keys/$(_DOMAIN); \
	if [ ! -f /etc/opendkim/keys/$(_DOMAIN)/mail.private ]; then \
	    opendkim-genkey -b 2048 -D /etc/opendkim/keys/$(_DOMAIN)/ -d $(_DOMAIN) -s mail; \
	    chown -R opendkim:opendkim /etc/opendkim/keys; \
	fi; \
	if command -v apt-get >/dev/null 2>&1; then _ZF=/etc/bind/zones/$(_DOMAIN).zone; else _ZF=/var/named/$(_DOMAIN).zone; fi; \
	grep -qF 'mail._domainkey' $$_ZF || cat /etc/opendkim/keys/$(_DOMAIN)/mail.txt >> $$_ZF; \
	grep -qF 'v=spf1'          $$_ZF || printf '@   IN TXT "v=spf1 a mx ip4:$(_IP) ~all"\n'                                  >> $$_ZF; \
	grep -qF 'v=DMARC1'        $$_ZF || printf '_dmarc  IN TXT "v=DMARC1; p=none; rua=mailto:postmaster@$(_DOMAIN)"\n'      >> $$_ZF; \
	rndc reload 2>/dev/null || true; \
	sed 's|__DOMAIN__|$(_DOMAIN)|g' host/opendkim/opendkim.conf.tmpl > /etc/opendkim.conf; \
	systemctl enable --now opendkim; \
	postconf -e "inet_interfaces = 10.89.0.1, loopback-only"; \
	postconf -e "mynetworks = 127.0.0.0/8 10.89.0.0/24"; \
	postconf -e "smtpd_milters = inet:127.0.0.1:8891"; \
	postconf -e "non_smtpd_milters = inet:127.0.0.1:8891"; \
	postconf -e "milter_protocol = 6"; \
	postconf -e "milter_default_action = accept"; \
	systemctl enable --now postfix
	podman network create --subnet 10.89.0.0/24 --disable-dns vpsmcp-net 2>/dev/null || true
	systemctl enable --now podman.socket
	$(MAKE) image
	$(MAKE) install-binaries
	$(MAKE) install-services DOMAIN=$(_DOMAIN) IP=$(_IP)
	@touch $@

# ── image ─────────────────────────────────────────────────────────────────────

image:
	podman build -t $(IMAGE) container/

# ── install-binaries ──────────────────────────────────────────────────────────

install-binaries:
	cd proxy && go build -o /usr/local/sbin/list-containers ./cmd/list-containers
	chown root:root /usr/local/sbin/list-containers
	chmod 0755      /usr/local/sbin/list-containers
	cd proxy && go build -o /usr/local/sbin/vps-proxy       ./cmd/vps-proxy
	cd proxy && go build -o /usr/local/sbin/vps-proxy-http  ./cmd/vps-proxy-http

# ── install-services ──────────────────────────────────────────────────────────

install-services:
	@test -n "$(DOMAIN)" || \
	    { echo "Error: DOMAIN is required.  Example: make install-services DOMAIN=example.com"; exit 1; }
	mkdir -p /etc/vps-mcp
	printf 'DOMAIN=%s\nIP=%s\n' "$(DOMAIN)" "$(IP)" > /etc/vps-mcp/host.env
	useradd -r -s /sbin/nologin proxy443 2>/dev/null || true
	useradd -r -s /sbin/nologin proxy80  2>/dev/null || true
	install -m 644 host/systemd/vps-proxy443.socket  /etc/systemd/system/
	install -m 644 host/systemd/vps-proxy443.service /etc/systemd/system/
	install -m 644 host/systemd/vps-proxy80.socket   /etc/systemd/system/
	install -m 644 host/systemd/vps-proxy80.service  /etc/systemd/system/
	systemctl daemon-reload
	systemctl enable --now vps-proxy443.socket vps-proxy80.socket
	mkdir -p /etc/nftables.d; \
	UID443=$$(id -u proxy443); UID80=$$(id -u proxy80); \
	sed -e "s|__UID_PROXY443__|$$UID443|g" \
	    -e "s|__UID_PROXY80__|$$UID80|g" \
	    host/nftables/vps-mcp.nft.tmpl > /etc/nftables.d/vps-mcp.nft
	grep -qF 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null || \
	    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
	systemctl enable nftables
	nft -f /etc/nftables.d/vps-mcp.nft

# ── container creation ────────────────────────────────────────────────────────
# Usage: make alice__alice@gmail.com.done
#        make default__admin@gmail.com.done   (serves parent domain, not default.DOMAIN)
# DOMAIN is read automatically from /etc/vps-mcp/host.env after setupdone.

%.done:
	$(eval _SUB      := $(call sub_of,$*))
	$(eval _EMAIL    := $(call email_of,$*))
	$(eval _SUBDOMAIN := $(if $(filter default,$(_SUB)),$(DOMAIN),$(_SUB).$(DOMAIN)))
	@test -n "$(DOMAIN)" || \
	    { echo "Error: DOMAIN not set.  Run make IP__DOMAIN.setupdone first."; exit 1; }
	podman run -d \
	    --name     $(_SUB)-web \
	    --hostname $(_SUBDOMAIN) \
	    --network  vpsmcp-net \
	    --systemd  always \
	    --memory   1g \
	    --pids-limit 200 \
	    --env      SUBDOMAIN=$(_SUBDOMAIN) \
	    --env      NOTIFY_EMAIL=$(_EMAIL) \
	    $(IMAGE)
	podman exec $(_SUB)-web /usr/local/bin/vps-mcp-init.sh
	@touch $@

# ── list ──────────────────────────────────────────────────────────────────────

list:
	@podman ps --filter "name=-web" --format "table {{.Names}}\t{{.Status}}\t{{.IPAddress}}"
