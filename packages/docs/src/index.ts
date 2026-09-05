import type { Database } from "bun:sqlite";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import type {
  AgentAdapter,
  ExecResult,
  MemoryKind,
} from "@oma/core";
import {
  createMemory,
  exec,
  isMemoryKind,
  MEMORY_KINDS,
  repoDocsDir,
  resolveSession,
  supersedeMemory,
} from "@oma/core";

export type CandidateStatus = "pending" | "promoted" | "rejected";

export interface CandidateInput {
  kind: MemoryKind;
  title: string;
  body: string;
  confidence: number;
  supersedes_memory_id: string | null;
}

export interface PromotionCandidate extends CandidateInput {
  id: string;
  session_id: string;
  status: CandidateStatus;
  promoted_memory_id: string | null;
  created_at: string;
}

type CommandRunner = (
  command: string[],
  options?: { cwd?: string; env?: Record<string, string> },
) => Promise<ExecResult>;

function parseJson(value: string): unknown {
  const trimmed = value
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
  try {
    return JSON.parse(trimmed);
  } catch {
    const lines = trimmed.split("\n").filter(Boolean);
    for (const line of lines.reverse()) {
      try {
        const parsed = JSON.parse(line) as Record<string, unknown>;
        const nested =
          parsed.result ??
          parsed.response ??
          parsed.text ??
          (parsed.item as Record<string, unknown> | undefined)?.text;
        if (typeof nested === "string") return parseJson(nested);
      } catch {
        // A streaming agent may emit non-JSON diagnostics between JSON events.
      }
    }
    throw new Error("extractor did not return valid JSON");
  }
}

function unwrapResponse(value: unknown): unknown {
  let current = value;
  for (let depth = 0; depth < 4; depth++) {
    if (typeof current === "string") {
      current = parseJson(current);
      continue;
    }
    if (!current || typeof current !== "object" || Array.isArray(current)) break;
    const record = current as Record<string, unknown>;
    if (Array.isArray(record.candidates)) return record;
    const nested = record.result ?? record.response ?? record.text;
    if (nested === undefined) break;
    current = nested;
  }
  return current;
}

export function parseCandidateResponse(output: string): CandidateInput[] {
  const value = unwrapResponse(parseJson(output));
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("extractor response must be an object");
  }
  const rawCandidates = (value as Record<string, unknown>).candidates;
  if (!Array.isArray(rawCandidates)) {
    throw new Error("extractor response must contain a candidates array");
  }
  if (rawCandidates.length > 50) throw new Error("extractor returned too many candidates");

  return rawCandidates.map((raw, index) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error(`invalid candidate ${index}: expected an object`);
    }
    const record = raw as Record<string, unknown>;
    const kind = record.kind;
    const title = typeof record.title === "string" ? record.title.trim() : "";
    const body = typeof record.body === "string" ? record.body.trim() : "";
    const confidence = record.confidence;
    const supersedes = record.supersedes_memory_id;
    if (
      typeof kind !== "string" ||
      !isMemoryKind(kind) ||
      !title ||
      !body ||
      typeof confidence !== "number" ||
      !Number.isFinite(confidence) ||
      confidence < 0 ||
      confidence > 1 ||
      (supersedes !== undefined && supersedes !== null && typeof supersedes !== "string")
    ) {
      throw new Error(`invalid candidate ${index}`);
    }
    return {
      kind,
      title,
      body,
      confidence,
      supersedes_memory_id: (supersedes as string | null | undefined) ?? null,
    };
  });
}

export function listCandidates(
  db: Database,
  sessionId: string,
  status?: CandidateStatus,
): PromotionCandidate[] {
  return status
    ? db
        .query<PromotionCandidate, [string, CandidateStatus]>(
          `SELECT * FROM promotion_candidate
            WHERE session_id = ? AND status = ?
            ORDER BY created_at, id`,
        )
        .all(sessionId, status)
    : db
        .query<PromotionCandidate, [string]>(
          `SELECT * FROM promotion_candidate
            WHERE session_id = ?
            ORDER BY created_at, id`,
        )
        .all(sessionId);
}

export function saveCandidates(
  db: Database,
  sessionId: string,
  candidates: CandidateInput[],
): PromotionCandidate[] {
  resolveSession(db, sessionId);
  db.transaction(() => {
    db.run(
      "DELETE FROM promotion_candidate WHERE session_id = ? AND status = 'pending'",
      [sessionId],
    );
    const statement = db.prepare(
      `INSERT INTO promotion_candidate
       (id, session_id, kind, title, body, confidence, supersedes_memory_id,
        status, promoted_memory_id, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', NULL, ?)`,
    );
    for (const candidate of candidates) {
      statement.run(
        randomUUID(),
        sessionId,
        candidate.kind,
        candidate.title,
        candidate.body,
        candidate.confidence,
        candidate.supersedes_memory_id,
        new Date().toISOString(),
      );
    }
  })();
  return listCandidates(db, sessionId, "pending");
}

interface ExtractionEvent {
  ts: string;
  role: string;
  kind: string;
  tool_name: string | null;
  text: string;
}

export function buildExtractionPrompt(db: Database, sessionId: string): string {
  const session = resolveSession(db, sessionId);
  const events = db
    .query<ExtractionEvent, [string]>(
      `SELECT ts, role, kind, tool_name, text
         FROM event
        WHERE session_id = ? AND text != ''
        ORDER BY ts, seq`,
    )
    .all(session.id)
    .map(
      (event) =>
        `[${event.ts}] ${event.role}/${event.kind}${event.tool_name ? `:${event.tool_name}` : ""}: ${event.text}`,
    )
    .join("\n")
    .slice(-80_000);
  const memories = db
    .query<
      {
        id: string;
        kind: string;
        title: string;
        body: string;
        confidence: number;
        source_session_id: string | null;
      },
      [string]
    >(
      `SELECT id, kind, title, body, confidence, source_session_id FROM memory
        WHERE superseded_by IS NULL AND repo_path = ?
        ORDER BY created_at DESC LIMIT 100`,
    )
    .all(session.repo_path);

  return [
    "Extract only durable knowledge from this coding session.",
    "Return JSON only. Do not include Markdown fences or commentary.",
    `Allowed kinds: ${MEMORY_KINDS.join(", ")}.`,
    "Every candidate must contain kind, title, body, confidence (0..1), and supersedes_memory_id (string or null).",
    "Use supersedes_memory_id only when a new fact directly corrects a listed live memory.",
    "Required schema: {\"candidates\":[{\"kind\":\"decision|invariant|risk|ownership|howto\",\"title\":\"...\",\"body\":\"include rationale and constraints\",\"confidence\":0.0,\"supersedes_memory_id\":null}]}",
    `Session task: ${session.title ?? "untitled"}`,
    `Repository: ${session.repo_path}`,
    `Live memory: ${JSON.stringify(memories)}`,
    "Transcript:",
    events || "(no normalized events)",
  ].join("\n\n");
}

export async function extractSession(
  db: Database,
  sessionId: string,
  adapter: AgentAdapter,
  runner: CommandRunner = exec,
): Promise<PromotionCandidate[]> {
  const session = resolveSession(db, sessionId);
  if (!(await adapter.isAvailable())) {
    throw new Error(`'${adapter.binary}' is not on PATH`);
  }
  const command = adapter.headlessCommand({
    cwd: session.worktree_path,
    prompt: buildExtractionPrompt(db, session.id),
    json: true,
  });
  const result = await runner(command, { cwd: session.worktree_path });
  if (result.code !== 0) {
    throw new Error(
      `extractor exited ${result.code}: ${result.stderr.trim() || result.stdout.trim()}`,
    );
  }
  return saveCandidates(db, session.id, parseCandidateResponse(result.stdout));
}

interface RenderedMemory {
  kind: MemoryKind;
  title: string;
  body: string;
  confidence: number;
  source_session_id: string | null;
  created_at: string;
}

const FILES: Record<MemoryKind, string> = {
  decision: "decisions.md",
  invariant: "invariants.md",
  risk: "risks.md",
  ownership: "ownership.md",
  howto: "howtos.md",
};

const TITLES: Record<MemoryKind, string> = {
  decision: "Decisions",
  invariant: "Invariants",
  risk: "Risks",
  ownership: "Ownership",
  howto: "How-tos",
};

function markdownFor(kind: MemoryKind, memories: RenderedMemory[]): string {
  const entries = memories
    .filter((memory) => memory.kind === kind)
    .map((memory) =>
      [
        `## ${memory.title}`,
        "",
        memory.body,
        "",
        `- Confidence: ${memory.confidence.toFixed(2)}`,
        `- Source session: \`${memory.source_session_id ?? "unknown"}\``,
        `- Recorded: ${memory.created_at}`,
      ].join("\n"),
    );
  return [
    `# ${TITLES[kind]}`,
    "",
    "Generated by OMA from reviewed session knowledge. Edit through a new promotion so provenance remains intact.",
    ...(entries.length ? ["", entries.join("\n\n")] : []),
    "",
  ].join("\n");
}

function liveMemories(db: Database, repoPath: string): RenderedMemory[] {
  return db
    .query<RenderedMemory, [string]>(
      `SELECT kind, title, body, confidence, source_session_id, created_at
         FROM memory
        WHERE repo_path = ? AND superseded_by IS NULL
        ORDER BY kind, created_at, id`,
    )
    .all(repoPath);
}

function previewMemories(
  db: Database,
  repoPath: string,
  candidates: PromotionCandidate[],
): RenderedMemory[] {
  const superseded = new Set(
    candidates
      .map((candidate) => candidate.supersedes_memory_id)
      .filter((id): id is string => Boolean(id)),
  );
  const current = db
    .query<RenderedMemory & { id: string }, [string]>(
      `SELECT id, kind, title, body, confidence, source_session_id, created_at
         FROM memory
        WHERE repo_path = ? AND superseded_by IS NULL
        ORDER BY kind, created_at, id`,
    )
    .all(repoPath)
    .filter((memory) => !superseded.has(memory.id));
  return [
    ...current,
    ...candidates.map((candidate) => ({
      kind: candidate.kind,
      title: candidate.title,
      body: candidate.body,
      confidence: candidate.confidence,
      source_session_id: candidate.session_id,
      created_at: candidate.created_at,
    })),
  ];
}

export function previewPromotion(db: Database, sessionId: string): string {
  const session = resolveSession(db, sessionId);
  const candidates = listCandidates(db, session.id, "pending");
  if (!candidates.length) return "No pending knowledge candidates.";
  const memories = previewMemories(db, session.repo_path, candidates);
  const kinds = [...new Set(candidates.map((candidate) => candidate.kind))];
  return kinds
    .map((kind) => {
      const relativePath = `.oma/docs/${FILES[kind]}`;
      const absolutePath = join(session.repo_path, relativePath);
      const before = existsSync(absolutePath)
        ? readFileSync(absolutePath, "utf8")
        : "";
      const after = markdownFor(kind, memories);
      const oldLines = before ? before.replace(/\n$/, "").split("\n") : [];
      const newLines = after ? after.replace(/\n$/, "").split("\n") : [];
      return [
        `--- ${relativePath}`,
        `+++ ${relativePath}`,
        `@@ -1,${oldLines.length} +1,${newLines.length} @@`,
        ...oldLines.map((line) => `-${line}`),
        ...newLines.map((line) => `+${line}`),
      ].join("\n");
    })
    .join("\n\n");
}

interface FileSnapshot {
  path: string;
  existed: boolean;
  content: string;
}

function snapshotLivingDocs(repoPath: string): FileSnapshot[] {
  const directory = repoDocsDir(repoPath);
  return MEMORY_KINDS.map((kind) => {
    const path = join(directory, FILES[kind]);
    return {
      path,
      existed: existsSync(path),
      content: existsSync(path) ? readFileSync(path, "utf8") : "",
    };
  });
}

function atomicWrite(
  path: string,
  content: string,
  onReplace?: () => void,
): void {
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, content);
    renameSync(temporary, path);
    onReplace?.();
  } finally {
    rmSync(temporary, { force: true });
  }
}

function restoreLivingDocs(snapshots: FileSnapshot[]): void {
  for (const snapshot of snapshots) {
    if (snapshot.existed) atomicWrite(snapshot.path, snapshot.content);
    else rmSync(snapshot.path, { force: true });
  }
}

function writeLivingDocsAtomic(
  db: Database,
  repoPath: string,
  onReplace?: () => void,
): string[] {
  const directory = repoDocsDir(repoPath);
  mkdirSync(directory, { recursive: true });
  const memories = liveMemories(db, repoPath);
  return MEMORY_KINDS.map((kind) => {
    const path = join(directory, FILES[kind]);
    atomicWrite(path, markdownFor(kind, memories), onReplace);
    return path;
  });
}

export function promoteSession(
  db: Database,
  sessionId: string,
): { promoted: number; files: string[] } {
  const session = resolveSession(db, sessionId);
  let candidates: PromotionCandidate[] = [];
  let snapshots: FileSnapshot[] = [];
  let files: string[] = [];
  let replacedFiles = false;
  try {
    const transaction = db.transaction(() => {
      // BEGIN IMMEDIATE is acquired before this callback, so validation,
      // snapshots, DB writes and file replacement see one serialized state
      // even when multiple CLI processes promote concurrently.
      candidates = listCandidates(db, session.id, "pending");
      if (!candidates.length) return;
      for (const candidate of candidates) {
        if (!candidate.supersedes_memory_id) continue;
        const previous = db
          .query<
            {
              scope: string;
              repo_path: string | null;
              superseded_by: string | null;
            },
            [string]
          >("SELECT scope, repo_path, superseded_by FROM memory WHERE id = ?")
          .get(candidate.supersedes_memory_id);
        if (!previous) {
          throw new Error(
            `candidate '${candidate.title}' supersedes unknown memory ${candidate.supersedes_memory_id}`,
          );
        }
        if (previous.scope !== "repo" || previous.repo_path !== session.repo_path) {
          throw new Error(
            `candidate '${candidate.title}' cannot supersede memory from another repository`,
          );
        }
        if (previous.superseded_by) {
          throw new Error(
            `candidate '${candidate.title}' targets memory that is already superseded`,
          );
        }
      }
      snapshots = snapshotLivingDocs(session.repo_path);
      for (const candidate of candidates) {
        const memory = createMemory(db, {
          kind: candidate.kind,
          repo_path: session.repo_path,
          title: candidate.title,
          body: candidate.body,
          confidence: candidate.confidence,
          source_session_id: session.id,
        });
        if (candidate.supersedes_memory_id) {
          supersedeMemory(db, candidate.supersedes_memory_id, memory.id);
        }
        db.run(
          `UPDATE promotion_candidate
              SET status = 'promoted', promoted_memory_id = ?
            WHERE id = ?`,
          [memory.id, candidate.id],
        );
      }
      // File replacement happens inside the SQLite transaction. A write error
      // rolls the DB back; the catch restores any files already replaced.
      files = writeLivingDocsAtomic(db, session.repo_path, () => {
        replacedFiles = true;
      });
    });
    transaction.immediate();
  } catch (error) {
    // A lock acquisition failure has not touched the filesystem. Restore only
    // when this invocation actually replaced at least one destination.
    if (replacedFiles) restoreLivingDocs(snapshots);
    throw error;
  }
  return {
    promoted: candidates.length,
    files,
  };
}
