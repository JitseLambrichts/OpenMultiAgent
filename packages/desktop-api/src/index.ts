#!/usr/bin/env bun
import { openDb } from "@oma/core";
import {
  failure,
  type JsonRpcId,
  type JsonRpcRequest,
  LineDecoder,
  RPC_ERROR,
  serializeMessage,
} from "./protocol.ts";
import { createRouter } from "./router.ts";
import { createProductionServices } from "./services.ts";

export function parentAlive(pid: number): boolean {
  if (pid <= 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM means the process exists but belongs to someone else.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

function requestId(value: unknown): JsonRpcId {
  if (typeof value === "string" || typeof value === "number" || value === null) {
    return value;
  }
  return null;
}

function parseRequest(line: string): JsonRpcRequest {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    throw failure(null, RPC_ERROR.PARSE_ERROR, "Parse error");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw failure(null, RPC_ERROR.INVALID_REQUEST, "Invalid Request");
  }
  const candidate = value as Record<string, unknown>;
  if (candidate.jsonrpc !== "2.0" || typeof candidate.method !== "string") {
    throw failure(
      requestId(candidate.id),
      RPC_ERROR.INVALID_REQUEST,
      "Invalid Request",
    );
  }
  if (
    candidate.id !== undefined &&
    candidate.id !== null &&
    typeof candidate.id !== "string" &&
    typeof candidate.id !== "number"
  ) {
    throw failure(null, RPC_ERROR.INVALID_REQUEST, "Invalid Request");
  }
  return candidate as unknown as JsonRpcRequest;
}

function isProtocolFailure(value: unknown): value is ReturnType<typeof failure> {
  return Boolean(
    value &&
      typeof value === "object" &&
      "jsonrpc" in value &&
      "error" in value,
  );
}

/**
 * Reads newline-delimited requests from stdin for as long as the parent keeps
 * the pipe open. `process.stdin` events are used deliberately: on Bun 1.2
 * `Bun.stdin.stream()` only yields piped input once the writer closes it,
 * which would make an interactive client hang on its first request.
 */
export async function main(): Promise<void> {
  const db = openDb();
  let shouldStop = false;
  const services = createProductionServices(db, () => {
    shouldStop = true;
  });
  const router = createRouter(services);
  const lines = new LineDecoder();

  const handleLine = async (line: string) => {
    try {
      const response = await router.dispatch(parseRequest(line));
      if (response) process.stdout.write(serializeMessage(response));
    } catch (error) {
      const response = isProtocolFailure(error)
        ? error
        : failure(null, RPC_ERROR.OPERATION_FAILED, "Operation failed");
      process.stdout.write(serializeMessage(response));
    }
  };

  // The sidecar must never outlive the app. EOF on stdin covers a clean exit;
  // the watchdog covers a crashed or force-quit parent. Bun 1.2 caches
  // `process.ppid`, so liveness is probed with signal 0 against the pid
  // captured at startup instead of watching for re-parenting.
  const initialParent = process.ppid;
  const watchdog = setInterval(() => {
    if (!parentAlive(initialParent)) {
      db.close();
      process.exit(0);
    }
  }, 2000);
  watchdog.unref?.();

  try {
    await new Promise<void>((resolve, reject) => {
      // Requests are dispatched strictly in arrival order.
      let queue: Promise<void> = Promise.resolve();
      const enqueue = (line: string) => {
        queue = queue.then(async () => {
          if (shouldStop) return;
          await handleLine(line);
          if (shouldStop) {
            process.stdin.pause();
            resolve();
          }
        });
      };
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk: string) => {
        for (const line of lines.push(chunk)) enqueue(line);
      });
      process.stdin.on("end", () => {
        for (const line of lines.flush()) enqueue(line);
        queue = queue.then(resolve);
      });
      process.stdin.on("error", reject);
      process.stdin.resume();
    });
  } finally {
    clearInterval(watchdog);
    db.close();
  }
}

if (import.meta.main) {
  try {
    await main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
