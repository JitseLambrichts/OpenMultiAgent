import { describe, expect, test } from "bun:test";

describe("oma command surface", () => {
  test("advertises orchestration and reviewed living-doc commands", async () => {
    const child = Bun.spawn(
      [process.execPath, "run", `${import.meta.dir}/index.ts`, "--help"],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [stdout, code] = await Promise.all([
      new Response(child.stdout).text(),
      child.exited,
    ]);

    expect(code).toBe(0);
    expect(stdout).toContain("oma switch <id>");
    expect(stdout).toContain("oma watch [--interval SECONDS]");
    expect(stdout).toContain("oma resume <id>");
    expect(stdout).toContain("oma fork <id>");
    expect(stdout).toContain("oma extract <id>");
    expect(stdout).toContain("oma promote <id> [--apply]");
    expect(stdout).toContain("oma end <id> [--extract]");
  });
});
