import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { exec } from "./exec.ts";
import { fileDiff, listedFiles } from "./git.ts";

const created: string[] = [];

async function makeRepo(): Promise<string> {
  const dir = mkdtempSync(join(tmpdir(), "oma-git-"));
  created.push(dir);
  await exec(["git", "init", "-b", "main"], { cwd: dir });
  await exec(["git", "config", "user.email", "test@example.com"], { cwd: dir });
  await exec(["git", "config", "user.name", "Test"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "# test\n");
  writeFileSync(join(dir, ".gitignore"), "ignored_vendor\nsecret.bin\n");
  mkdirSync(join(dir, "src"));
  writeFileSync(join(dir, "src", "index.ts"), "export const n = 1;\n");
  await exec(["git", "add", "."], { cwd: dir });
  await exec(["git", "commit", "-m", "init"], { cwd: dir });
  return dir;
}

afterEach(() => {
  while (created.length) {
    rmSync(created.pop()!, { recursive: true, force: true });
  }
});

describe("listedFiles", () => {
  test("returns tracked files and skips gitignored paths", async () => {
    const repo = await makeRepo();
    expect(existsSync(join(repo, ".git"))).toBe(true);
    mkdirSync(join(repo, "ignored_vendor", "pkg"), { recursive: true });
    writeFileSync(join(repo, "ignored_vendor", "pkg", "index.js"), "ignored\n");
    writeFileSync(join(repo, "src", "extra.ts"), "export {};\n");

    const files = await listedFiles(repo);

    expect(files).toContain("README.md");
    expect(files).toContain("src/index.ts");
    expect(files).toContain("src/extra.ts");
    expect(files.some((path) => path.startsWith("ignored_vendor/"))).toBe(
      false,
    );
  });
});

describe("fileDiff", () => {
  test("returns a unified diff for a modified tracked file", async () => {
    const repo = await makeRepo();
    writeFileSync(join(repo, "README.md"), "# test\nchanged\n");

    const diff = await fileDiff(repo, "README.md");

    expect(diff).toContain("README.md");
    expect(diff).toContain("+changed");
  });

  test("returns an added-file diff for an untracked path", async () => {
    const repo = await makeRepo();
    writeFileSync(join(repo, "src", "new.ts"), "export const x = 2;\n");

    const diff = await fileDiff(repo, "src/new.ts");

    expect(diff).toContain("new.ts");
    expect(diff).toContain("+export const x = 2;");
  });
});
