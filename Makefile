# https://github.com/paijp/vps-subdomain-mcp

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
	@printf "Optional hardening:\n"
	@printf "  make sshsec.done          Disable SSH password auth + install fail2ban\n\n"
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
# 1. Set hostname to <domain>
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
	hostnamectl set-hostname $(_DOMAIN)
	mkdir -p /etc/vps-mcp
	printf 'DOMAIN=%s\nIP=%s\n' "$(_DOMAIN)" "$(_IP)" > /etc/vps-mcp/host.env
	if [ ! -e /swapfile ]; then \
	    fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024; \
	    chmod 600 /swapfile; \
	    mkswap /swapfile; \
	    swapon /swapfile; \
	    grep -qF '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab; \
	fi
	if command -v apt-get >/dev/null 2>&1; then \
	    apt-get update; \
	    apt-get upgrade -y; \
	    apt-get install -y bind9 podman golang-go postfix opendkim opendkim-tools unattended-upgrades; \
	    BIND_ZONE_DIR=/etc/bind/zones; \
	    BIND_CONF=/etc/bind/named.conf.local; \
	elif command -v dnf >/dev/null 2>&1; then \
	    dnf install -y epel-release || dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$$(rpm -E %rhel).noarch.rpm"; \
	    dnf upgrade -y; \
	    dnf install -y bind bind-utils podman golang postfix opendkim opendkim-tools dnf-automatic; \
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
	grep -qF 'v=spf1'          $$_ZF || printf '@   IN TXT "v=spf1 a mx ip4:$(_IP) ~all"\n*   IN TXT "v=spf1 a mx ip4:$(_IP) ~all"\n' >> $$_ZF; \
	grep -qF 'v=DMARC1'        $$_ZF || printf '_dmarc  IN TXT "v=DMARC1; p=none; rua=mailto:postmaster@$(_DOMAIN)"\n'      >> $$_ZF; \
	rndc reload 2>/dev/null || true; \
	sed 's|__DOMAIN__|$(_DOMAIN)|g' host/opendkim/opendkim.conf.tmpl > /etc/opendkim.conf; \
	systemctl enable --now opendkim; \
	postconf -e "inet_interfaces = all"; \
	postconf -e "inet_protocols = ipv4"; \
	postconf -e "myhostname = $(_DOMAIN)"; \
	postconf -e "myorigin = $(_DOMAIN)"; \
	postconf -e "mynetworks = 127.0.0.0/8 10.89.0.0/24"; \
	postconf -e "smtpd_relay_restrictions = permit_mynetworks reject_unauth_destination"; \
	postconf -e "smtpd_milters = inet:127.0.0.1:8891"; \
	postconf -e "non_smtpd_milters = inet:127.0.0.1:8891"; \
	postconf -e "milter_protocol = 6"; \
	postconf -e "milter_default_action = accept"; \
	systemctl enable --now postfix
	podman network create --subnet 10.89.0.0/24 --disable-dns vpsmcp-net 2>/dev/null || true
	systemctl enable --now podman.socket
	systemctl enable podman-restart.service
	if command -v apt-get >/dev/null 2>&1; then \
	    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
	        > /etc/apt/apt.conf.d/20auto-upgrades; \
	    systemctl enable --now unattended-upgrades; \
	elif command -v dnf >/dev/null 2>&1; then \
	    install -m 644 host/dnf/automatic.conf /etc/dnf/automatic.conf; \
	    systemctl enable --now dnf-automatic.timer; \
	fi
	install -m 644 host/systemd/vps-mcp-reboot.service /etc/systemd/system/
	install -m 644 host/systemd/vps-mcp-reboot.timer   /etc/systemd/system/
	systemctl daemon-reload
	systemctl enable --now vps-mcp-reboot.timer
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
	UID443=$$(id -u proxy443); UID80=$$(id -u proxy80); UID_POSTFIX=$$(id -u postfix); \
	sed -e "s|__UID_PROXY443__|$$UID443|g" \
	    -e "s|__UID_PROXY80__|$$UID80|g" \
	    -e "s|__UID_POSTFIX__|$$UID_POSTFIX|g" \
	    host/nftables/vps-mcp.nft.tmpl > /etc/nftables.d/vps-mcp.nft
	grep -qF 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null || \
	    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
	systemctl enable nftables
	nft -f /etc/nftables.d/vps-mcp.nft

# ── sshsec.done — optional SSH hardening ──────────────────────────────────────
# Usage: make sshsec.done
#
# Not called by setupdone — run it separately when you want to lock down SSH.
#   1. Disable password authentication (access is key-based).
#   2. Install + enable fail2ban with the nftables banaction.
#
# Explicit target, so it takes precedence over the %.done pattern rule below.
sshsec.done:
	# Harden SSH: disable password authentication (access is key-based).
	# A container compromise gives the participant root inside their container
	# and reachability to the host's :22, so password login must be off to
	# remove brute-force exposure. The drop-in's 00- prefix wins first-match;
	# validate with sshd -t before reloading so a bad config can't lock us out.
	mkdir -p /etc/ssh/sshd_config.d
	install -m 600 host/ssh/00-vps-mcp-hardening.conf /etc/ssh/sshd_config.d/00-vps-mcp-hardening.conf
	sshd -t && { systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true; }
	# Install fail2ban for SSH brute-force protection.
	# Uses the nftables banaction (firewalld is masked on this host).
	# The 00-vps-mcp.conf drop-in overrides the distro's 00-firewalld.conf.
	if command -v apt-get >/dev/null 2>&1; then \
	    apt-get install -y fail2ban; \
	elif command -v dnf >/dev/null 2>&1; then \
	    dnf install -y fail2ban; \
	fi
	mkdir -p /etc/fail2ban/jail.d
	install -m 644 host/fail2ban/jail.d/00-vps-mcp.conf /etc/fail2ban/jail.d/00-vps-mcp.conf
	systemctl enable --now fail2ban
	@touch $@

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
	    --restart  always \
	    --memory   1g \
	    --pids-limit 200 \
	    --env      SUBDOMAIN=$(_SUBDOMAIN) \
	    --env      MAIL_DOMAIN=$(_SUB).$(DOMAIN) \
	    --env      NOTIFY_EMAIL=$(_EMAIL) \
	    $(IMAGE)
	@echo "Letting the proxy refresh its routing table for the new container..."
	@sleep 10
	@echo "Waiting for the proxy to route the HTTP-01 path to $(_SUBDOMAIN)..."
	@for i in $$(seq 60); do \
	    code=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
	        --resolve $(_SUBDOMAIN):80:$(IP) \
	        http://$(_SUBDOMAIN)/.well-known/acme-challenge/ping 2>/dev/null || true); \
	    if [ "$$code" = "404" ] || [ "$$code" = "200" ]; then \
	        echo "proxy ready (HTTP $$code) after $$i attempt(s)"; break; \
	    fi; \
	    sleep 2; \
	done
	podman exec $(_SUB)-web /usr/local/bin/vps-mcp-init.sh
	@touch $@

# ── list ──────────────────────────────────────────────────────────────────────

list:
	@podman ps --filter "name=-web" --format "table {{.Names}}\t{{.Status}}\t{{.IPAddress}}"
