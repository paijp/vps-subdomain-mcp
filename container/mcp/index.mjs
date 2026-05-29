/**
 * vps-mcp: MCP server for VPS seminar containers.
 *
 * Implements OAuth 2.1 (PKCE) token issuance and the MCP SSE transport.
 * All state is in-process and ephemeral; tokens are single-use, hashed.
 *
 * Environment variables (set by vps-mcp-init.service):
 *   SUBDOMAIN     – full hostname, e.g. alice.example.com
 *   NOTIFY_EMAIL  – address to notify on token issue
 */

import crypto from "node:crypto";
import { execFile } from "node:child_process";
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
const EXEC_TIMEOUT = 60_000; // ms

// ── Token store ───────────────────────────────────────────────────────────────
// Pending: code_challenge → { challenge_method, expiry }
// Issued:  token_hash → expiry
const pendingCodes = new Map();
const issuedTokens = new Map();

function sha256(str) {
  return crypto.createHash("sha256").update(str).digest("hex");
}

function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) {
    // Constant-time compare anyway to avoid length oracle.
    crypto.timingSafeEqual(ba, Buffer.alloc(ba.length));
    return false;
  }
  return crypto.timingSafeEqual(ba, bb);
}

// ── OAuth 2.1 / PKCE ──────────────────────────────────────────────────────────

const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

// Authorization endpoint — issues an auth code.
app.get("/authorize", (req, res) => {
  const { code_challenge, code_challenge_method, redirect_uri, state } = req.query;
  if (!code_challenge || code_challenge_method !== "S256") {
    return res.status(400).json({ error: "invalid_request" });
  }

  const code = crypto.randomBytes(32).toString("hex");
  pendingCodes.set(code, {
    challenge: code_challenge,
    expiry: Date.now() + 5 * 60 * 1000,
  });

  const url = new URL(redirect_uri);
  url.searchParams.set("code", code);
  if (state) url.searchParams.set("state", state);
  res.redirect(302, url.toString());
});

// Token endpoint — exchanges code+verifier for a bearer token.
// Access is restricted to 160.79.104.0/21 by nginx.
app.post("/token", (req, res) => {
  const { grant_type, code, code_verifier } = req.body;
  if (grant_type !== "authorization_code" || !code || !code_verifier) {
    return res.status(400).json({ error: "invalid_request" });
  }

  const entry = pendingCodes.get(code);
  if (!entry || entry.expiry < Date.now()) {
    pendingCodes.delete(code);
    return res.status(400).json({ error: "invalid_grant" });
  }

  // Verify PKCE: sha256(verifier) == challenge (base64url, no padding)
  const expected = entry.challenge;
  const actual   = crypto.createHash("sha256")
    .update(code_verifier)
    .digest("base64url");

  if (!timingSafeEqual(expected, actual)) {
    return res.status(400).json({ error: "invalid_grant" });
  }
  pendingCodes.delete(code);

  const token = crypto.randomBytes(32).toString("hex");
  issuedTokens.set(sha256(token), Date.now() + 24 * 60 * 60 * 1000);

  // Send notification email asynchronously.
  if (NOTIFY_EMAIL) {
    const body = `A new MCP token was issued for ${SUBDOMAIN} at ${new Date().toISOString()}.`;
    execFileAsync("sendmail", ["-t"], {
      input: [
        `To: ${NOTIFY_EMAIL}`,
        `From: noreply@${SUBDOMAIN}`,
        `Subject: MCP token issued for ${SUBDOMAIN}`,
        "",
        body,
      ].join("\n"),
    }).catch(() => {});
  }

  res.json({ access_token: token, token_type: "Bearer", expires_in: 86400 });
});

// Bearer token validation middleware.
function requireBearer(req, res, next) {
  const auth = req.headers.authorization || "";
  const match = auth.match(/^Bearer\s+(\S+)$/i);
  if (!match) return res.status(401).json({ error: "unauthorized" });

  const hash = sha256(match[1]);
  const expiry = issuedTokens.get(hash);
  if (!expiry || expiry < Date.now()) {
    issuedTokens.delete(hash);
    return res.status(401).json({ error: "unauthorized" });
  }
  next();
}

// ── MCP server ────────────────────────────────────────────────────────────────

const mcp = new McpServer({
  name: "vps-mcp",
  version: "1.0.0",
});

// exec_command tool
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
      return {
        content: [{ type: "text", text: `[error]\n${msg}` }],
        isError: true,
      };
    }
  }
);

// read_file tool
mcp.tool(
  "read_file",
  "Read a file from the VPS filesystem.",
  { path: z.string().describe("Absolute path to the file") },
  async ({ path: filePath }) => {
    try {
      const content = await fs.readFile(filePath, "utf8");
      return { content: [{ type: "text", text: content }] };
    } catch (err) {
      return {
        content: [{ type: "text", text: `[error] ${err.message}` }],
        isError: true,
      };
    }
  }
);

// write_file tool
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
      return {
        content: [{ type: "text", text: `[error] ${err.message}` }],
        isError: true,
      };
    }
  }
);

// ── SSE transport ─────────────────────────────────────────────────────────────

const transports = new Map();

app.get("/sse", requireBearer, async (req, res) => {
  const transport = new SSEServerTransport("/messages", res);
  transports.set(transport.sessionId, transport);
  res.on("close", () => transports.delete(transport.sessionId));
  await mcp.connect(transport);
});

app.post("/messages", requireBearer, async (req, res) => {
  const sessionId = req.query.sessionId;
  const transport = transports.get(sessionId);
  if (!transport) return res.status(404).json({ error: "session not found" });
  await transport.handlePostMessage(req, res);
});

// ── Start ─────────────────────────────────────────────────────────────────────

app.listen(PORT, "127.0.0.1", () => {
  console.log(`vps-mcp listening on 127.0.0.1:${PORT} (subdomain=${SUBDOMAIN})`);
});
