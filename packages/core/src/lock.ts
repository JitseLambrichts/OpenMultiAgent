import {
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { omaHome } from "./paths.ts";

export interface FileLockOptions {
  timeoutMs?: number;
  staleMs?: number;
  pollMs?: number;
}

/**
 * A small cross-process mutex based on atomic directory creation. It is used
 * for agent starts whose native transcript id must be discovered afterwards.
 */
export async function withFileLock<T>(
  name: string,
  fn: () => Promise<T>,
  options: FileLockOptions = {},
): Promise<T> {
  if (!/^[a-z0-9-]+$/i.test(name)) throw new Error(`invalid lock name '${name}'`);
  const timeoutMs = options.timeoutMs ?? 15_000;
  const staleMs = options.staleMs ?? 60_000;
  const pollMs = options.pollMs ?? 50;
  const locksDir = join(omaHome(), "locks");
  const lockDir = join(locksDir, `${name}.lock`);
  mkdirSync(locksDir, { recursive: true });
  const deadline = Date.now() + timeoutMs;

  while (true) {
    try {
      mkdirSync(lockDir);
      writeFileSync(join(lockDir, "owner.json"), JSON.stringify({ pid: process.pid }));
      break;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      try {
        let ownerAlive = false;
        let ownerDead = false;
        try {
          const owner = JSON.parse(
            readFileSync(join(lockDir, "owner.json"), "utf8"),
          ) as { pid?: unknown };
          if (typeof owner.pid === "number") {
            try {
              process.kill(owner.pid, 0);
              ownerAlive = true;
            } catch (signalError) {
              if ((signalError as NodeJS.ErrnoException).code === "ESRCH")
                ownerDead = true;
              else ownerAlive = true;
            }
          }
        } catch {
          // A crash between mkdir and owner write is reclaimed by age below.
        }
        if (
          ownerDead ||
          (!ownerAlive && Date.now() - statSync(lockDir).mtimeMs > staleMs)
        ) {
          rmSync(lockDir, { recursive: true, force: true });
          continue;
        }
      } catch (statError) {
        if ((statError as NodeJS.ErrnoException).code !== "ENOENT") throw statError;
        continue;
      }
      if (Date.now() >= deadline) {
        throw new Error(`timed out waiting for '${name}' lock`);
      }
      await Bun.sleep(pollMs);
    }
  }

  try {
    return await fn();
  } finally {
    rmSync(lockDir, { recursive: true, force: true });
  }
}
