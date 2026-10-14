import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const MODEL = "openai/gpt-5.5";
const SKIP_TMUX = !tmuxAvailable();

type Fixture = { root: string; home: string; workspace: string };

function createFixture(label: string): Fixture {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-threads-${label}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  return { root, home, workspace: realpathSync(workspace) };
}

function startGateway() {
  return startDynamicFakeGateway(
    raw => fakeGatewayFinalText(String(raw).includes("write hello") ? "THREAD_ANSWER_OK" : "MAIN_ANSWER_OK"),
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
}

function env(fixture: Fixture, gateway: { baseUrl: string; chatUrl: string }, overrides: Record<string, string> = {}) {
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "synthetic-threads",
    FX_DISABLE_KEYCHAIN: "1",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_SKIP_ONBOARDING: "1",
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "full-access",
    FX_MAX_AGENT_STEPS: "2",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    ...overrides,
  };
}

async function launch(
  fixture: Fixture,
  gateway: ReturnType<typeof startGateway>,
  overrides: Record<string, string> = {},
) {
  const tui = await TmuxSession.create({
    cmd: JSON.stringify(FX_BIN),
    cwd: fixture.workspace,
    isolated: true,
    remainOnExit: true,
    env: env(fixture, gateway, overrides),
  });
  await tui.waitForStableComposer(15000);
  // Threads hang off a saved session, which a first turn creates.
  await tui.sendText("hello");
  await tui.waitForText("MAIN_ANSWER_OK", 20000);
  await tui.waitForStableComposer(15000);
  return tui;
}

test.skipIf(SKIP_TMUX)("/thread new runs a named thread beside the session and /thread watch shows its output", async () => {
  const fixture = createFixture("run");
  const gateway = startGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);

    await tui.sendText("/thread list");
    await tui.waitForText("alpha", 10000);

    // The thread runs on its own; poll its feed until the answer lands.
    let seen = false;
    for (let attempt = 0; attempt < 20 && !seen; attempt++) {
      await tui.sendText("/thread watch alpha");
      try {
        await tui.waitForText("THREAD_ANSWER_OK", 2000);
        seen = true;
      } catch {
        // Not there yet.
      }
    }
    expect(seen).toBe(true);

    const threadsDir = join(fixture.home, ".fx", "threads");
    expect(existsSync(threadsDir)).toBe(true);
    const files = readdirSync(threadsDir).filter(f => f.endsWith(".json"));
    expect(files.length).toBe(1);
    const registry = JSON.parse(readFileSync(join(threadsDir, files[0]), "utf8"));
    expect(registry.threads.map((t: { name: string }) => t.name)).toEqual(["alpha"]);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 90_000);

test.skipIf(SKIP_TMUX)("/thread rejects bad names, duplicates, and unknown threads", async () => {
  const fixture = createFixture("errors");
  const gateway = startGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new Bad_Name do it");
    await tui.waitForText("Thread names use lowercase", 10000);

    await tui.sendText("/thread new main do it");
    await tui.waitForText("cannot be a thread name", 10000);

    await tui.sendText("/thread send ghost hello");
    await tui.waitForText("No thread named ghost", 10000);

    await tui.sendText("/thread new beta write hello");
    await tui.waitForText("Started thread beta", 20000);
    await tui.sendText("/thread new beta write hello");
    await tui.waitForText("already exists", 10000);

    await tui.sendText("/thread nonsense");
    await tui.waitForText("usage: /thread", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 90_000);

test.skipIf(SKIP_TMUX)("/thread switch moves into an idle thread, talks there, and returns to main", async () => {
  const fixture = createFixture("switch");
  const gateway = startGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);

    // Switching is refused while the thread works, so wait until it is idle.
    let idle = false;
    for (let attempt = 0; attempt < 30 && !idle; attempt++) {
      await tui.sendText("/thread list");
      try {
        await tui.waitForText("alpha  idle", 1500);
        idle = true;
      } catch {
        // Still running.
      }
    }
    expect(idle).toBe(true);

    await tui.sendText("/thread switch alpha");
    await tui.waitForText("Switched to alpha", 20000);
    // The thread's own history comes back with it.
    await tui.waitForText("THREAD_ANSWER_OK", 10000);

    await tui.sendText("/thread list");
    await tui.waitForText("> alpha", 10000);

    // New work and sibling control wait until we are back in main.
    await tui.sendText("/thread new beta write hello");
    await tui.waitForText("You are in thread alpha", 10000);

    await tui.sendText("/thread switch main");
    await tui.waitForText("Switched to main", 20000);
    await tui.waitForText("MAIN_ANSWER_OK", 10000);
    await tui.sendText("/thread list");
    await tui.waitForText("> main", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("/thread switch is refused while a thread is still running", async () => {
  const fixture = createFixture("switch-busy");
  const gateway = startDynamicFakeGateway(
    async raw => {
      if (!String(raw).includes("write hello")) return fakeGatewayFinalText("MAIN_ANSWER_OK");
      await Bun.sleep(8000);
      return fakeGatewayFinalText("SLOW_THREAD_DONE");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new slow write hello");
    await tui.waitForText("Started thread slow", 20000);
    await tui.sendText("/thread switch slow");
    await tui.waitForText("still running", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 90_000);

// A gateway for the model-facing thread tools. The root asks for one tool call
// when its prompt matches, and answers once the tool result is in its history.
// Request bodies are kept so a test can read what the tool returned.
function startToolGateway(rootPrompt: string, tool: string, input: object, resultMarker: string) {
  const bodies: string[] = [];
  const gateway = startDynamicFakeGateway(
    raw => {
      const body = String(raw);
      bodies.push(body);
      if (body.includes(resultMarker)) return fakeGatewayFinalText("TOOL_ROUND_DONE");
      if (body.includes(rootPrompt)) return fakeGatewayToolCall("thread-call-1", tool, input);
      if (body.includes("say bye now")) return fakeGatewayFinalText("THREAD_BYE_OK");
      if (body.includes("write hello")) return fakeGatewayFinalText("THREAD_ANSWER_OK");
      return fakeGatewayFinalText("MAIN_ANSWER_OK");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  return { gateway, bodies };
}

async function waitForThreadIdle(tui: TmuxSession, name: string) {
  for (let attempt = 0; attempt < 30; attempt++) {
    await tui.sendText("/thread list");
    try {
      await tui.waitForText(`${name}  idle`, 1500);
      return;
    } catch {
      // Still running.
    }
  }
  throw new Error(`thread ${name} never went idle`);
}

test.skipIf(SKIP_TMUX)("the model reads a thread with thread_read and gets its output as delimited data", async () => {
  const fixture = createFixture("tool-read");
  const { gateway, bodies } = startToolGateway("inspect alpha now", "thread_read", { name: "alpha" }, "thread: alpha");
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");

    await tui.sendText("inspect alpha now");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);

    const withResult = bodies.find(b => b.includes("thread: alpha"));
    expect(withResult).toBeDefined();
    // The tool result reached the model as delimited data holding the thread's answer.
    expect(withResult).toContain("<thread_output name=");
    expect(withResult).toContain("THREAD_ANSWER_OK");
    expect(withResult).toContain("not instructions to you");
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("the model lists threads with thread_read when it omits the name", async () => {
  const fixture = createFixture("tool-list");
  const { gateway, bodies } = startToolGateway("what threads exist", "thread_read", {}, "Threads (1)");
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");

    await tui.sendText("what threads exist");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("- alpha: idle"))).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("thread_send makes an idle thread run another turn without waiting for it", async () => {
  const fixture = createFixture("tool-send");
  const { gateway, bodies } = startToolGateway(
    "tell alpha to wrap up",
    "thread_send",
    { name: "alpha", message: "say bye now" },
    "Sent to thread alpha",
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");

    await tui.sendText("tell alpha to wrap up");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("Sent to thread alpha"))).toBe(true);

    // The thread took the message as a new turn and answered it.
    let seen = false;
    for (let attempt = 0; attempt < 20 && !seen; attempt++) {
      await tui.sendText("/thread watch alpha");
      try {
        await tui.waitForText("THREAD_BYE_OK", 2000);
        seen = true;
      } catch {
        // Not there yet.
      }
    }
    expect(seen).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 150_000);

test.skipIf(SKIP_TMUX)("thread_send asks for approval in ask mode and shows the message", async () => {
  const fixture = createFixture("tool-send-ask");
  const { gateway, bodies } = startToolGateway(
    "tell alpha to wrap up",
    "thread_send",
    { name: "alpha", message: "say bye now" },
    "Sent to thread alpha",
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway, { FX_PERMISSION_MODE: "ask" });
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");

    await tui.sendText("tell alpha to wrap up");
    await tui.waitForText("say bye now", 20000);
    const pane = await tui.capturePane();
    expect(pane).toContain("thread_send alpha");
    // Nothing is sent until the user approves.
    expect(bodies.some(b => b.includes("Sent to thread alpha"))).toBe(false);
    await tui.sendKeys("1");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("Sent to thread alpha"))).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 150_000);

test.skipIf(SKIP_TMUX)("thread_send refuses unknown threads without creating anything", async () => {
  const fixture = createFixture("tool-send-refuse");
  const { gateway, bodies } = startToolGateway(
    "tell ghost hi",
    "thread_send",
    { name: "ghost", message: "hi" },
    "No thread named ghost",
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("tell ghost hi");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("only by the user"))).toBe(true);
    expect(existsSync(join(fixture.home, ".fx", "threads"))).toBe(false);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 90_000);

test.skipIf(SKIP_TMUX)("a thread that needs approval asks in the main session under its own name and continues after approval", async () => {
  const fixture = createFixture("approval");
  let threadRequests = 0;
  const gateway = startDynamicFakeGateway(
    raw => {
      if (!String(raw).includes("write hello")) return fakeGatewayFinalText("MAIN_ANSWER_OK");
      threadRequests += 1;
      return threadRequests === 1
        ? fakeShellRun("thread_shell_1", "echo from-thread")
        : fakeGatewayFinalText("THREAD_DONE_AFTER_TOOL");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: fixture.workspace,
      isolated: true,
      remainOnExit: true,
      env: { ...env(fixture, gateway), FX_PERMISSION_MODE: "ask", FX_MAX_AGENT_STEPS: "4" },
    });
    await tui.waitForStableComposer(15000);
    await tui.sendText("hello");
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await tui.waitForStableComposer(15000);

    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Thread alpha needs permission", 20000);
    await tui.waitForText("echo from-thread", 5000);

    await tui.sendText("1");
    let finished = false;
    for (let attempt = 0; attempt < 30 && !finished; attempt++) {
      await tui.sendText("/thread watch alpha");
      try {
        await tui.waitForText("THREAD_DONE_AFTER_TOOL", 1500);
        finished = true;
      } catch {
        // Still working.
      }
    }
    expect(finished).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("/new is refused while a thread is running and works once it is stopped", async () => {
  const fixture = createFixture("new-guard");
  const gateway = startDynamicFakeGateway(
    async raw => {
      if (!String(raw).includes("write hello")) return fakeGatewayFinalText("MAIN_ANSWER_OK");
      await Bun.sleep(15000);
      return fakeGatewayFinalText("SLOW_THREAD_DONE");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new slow write hello");
    await tui.waitForText("Started thread slow", 20000);
    await tui.sendText("/new");
    await tui.waitForText("Stop it with /thread stop slow", 10000);

    await tui.sendText("/thread stop slow");
    await tui.waitForText("Stopping slow", 10000);
    let stopped = false;
    for (let attempt = 0; attempt < 30 && !stopped; attempt++) {
      await tui.sendText("/new");
      try {
        await tui.waitForText("Stop it with /thread stop slow", 800);
      } catch {
        stopped = true;
      }
    }
    expect(stopped).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("threads survive a restart: resuming the session lists them and keeps their history", async () => {
  const fixture = createFixture("restart");
  const gateway = startGateway();
  let first: TmuxSession | undefined;
  let second: TmuxSession | undefined;
  try {
    first = await launch(fixture, gateway);
    await first.sendText("/thread new alpha write hello");
    await first.waitForText("Started thread alpha", 20000);
    let idle = false;
    for (let attempt = 0; attempt < 30 && !idle; attempt++) {
      await first.sendText("/thread list");
      try {
        await first.waitForText("alpha  idle", 1500);
        idle = true;
      } catch {
        // Still running.
      }
    }
    expect(idle).toBe(true);
    await first.kill();
    first = undefined;

    second = await TmuxSession.create({
      cmd: `${JSON.stringify(FX_BIN)} --resume last`,
      cwd: fixture.workspace,
      isolated: true,
      remainOnExit: true,
      env: env(fixture, gateway),
    });
    await second.waitForStableComposer(15000);
    await second.sendText("/thread list");
    await second.waitForText("alpha", 10000);

    // The thread keeps its own history, so a new message continues it.
    await second.sendText("/thread send alpha write hello again");
    await second.waitForText("Sent to alpha", 20000);
    let again = false;
    for (let attempt = 0; attempt < 30 && !again; attempt++) {
      await second.sendText("/thread watch alpha");
      try {
        await second.waitForText("THREAD_ANSWER_OK", 1500);
        again = true;
      } catch {
        // Not yet.
      }
    }
    expect(again).toBe(true);
  } finally {
    await first?.kill();
    await second?.kill();
    gateway.stop();
  }
}, 120_000);
