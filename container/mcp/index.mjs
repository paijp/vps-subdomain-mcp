/**
 * https://github.com/paijp/vps-subdomain-mcp
 *
 * vps-mcp: MCP server for VPS seminar containers.
 *
 * Authentication uses real GitHub OAuth login. A dedicated "oauth" container
 * (oauth.<DOMAIN>) holds the GitHub OAuth App credentials and is the single
 * registered redirect target; each seminar container only knows OAUTH_BASE.
 *
 * Endpoints on a seminar container (authorization server seen by Claude.ai):
 *   - /.well-known/oauth-authorization-server  discovery metadata (PKCE S256, public client)
 *   - /mcp/authorize  validates redirect_uri host is claude.ai, bounces the
 *                     browser to the oauth container's /mcp/start
 *   - /mcp/token      receives { code (ignored), code_verifier }, asks the oauth
 *                     container to resolve the verified GitHub email, and issues
 *                     a Bearer only if that email matches NOTIFY_EMAIL
 *   - /mcp/sse        SSE transport (Bearer auth)
 *   - /mcp/messages   SSE message channel (Bearer auth)
 *
 * Endpoints on the oauth container (enabled when GITHUB_CLIENT_ID is set):
 *   - /mcp/start      validates claude_redirect host, redirects to GitHub authorize
 *   - /mcp/callback   exchanges the GitHub code (single-use, consumed here) for the
 *                     verified primary email, mints an authorization code bound to
 *                     { challenge, email }, then redirects the browser back to
 *                     claude.ai with that code
 *   - /mcp/resolve    given { code, code_verifier }, returns the email if the code
 *                     exists and sha256(verifier) == its stored challenge
 *
 * Environment variables (set by vps-mcp-init.service):
 *   SUBDOMAIN          – full hostname, e.g. alice.example.com
 *   NOTIFY_EMAIL       – the organizer's email; only this GitHub account is allowed
 *   OAUTH_BASE         – e.g. https://oauth.example.com (all containers)
 *   GITHUB_CLIENT_ID   – GitHub OAuth App client id    (oauth container only)
 *   GITHUB_CLIENT_SECRET – GitHub OAuth App secret      (oauth container only)
 */

import crypto from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { z } from "zod";

const execFileAsync = promisify(execFile);

const SUBDOMAIN     = process.env.SUBDOMAIN     || "localhost";
const MAIL_DOMAIN   = process.env.MAIL_DOMAIN   || SUBDOMAIN;
const NOTIFY_EMAIL  = process.env.NOTIFY_EMAIL  || "";
const OAUTH_BASE    = (process.env.OAUTH_BASE   || "").replace(/\/+$/, "");
const GH_CLIENT_ID     = process.env.GITHUB_CLIENT_ID     || "";
const GH_CLIENT_SECRET = process.env.GITHUB_CLIENT_SECRET || "";
const PORT          = 3000;
const EXEC_TIMEOUT  = 60_000;

// The oauth role is active when GitHub credentials are present.
const IS_OAUTH = Boolean(GH_CLIENT_ID && GH_CLIENT_SECRET);

const MFN = "/etc/mcp-server";

const sha256hex = t => crypto.createHash("sha256").update(t).digest("hex");
// PKCE S256: BASE64URL(SHA256(code_verifier)).
const sha256b64url = t => crypto.createHash("sha256").update(t).digest("base64url");

const encodeState = obj => Buffer.from(JSON.stringify(obj)).toString("base64url");
const decodeState = s => JSON.parse(Buffer.from(String(s), "base64url").toString("utf8"));

const isClaudeRedirect = u => {
  try { return new URL(u).hostname === "claude.ai"; } catch { return false; }
};

const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

// ── OAuth discovery ───────────────────────────────────────────────────────────

app.get("/.well-known/oauth-authorization-server", (req, res) => {
  const host  = req.headers["x-forwarded-host"] || req.headers.host || req.hostname;
  const proto = req.headers["x-forwarded-proto"] || req.protocol;
  const base  = `${proto}://${host}`;
  res.json({
    issuer:                                base,
    authorization_endpoint:               `${base}/mcp/authorize`,
    token_endpoint:                        `${base}/mcp/token`,
    registration_endpoint:                `${base}/mcp/register`,
    token_endpoint_auth_methods_supported: ["none"],
    response_types_supported:             ["code"],
    code_challenge_methods_supported:     ["S256"],
  });
});

// ── Dynamic client registration (RFC 7591) ────────────────────────────────────
// Claude.ai auto-registers a client before starting the flow; without this it
// reports "does not support automatic client registration". We are a public
// client and never validate client_id (PKCE + GitHub email match are the gate),
// so we just mint an id and echo the requested metadata back.

app.post("/mcp/register", (req, res) => {
  const meta = req.body || {};
  res.status(201).json({
    client_id:            crypto.randomBytes(16).toString("hex"),
    client_id_issued_at:  Math.floor(Date.now() / 1000),
    redirect_uris:        Array.isArray(meta.redirect_uris) ? meta.redirect_uris : [],
    token_endpoint_auth_method: "none",
    grant_types:          meta.grant_types   || ["authorization_code"],
    response_types:       meta.response_types || ["code"],
    ...(meta.client_name ? { client_name: meta.client_name } : {}),
    ...(meta.scope       ? { scope:       meta.scope }       : {}),
  });
});

// ── Authorization endpoint (seminar container) ────────────────────────────────
// Validates that redirect_uri belongs to claude.ai and PKCE is S256, then bounces
// the browser to the oauth container's /mcp/start. The oauth container owns all
// GitHub knowledge (client_id, redirect_uri, scope).

app.get("/mcp/authorize", (req, res) => {
  const { redirect_uri, state, code_challenge, code_challenge_method } = req.query;
  if (!isClaudeRedirect(redirect_uri))        return res.status(400).send();
  if (code_challenge_method !== "S256")        return res.status(400).send();
  if (!code_challenge)                         return res.status(400).send();
  if (!OAUTH_BASE)                             return res.status(500).send();

  const url = new URL(`${OAUTH_BASE}/mcp/start`);
  url.searchParams.set("claude_redirect", redirect_uri);
  if (state) url.searchParams.set("claude_state", state);
  url.searchParams.set("challenge", code_challenge);
  res.redirect(302, url.toString());
});

// ── Token endpoint (seminar container) ────────────────────────────────────────
// Asks the oauth container to resolve the verified GitHub email for this PKCE
// verifier, then issues a Bearer only if it matches NOTIFY_EMAIL. No need to
// validate the verifier locally: an invalid one simply fails to resolve.

app.post("/mcp/token", async (req, res) => {
  const { code, code_verifier } = req.body;
  if (!OAUTH_BASE) return res.status(500).send();

  let email;
  try {
    const r = await fetch(`${OAUTH_BASE}/mcp/resolve`, {
      method:  "POST",
      headers: { "content-type": "application/json" },
      body:    JSON.stringify({ code, code_verifier }),
    });
    if (!r.ok) return res.status(403).send();
    ({ email } = await r.json());
  } catch {
    return res.status(502).send();
  }

  if (!email || email.toLowerCase() !== NOTIFY_EMAIL.toLowerCase())
    return res.status(403).send();

  const token = crypto.randomBytes(32).toString("hex");
  writeFileSync(`${MFN}/hash`, sha256hex(token), { mode: 0o600 });

  if (NOTIFY_EMAIL) {
    const m = spawn("/usr/sbin/sendmail", ["-f", `noreply@${MAIL_DOMAIN}`, NOTIFY_EMAIL]);
    m.stdin.end(
      `From: noreply@${MAIL_DOMAIN}\r\nTo: ${NOTIFY_EMAIL}\r\nSubject: MCP token issued\r\n\r\n` +
      `A Bearer token was issued after GitHub login as ${email}.\r\n`
    );
  }

  res.json({ access_token: token, token_type: "Bearer" });
});

// ── OAuth-container endpoints (GitHub login broker) ───────────────────────────
// pending: auth_code -> { challenge, email, createdAt }. In-memory; a login
// completes in one short browser session. Entries are single-use and swept
// after PENDING_TTL.

const pending = new Map();
const PENDING_TTL = 10 * 60_000;

if (IS_OAUTH) {
  setInterval(() => {
    const now = Date.now();
    for (const [k, v] of pending) if (now - v.createdAt > PENDING_TTL) pending.delete(k);
  }, 60_000).unref();

  const CALLBACK_URI = `${OAUTH_BASE}/mcp/callback`;

  // Bounce to GitHub. claude_redirect is re-validated here because /mcp/start is
  // publicly reachable (a user could hit it without going through a seminar
  // container), which would otherwise allow open redirects via the callback.
  app.get("/mcp/start", (req, res) => {
    const { claude_redirect, claude_state, challenge } = req.query;
    if (!isClaudeRedirect(claude_redirect)) return res.status(400).send();
    if (!challenge)                         return res.status(400).send();

    const state = encodeState({ claude_redirect, claude_state: claude_state || "", challenge });
    const url = new URL("https://github.com/login/oauth/authorize");
    url.searchParams.set("client_id", GH_CLIENT_ID);
    url.searchParams.set("redirect_uri", CALLBACK_URI);
    url.searchParams.set("scope", "user:email");
    url.searchParams.set("state", state);
    res.redirect(302, url.toString());
  });

  // GitHub redirects the browser here with a single-use code. We exchange it
  // immediately (so the code is dead by the time it sits in browser history),
  // fetch the verified primary email, stash it under the PKCE challenge, then
  // send the browser back to claude.ai with a dummy code.
  app.get("/mcp/callback", async (req, res) => {
    const { code, state } = req.query;
    let st;
    try { st = decodeState(state); } catch { return res.status(400).send(); }
    if (!isClaudeRedirect(st.claude_redirect)) return res.status(400).send();
    if (!st.challenge || !code)                return res.status(400).send();

    try {
      const tokRes = await fetch("https://github.com/login/oauth/access_token", {
        method:  "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body:    JSON.stringify({
          client_id:     GH_CLIENT_ID,
          client_secret: GH_CLIENT_SECRET,
          code,
          redirect_uri:  CALLBACK_URI,
        }),
      });
      const tok = await tokRes.json();
      if (!tok.access_token) return res.status(403).send();

      const emailRes = await fetch("https://api.github.com/user/emails", {
        headers: {
          authorization: `Bearer ${tok.access_token}`,
          accept:        "application/vnd.github+json",
          "user-agent":  "vps-mcp",
        },
      });
      const emails = await emailRes.json();
      const primary = Array.isArray(emails)
        ? emails.find(e => e.primary && e.verified)
        : null;
      if (!primary) return res.status(403).send();

      // Issue our own authorization code, bound to the PKCE challenge and email.
      // It is delivered only to claude.ai (redirect_uri is host-locked above), so
      // an attacker who merely holds a verifier cannot obtain it and thus cannot
      // resolve — this is what stops login-CSRF / authorization-code fixation.
      const authCode = crypto.randomBytes(32).toString("hex");
      pending.set(authCode, { challenge: st.challenge, email: primary.email, createdAt: Date.now() });

      const url = new URL(st.claude_redirect);
      url.searchParams.set("code", authCode);
      if (st.claude_state) url.searchParams.set("state", st.claude_state);
      res.set("Referrer-Policy", "no-referrer");
      return res.redirect(302, url.toString());
    } catch {
      return res.status(502).send();
    }
  });

  // Resolve the verified email for an authorization code. The caller must present
  // both the code (delivered only to claude.ai) and the matching PKCE verifier.
  // Single-use.
  app.post("/mcp/resolve", (req, res) => {
    const { code, code_verifier } = req.body;
    if (!code || !code_verifier) return res.status(400).send();
    const entry = pending.get(code);
    if (!entry) return res.status(404).send();
    const a = Buffer.from(sha256b64url(code_verifier));
    const b = Buffer.from(entry.challenge);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b))
      return res.status(403).send();
    pending.delete(code);
    res.json({ email: entry.email });
  });
}

// ── Bearer auth middleware ────────────────────────────────────────────────────

function auth(req, res, next) {
  const t = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  let h;
  try { h = readFileSync(`${MFN}/hash`, "utf8").trim(); } catch {
    return res.status(401).send();
  }
  const hb = Buffer.from(h);
  const tb = Buffer.from(sha256hex(t));
  if (hb.length !== tb.length || !crypto.timingSafeEqual(hb, tb))
    return res.status(401).send();
  next();
}

// ── MCP server ────────────────────────────────────────────────────────────────
// A fresh McpServer is built per SSE connection: a single Protocol instance can
// only be bound to one transport at a time, so sharing it across reconnects
// throws "Already connected to a transport" and crashes the process.

function createMcpServer() {
  const mcp = new McpServer({ name: "vps-mcp", version: "1.0.0" });

  mcp.tool(
    "exec_command",
    "Execute a shell command on the VPS. Returns stdout and stderr.",
    { command: z.string().describe("Shell command to run") },
    async ({ command }) => {
      try {
        const { stdout, stderr } = await execFileAsync(
          "/bin/bash", ["-c", command],
          { timeout: EXEC_TIMEOUT, maxBuffer: 10 * 1024 * 1024 }
        );
        return {
          content: [{ type: "text", text: stdout + (stderr ? `\n[stderr]\n${stderr}` : "") }],
        };
      } catch (err) {
        const msg = err.stdout
          ? err.stdout + (err.stderr ? `\n[stderr]\n${err.stderr}` : "")
          : err.message;
        return { content: [{ type: "text", text: `[error]\n${msg}` }], isError: true };
      }
    }
  );

  mcp.tool(
    "read_file",
    "Read a file from the VPS filesystem.",
    { path: z.string().describe("Absolute path to the file") },
    async ({ path: filePath }) => {
      try {
        const content = await fs.readFile(filePath, "utf8");
        return { content: [{ type: "text", text: content }] };
      } catch (err) {
        return { content: [{ type: "text", text: `[error] ${err.message}` }], isError: true };
      }
    }
  );

  mcp.tool(
    "write_file",
    "Write content to a file on the VPS filesystem.",
    {
      path:    z.string().describe("Absolute path to the file"),
      content: z.string().describe("Content to write"),
    },
    async ({ path: filePath, content }) => {
      try {
        await fs.mkdir(path.dirname(filePath), { recursive: true });
        await fs.writeFile(filePath, content, "utf8");
        return { content: [{ type: "text", text: "ok" }] };
      } catch (err) {
        return { content: [{ type: "text", text: `[error] ${err.message}` }], isError: true };
      }
    }
  );

  mcp.tool(
    "nginx_reload",
    "Reload the nginx configuration. Always use this instead of running " +
      "'nginx -s reload' / 'systemctl reload nginx' via exec_command: the MCP " +
      "SSE connection is proxied through nginx, so a synchronous reload can " +
      "interrupt it before the tool result is delivered and stall the client " +
      "until timeout. This validates the config, returns immediately, then " +
      "defers the actual reload so the result is flushed first.",
    {},
    async () => {
      // Validate the config before touching the running server. nginx -t
      // writes its report to stderr on both success and failure.
      let report;
      try {
        const { stderr } = await execFileAsync("/usr/sbin/nginx", ["-t"]);
        report = stderr;
      } catch (err) {
        return {
          content: [{ type: "text", text: `[error] nginx config test failed:\n${err.stderr || err.message}` }],
          isError: true,
        };
      }
      // Defer the reload so this response reaches the client first; reloading
      // can briefly disrupt the SSE connection that carries tool results.
      setTimeout(() => {
        execFile("/usr/bin/systemctl", ["reload", "nginx"], (err, _out, stderr) => {
          if (err) console.error(`nginx_reload: reload failed: ${stderr || err.message}`);
        });
      }, 1000);
      return { content: [{ type: "text", text: `nginx config valid; reload scheduled\n${report}` }] };
    }
  );

  return mcp;
}

// ── SSE transport ─────────────────────────────────────────────────────────────

const transports = new Map();

app.get("/mcp/sse", auth, async (req, res) => {
  const transport = new SSEServerTransport("/mcp/messages", res);
  transports.set(transport.sessionId, transport);
  req.on("close", () => {
    transports.delete(transport.sessionId);
    transport.close();
  });
  const mcp = createMcpServer();
  await mcp.connect(transport);
});

app.post("/mcp/messages", auth, async (req, res) => {
  const transport = transports.get(req.query.sessionId);
  if (!transport) return res.status(404).json({ error: "session not found" });
  await transport.handlePostMessage(req, res, req.body);
});

// ── Start ─────────────────────────────────────────────────────────────────────

app.listen(PORT, "127.0.0.1", () => {
  console.log(`vps-mcp listening on 127.0.0.1:${PORT} (subdomain=${SUBDOMAIN}, oauth=${IS_OAUTH})`);
});
