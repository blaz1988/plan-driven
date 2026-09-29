// Runs one read-only Cursor agent turn for plan_driven and prints {"text", "usage"} as JSON.
// Input on stdin: {"model", "prompt", "cwd", "sdkPaths"}. The key comes from CURSOR_API_KEY.
// `--check` only resolves the SDK, for `plan-driven doctor`.
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import os from "node:os";
import path from "node:path";

const READ_ONLY_TOOLS = ["read", "grep", "glob", "ls"];

function globalRoot() {
  try {
    return execSync("npm root -g", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
}

function loadSdk(dirs) {
  const candidates = [...dirs, path.join(os.homedir(), ".plan_driven", "node"), globalRoot()].filter(Boolean);
  for (const dir of candidates) {
    try {
      return createRequire(path.join(dir, "package.json"))("@cursor/sdk");
    } catch {
      // try the next place
    }
  }
  throw new Error(
    "@cursor/sdk not found. Install it with `npm install --prefix ~/.plan_driven/node @cursor/sdk` (Node 22.13+)."
  );
}

async function readStdin() {
  let data = "";
  for await (const chunk of process.stdin) data += chunk;
  return JSON.parse(data);
}

function fail(message) {
  process.stdout.write(JSON.stringify({ error: message }));
  process.exit(1);
}

try {
  if (process.argv.includes("--check")) {
    const dirs = process.argv.slice(3);
    loadSdk(dirs);
    process.stdout.write(JSON.stringify({ ok: true, node: process.version }));
    process.exit(0);
  }

  const input = await readStdin();
  const { Agent } = loadSdk([input.cwd, ...(input.sdkPaths || [])]);
  const result = await Agent.prompt(input.prompt, {
    apiKey: process.env.CURSOR_API_KEY,
    model: { id: input.model },
    tools: READ_ONLY_TOOLS,
    local: { cwd: input.cwd },
  });
  if (result.status !== "finished") fail(result.error?.message || `agent run ${result.status}`);

  const usage = result.usage || {};
  process.stdout.write(JSON.stringify({
    text: result.result || "",
    usage: { input: usage.inputTokens, output: usage.outputTokens },
  }));
  process.exit(0);
} catch (error) {
  fail(error?.message || String(error));
}
