export interface ExecResult {
  code: number;
  stdout: string;
  stderr: string;
}

export async function exec(
  cmd: string[],
  opts: { cwd?: string; env?: Record<string, string> } = {},
): Promise<ExecResult> {
  const proc = Bun.spawn(cmd, {
    cwd: opts.cwd,
    env: opts.env ? { ...process.env, ...opts.env } : process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const code = await proc.exited;
  return { code, stdout, stderr };
}

export async function execOrThrow(
  cmd: string[],
  opts: { cwd?: string; env?: Record<string, string> } = {},
): Promise<string> {
  const result = await exec(cmd, opts);
  if (result.code !== 0) {
    throw new Error(
      `${cmd.join(" ")} exited ${result.code}: ${result.stderr.trim() || result.stdout.trim()}`,
    );
  }
  return result.stdout;
}
