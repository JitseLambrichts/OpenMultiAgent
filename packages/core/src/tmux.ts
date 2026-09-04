import { exec, execOrThrow } from "./exec.ts";
import { TMUX_PREFIX, tmuxSessionName } from "./paths.ts";

export interface TmuxSession {
  name: string;
  /** The OMA session id, i.e. the name without the `oma-` prefix. */
  sessionId: string;
  windows: number;
  created: string;
}

export async function tmuxAvailable(): Promise<boolean> {
  return (await exec(["tmux", "-V"])).code === 0;
}

export async function hasSession(name: string): Promise<boolean> {
  return (await exec(["tmux", "has-session", "-t", `=${name}`])).code === 0;
}

export interface NewSessionOptions {
  name: string;
  cwd: string;
  /** Run inside a login shell so the agent inherits the user's PATH and rc. */
  command?: string;
  env?: Record<string, string>;
}

export async function newSession(opts: NewSessionOptions): Promise<void> {
  if (await hasSession(opts.name)) {
    throw new Error(`tmux session '${opts.name}' already exists`);
  }
  const sessionEnv = Object.entries(opts.env ?? {}).flatMap(([key, value]) => {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      throw new Error(`invalid tmux environment variable name '${key}'`);
    }
    // `tmux -e` writes into the session environment. Merely setting the
    // client process environment is insufficient when a tmux server already
    // exists, which is the normal multi-session OMA case.
    return ["-e", `${key}=${value}`];
  });
  const cmd = [
    "tmux",
    "new-session",
    "-d",
    "-s",
    opts.name,
    "-c",
    opts.cwd,
    ...sessionEnv,
    // Large history so the scrollback is a usable escape hatch.
    ...(opts.command ? [opts.command] : []),
  ];
  await execOrThrow(cmd);
  await exec(["tmux", "set-option", "-t", opts.name, "history-limit", "50000"]);
}

/**
 * Only sessions carrying the `oma-` prefix. This machine also runs `xirp-*`
 * sessions, so listing every tmux session would adopt sessions OMA never made.
 */
export async function listSessions(): Promise<TmuxSession[]> {
  // tmux 3.4+ sanitises non-printable characters in format output (a tab
  // becomes `_`), so the separator must be printable. Session names can never
  // contain ':' (tmux rejects them), which makes it a safe delimiter.
  const result = await exec([
    "tmux",
    "list-sessions",
    "-F",
    "#{session_name}:#{session_windows}:#{session_created}",
  ]);
  // `no server running` is a normal empty state, not an error.
  if (result.code !== 0) return [];

  return result.stdout
    .split("\n")
    .filter((line) => line.trim() !== "")
    .map((line) => line.split(":"))
    .filter(([name]) => name?.startsWith(TMUX_PREFIX))
    .map(([name, windows, created]) => ({
      name: name!,
      sessionId: name!.slice(TMUX_PREFIX.length),
      windows: Number.parseInt(windows ?? "0", 10),
      created: new Date(Number.parseInt(created ?? "0", 10) * 1000).toISOString(),
    }));
}

export async function killSession(name: string): Promise<void> {
  await exec(["tmux", "kill-session", "-t", `=${name}`]);
}

export async function renameSession(from: string, to: string): Promise<void> {
  await execOrThrow(["tmux", "rename-session", "-t", `=${from}`, to]);
}

export async function sendKeys(name: string, text: string): Promise<void> {
  await execOrThrow(["tmux", "send-keys", "-t", name, text, "Enter"]);
}

export async function capturePane(
  name: string,
  lines = 200,
): Promise<string> {
  const result = await exec([
    "tmux",
    "capture-pane",
    "-p",
    "-t",
    name,
    "-S",
    `-${lines}`,
  ]);
  return result.code === 0 ? result.stdout : "";
}

/** The UI never owns a terminal; it shells out to this. */
export function attachCommand(sessionId: string): string[] {
  return ["tmux", "attach", "-t", tmuxSessionName(sessionId)];
}
