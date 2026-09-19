import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { Database } from "bun:sqlite";
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSession, exec, openDb } from "@oma/core";
import {
  createDesktopServices,
  DesktopError,
  type SessionOperations,
} from "./services.ts";

let db: Database;
const tempDirs: string[] = [];

beforeEach(() => {
  db = openDb({ path: ":memory:" });
});

afterEach(() => {
  db.close();
  while (tempDirs.length) {
    rmSync(tempDirs.pop()!, { recursive: true, force: true });
  }
});

async function makeRepo(): Promise<string> {
  const directory = mkdtempSync(join(tmpdir(), "oma-fs-repo-"));
  tempDirs.push(directory);
  await exec(["git", "init", "-b", "main"], { cwd: directory });
  await exec(["git", "config", "user.email", "test@example.com"], {
    cwd: directory,
  });
  await exec(["git", "config", "user.name", "Test"], { cwd: directory });
  writeFileSync(join(directory, "README.md"), "# editor\n");
  writeFileSync(join(directory, ".gitignore"), "ignored_vendor\n");
  mkdirSync(join(directory, "src"));
  writeFileSync(join(directory, "src", "index.ts"), "export const n = 1;\n");
  await exec(["git", "add", "."], { cwd: directory });
  await exec(["git", "commit", "-m", "init"], { cwd: directory });
  return realpathSync(directory);
}

function sessionOperations(): SessionOperations {
  return {
    list: async () => [],
    status: async () => {
      throw new Error("not used");
    },
    create: async () => {
      throw new Error("not used");
    },
    resume: async () => {
      throw new Error("not used");
    },
    switchAgent: async () => {
      throw new Error("not used");
    },
    end: async () => undefined,
    remove: async () => undefined,
  };
}

describe("desktop filesystem", () => {
  test("lists tracked files and skips gitignored paths", async () => {
    const repo = await makeRepo();
    mkdirSync(join(repo, "ignored_vendor"), { recursive: true });
    writeFileSync(join(repo, "ignored_vendor", "secret.js"), "nope\n");
    writeFileSync(join(repo, "src", "extra.ts"), "export {};\n");
    const service = createDesktopServices({ db, manager: sessionOperations() });
    const project = await service.projectAdd({ repo_path: repo });

    const tree = await service.fsTree({ project_id: project.id });

    expect(tree.paths).toContain("README.md");
    expect(tree.paths).toContain("src/index.ts");
    expect(tree.paths).toContain("src/extra.ts");
    expect(tree.paths.some((path) => path.startsWith("ignored_vendor/"))).toBe(
      false,
    );
  });

  test("reads and writes a text file inside the project", async () => {
    const repo = await makeRepo();
    const service = createDesktopServices({ db, manager: sessionOperations() });
    const project = await service.projectAdd({ repo_path: repo });

    const before = await service.fsRead({
      project_id: project.id,
      path: "src/index.ts",
    });
    expect(before).toEqual({
      path: "src/index.ts",
      content: "export const n = 1;\n",
    });

    const written = await service.fsWrite({
      project_id: project.id,
      path: "src/index.ts",
      content: "export const n = 2;\n",
    });
    expect(written.bytes_written).toBeGreaterThan(0);

    const after = await service.fsRead({
      project_id: project.id,
      path: "src/index.ts",
    });
    expect(after.content).toBe("export const n = 2;\n");
  });

  test("rejects path traversal for read and write", async () => {
    const repo = await makeRepo();
    const service = createDesktopServices({ db, manager: sessionOperations() });
    const project = await service.projectAdd({ repo_path: repo });

    try {
      await service.fsRead({ project_id: project.id, path: "../secret.txt" });
      throw new Error("read unexpectedly succeeded");
    } catch (error) {
      expect(error).toBeInstanceOf(DesktopError);
      expect(error).toMatchObject({ code: -32001 });
    }

    try {
      await service.fsWrite({
        project_id: project.id,
        path: "../secret.txt",
        content: "nope",
      });
      throw new Error("write unexpectedly succeeded");
    } catch (error) {
      expect(error).toBeInstanceOf(DesktopError);
      expect(error).toMatchObject({ code: -32001 });
    }
  });

  test("reads a session worktree rather than the main checkout", async () => {
    const repo = await makeRepo();
    const service = createDesktopServices({ db, manager: sessionOperations() });
    const project = await service.projectAdd({ repo_path: repo });
    await exec(["git", "branch", "oma/edit"], { cwd: repo });
    const worktree = join(repo, ".worktrees", "oma-edit");
    mkdirSync(join(repo, ".worktrees"), { recursive: true });
    await exec(["git", "worktree", "add", worktree, "oma/edit"], { cwd: repo });
    writeFileSync(join(worktree, "README.md"), "# session\n");
    const session = createSession(db, {
      repo_path: repo,
      worktree_path: worktree,
      branch: "oma/edit",
    });

    const main = await service.fsRead({
      project_id: project.id,
      path: "README.md",
    });
    const fromSession = await service.fsRead({
      project_id: project.id,
      session_id: session.id,
      path: "README.md",
    });

    expect(main.content).toBe("# editor\n");
    expect(fromSession.content).toBe("# session\n");
  });

  test("rejects a session that belongs to another project", async () => {
    const repoA = await makeRepo();
    const repoB = await makeRepo();
    const service = createDesktopServices({ db, manager: sessionOperations() });
    const projectA = await service.projectAdd({ repo_path: repoA });
    const sessionB = createSession(db, {
      repo_path: repoB,
      worktree_path: repoB,
    });

    try {
      await service.fsTree({
        project_id: projectA.id,
        session_id: sessionB.id,
      });
      throw new Error("fsTree unexpectedly succeeded");
    } catch (error) {
      expect(error).toBeInstanceOf(DesktopError);
      expect(error).toMatchObject({ code: -32001 });
    }
  });

  test("returns a unified diff for a modified file", async () => {
    const repo = await makeRepo();
    writeFileSync(join(repo, "README.md"), "# editor\nchanged\n");
    const service = createDesktopServices({ db, manager: sessionOperations() });
    const project = await service.projectAdd({ repo_path: repo });

    const result = await service.gitFileDiff({
      project_id: project.id,
      path: "README.md",
    });

    expect(result.path).toBe("README.md");
    expect(result.diff).toContain("+changed");
  });

  test("rejects a binary file", async () => {
    const repo = await makeRepo();
    writeFileSync(join(repo, "blob.bin"), Buffer.from([0, 1, 2, 3, 0, 9]));
    await exec(["git", "add", "blob.bin"], { cwd: repo });
    await exec(["git", "commit", "-m", "blob"], { cwd: repo });
    const service = createDesktopServices({ db, manager: sessionOperations() });
    const project = await service.projectAdd({ repo_path: repo });

    try {
      await service.fsRead({ project_id: project.id, path: "blob.bin" });
      throw new Error("read unexpectedly succeeded");
    } catch (error) {
      expect(error).toBeInstanceOf(DesktopError);
      expect(error).toMatchObject({ code: -32001 });
    }
  });
});
