/**
 * https://github.com/paijp/vps-subdomain-mcp
 *
 * vps-mcp: MCP server for VPS seminar containers.
 *
 * All MCP/OAuth endpoints are namespaced under /mcp/ to avoid clashing with
 * static content; only the RFC 8414 discovery document stays at the
 * well-known root.
 *   - /.well-known/oauth-authorization-server  discovery metadata
 *   - /mcp/authorize  validates redirect_uri host is claude.ai, issues a dummy code
 *   - /mcp/token      validates client_secret against /etc/mcp-server/secret (single-use),
 *                     issues the pre-generated token from /etc/mcp-server/token (single-use),
 *                     stores sha256(token) in /etc/mcp-server/hash for future auth
 *   - /mcp/sse        SSE transport (Bearer auth)
 *   - /mcp/messages   SSE message channel (Bearer auth)
 *
 * Environment variables (set by vps-mcp-init.service):
 *   SUBDOMAIN     – full hostname, e.g. alice.example.com
 *   NOTIFY_EMAIL  – address to notify on token issue
 */

import crypto from "node:crypto";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { z } from "zod";

const execFileAsync = promisify(execFile);

const SUBDOMAIN    = process.env.SUBDOMAIN    || "localhost";
const NOTIFY_EMAIL = process.env.NOTIFY_EMAIL || "";
const PORT         = 3000;
const EXEC_TIMEOUT = 60_000;

const MFN = "/etc/mcp-server";
const SFN = `${MFN}/secret`;
const TFN = `${MFN}/token`;

const sha256 = t => crypto.createHash("sha256").update(t).digest("hex");

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
    token_endpoint_auth_methods_supported: ["client_secret_post"],
    response_types_supported:             ["code"],
    code_challenge_methods_supported:     ["S256"],
  });
});

// ── Authorization endpoint ────────────────────────────────────────────────────
// Validates that redirect_uri belongs to claude.ai, then issues a dummy code.

app.get("/mcp/authorize", (req, res) => {
  const { redirect_uri, state } = req.query;
  try {
    if (new URL(redirect_uri).hostname !== "claude.ai") return res.status(400).send();
  } catch {
    return res.status(400).send();
  }
  const url = new URL(redirect_uri);
  url.searchParams.set("code", "x");
  if (state) url.searchParams.set("state", state);
  res.redirect(302, url.toString());
});

// ── Token endpoint ────────────────────────────────────────────────────────────
// Validates client_secret against /etc/mcp-server/secret (single-use).
// Issues the pre-generated token from /etc/mcp-server/token (single-use).
// Restricted to Anthropic IPs (160.79.104.0/21) by nginx.

app.post("/mcp/token", (req, res) => {
  const { client_secret } = req.body;

  let secret;
  try { secret = readFileSync(SFN, "utf8").trim(); } catch {
    return res.status(403).send();
  }
  if (client_secret !== secret) return res.status(403).send();

  // client_id is the "secret marker": it identifies the session in the
  // notification email but is never stored server-side.
  const cid = +req.body.client_id;
  if (!cid) return res.status(403).send();

  try { unlinkSync(SFN); } catch {}

  let token;
  try { token = readFileSync(TFN, "utf8").trim(); } catch {
    return res.status(403).send();
  }
  writeFileSync(`${MFN}/hash`, sha256(token), { mode: 0o600 });
  try { unlinkSync(TFN); } catch {}

  if (NOTIFY_EMAIL) {
    const m = spawn("/usr/bin/s-nail", [
      "-s", `MCP token issued client_id=${cid}`,
      "-r", `noreply@${SUBDOMAIN}`,
      NOTIFY_EMAIL,
    ]);
    m.stdin.end("done");
  }

  setTimeout(() => res.json({ access_token: token, token_type: "Bearer" }), 5000);
});

// ── Bearer auth middleware ────────────────────────────────────────────────────

function auth(req, res, next) {
  const t = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  let h;
  try { h = readFileSync(`${MFN}/hash`, "utf8").trim(); } catch {
    return res.status(401).send();
  }
  const hb = Buffer.from(h);
  const tb = Buffer.from(sha256(t));
  if (hb.length !== tb.length || !crypto.timingSafeEqual(hb, tb))
    return res.status(401).send();
  next();
}

// ── MCP server ────────────────────────────────────────────────────────────────

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

// ── SSE transport ─────────────────────────────────────────────────────────────

const transports = new Map();

app.get("/mcp/sse", auth, async (req, res) => {
  const transport = new SSEServerTransport("/mcp/messages", res);
  transports.set(transport.sessionId, transport);
  req.on("close", () => {
    transports.delete(transport.sessionId);
    transport.close();
  });
  await mcp.connect(transport);
});

app.post("/mcp/messages", auth, async (req, res) => {
  const transport = transports.get(req.query.sessionId);
  if (!transport) return res.status(404).json({ error: "session not found" });
  await transport.handlePostMessage(req, res, req.body);
});

// ── Start ─────────────────────────────────────────────────────────────────────

app.listen(PORT, "127.0.0.1", () => {
  console.log(`vps-mcp listening on 127.0.0.1:${PORT} (subdomain=${SUBDOMAIN})`);
});
