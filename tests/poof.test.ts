import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { existsSync, mkdtempSync, rmSync, writeFileSync, readFileSync, mkdirSync } from "fs";
import { join } from "path";
import { StringDecoder } from "node:string_decoder";

const POOF_BIN = join(import.meta.dir, "../zig-out/bin/poof");
// Use ephemeral tmpdir - must be outside /tmp since poof mounts fresh /tmp
let TEST_DIR: string;
// Shell prompt: # for root, $ for non-root
const SHELL_PROMPT = process.getuid?.() === 0 ? "# " : "$ ";

describe("poof CLI", () => {
  beforeAll(() => {
    if (!existsSync(POOF_BIN)) {
      throw new Error(`poof binary not found at ${POOF_BIN}. Run 'zig build' first.`);
    }
    TEST_DIR = mkdtempSync(join("/var/tmp", "poof-test-"));
    // Force bash for consistent prompt detection
    process.env.SHELL = "/bin/bash";
  });

  afterAll(() => {
    if (TEST_DIR && existsSync(TEST_DIR)) {
      rmSync(TEST_DIR, { recursive: true });
    }
  });

  // ============================================================================
  // Help and Usage
  // ============================================================================
  describe("help and usage", () => {
    test("--help shows usage", () => {
      const result = spawnSync([POOF_BIN, "--help"]);
      const output = result.stderr.toString();
      expect(output).toContain("USAGE");
      expect(output).toContain("COMMANDS");
      expect(output).toContain("exec");
      expect(output).toContain("run");
      expect(output).toContain("enter");
      expect(result.exitCode).toBe(0);
    });

    test("-h shows usage", () => {
      const result = spawnSync([POOF_BIN, "-h"]);
      const output = result.stderr.toString();
      expect(output).toContain("USAGE");
      expect(result.exitCode).toBe(0);
    });

    test("no arguments shows usage and error", () => {
      const result = spawnSync([POOF_BIN]);
      const output = result.stderr.toString();
      expect(output).toContain("USAGE");
      expect(result.exitCode).toBe(1);
    });

    test("unknown option shows error", () => {
      const result = spawnSync([POOF_BIN, "--unknown"]);
      const output = result.stderr.toString();
      expect(output).toContain("unknown option");
      expect(result.exitCode).toBe(1);
    });

    test("missing command shows help", () => {
      const result = spawnSync([POOF_BIN, "exec"]);
      const output = result.stderr.toString();
      expect(output).toContain("poof exec");
      expect(output).toContain("USAGE");
      expect(result.exitCode).toBe(1);
    });
  });

  // ============================================================================
  // Exec Mode (Ephemeral)
  // ============================================================================
  describe("exec mode", () => {
    describe("basic execution", () => {
      test("runs command and exits with status 0", () => {
        const result = spawnSync([POOF_BIN, "exec", "true"]);
        expect(result.exitCode).toBe(0);
      });

      test("propagates non-zero exit code", () => {
        const result = spawnSync([POOF_BIN, "exec", "false"]);
        expect(result.exitCode).toBe(1);
      });

      test("propagates specific exit code (42)", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "exit 42"]);
        expect(result.exitCode).toBe(42);
      });

      test("propagates exit code 255", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "exit 255"]);
        expect(result.exitCode).toBe(255);
      });

      test("returns 127 for non-existent command", () => {
        const result = spawnSync([POOF_BIN, "exec", "nonexistent-command-xyz"]);
        expect(result.exitCode).toBe(127);
      });

      test("passes arguments to command", () => {
        const result = spawnSync([POOF_BIN, "exec", "echo", "hello", "world"]);
        expect(result.stdout.toString().trim()).toBe("hello world");
      });

      test("works with -- separator", () => {
        const result = spawnSync([POOF_BIN, "exec", "--", "echo", "-n", "test"]);
        expect(result.stdout.toString()).toBe("test");
      });
    });

    describe("filesystem isolation", () => {
      test("file created inside does not exist outside", () => {
        const testFile = join(TEST_DIR, "exec-create.txt");
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          `echo "created" > ${testFile} && cat ${testFile}`
        ]);
        expect(result.stdout.toString().trim()).toBe("created");
        expect(result.exitCode).toBe(0);
        expect(existsSync(testFile)).toBe(false);
      });

      test("can read existing files from host", () => {
        const testFile = join(TEST_DIR, "exec-read.txt");
        writeFileSync(testFile, "readable content");
        const result = spawnSync([POOF_BIN, "exec", "cat", testFile]);
        expect(result.stdout.toString().trim()).toBe("readable content");
      });

      test("modifications to existing files are isolated", () => {
        const testFile = join(TEST_DIR, "exec-modify.txt");
        writeFileSync(testFile, "original");
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          `echo "modified" > ${testFile} && cat ${testFile}`
        ]);
        expect(result.stdout.toString().trim()).toBe("modified");
        expect(readFileSync(testFile, "utf-8")).toBe("original");
      });

      test("file deletion is isolated", () => {
        const testFile = join(TEST_DIR, "exec-delete.txt");
        writeFileSync(testFile, "to be deleted");
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          `rm ${testFile} && test ! -f ${testFile} && echo "deleted"`
        ]);
        expect(result.stdout.toString().trim()).toBe("deleted");
        expect(existsSync(testFile)).toBe(true);
      });

      test("directory creation is isolated", () => {
        const testDir = join(TEST_DIR, "exec-newdir");
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          `mkdir -p ${testDir}/subdir && test -d ${testDir}/subdir && echo "created"`
        ]);
        expect(result.stdout.toString().trim()).toBe("created");
        expect(existsSync(testDir)).toBe(false);
      });

      test("symlink creation is isolated", () => {
        const target = join(TEST_DIR, "exec-symlink-target.txt");
        const link = join(TEST_DIR, "exec-symlink-link");
        writeFileSync(target, "target content");
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          `ln -s ${target} ${link} && cat ${link}`
        ]);
        expect(result.stdout.toString().trim()).toBe("target content");
        expect(existsSync(link)).toBe(false);
      });
    });

    describe("device nodes", () => {
      test("/dev/null is available", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo test > /dev/null && echo ok"]);
        expect(result.stdout.toString().trim()).toBe("ok");
        expect(result.exitCode).toBe(0);
      });

      test("/dev/zero is available", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "head -c 4 /dev/zero | xxd -p"]);
        expect(result.stdout.toString().trim()).toBe("00000000");
        expect(result.exitCode).toBe(0);
      });

      test("/dev/urandom is available", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "head -c 16 /dev/urandom | wc -c"]);
        expect(result.stdout.toString().trim()).toBe("16");
        expect(result.exitCode).toBe(0);
      });

      test("/dev/random is available", () => {
        const result = spawnSync([POOF_BIN, "exec", "test", "-c", "/dev/random"]);
        expect(result.exitCode).toBe(0);
      });

      test("disk devices are NOT available", () => {
        // /dev/sda, /dev/nvme*, etc should not be accessible
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "ls /dev/sd* /dev/nvme* 2>&1 || echo 'no disk devices'"]);
        expect(result.stdout.toString()).toContain("no disk devices");
      });

      test("/dev/mem is NOT available", () => {
        const result = spawnSync([POOF_BIN, "exec", "test", "-e", "/dev/mem"]);
        expect(result.exitCode).not.toBe(0);
      });
    });

    describe("environment", () => {
      test("sets IS_SANDBOX=1", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo $IS_SANDBOX"]);
        expect(result.stdout.toString().trim()).toBe("1");
      });

      test("preserves environment variables", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo $MY_VAR"], {
          env: { ...process.env, MY_VAR: "test-value" }
        });
        expect(result.stdout.toString().trim()).toBe("test-value");
      });

      test("preserves PATH", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo $PATH"]);
        expect(result.stdout.toString().trim()).toContain("/bin");
      });

      test("preserves cwd (non-/tmp)", () => {
        const result = spawnSync([POOF_BIN, "exec", "pwd"], { cwd: "/var" });
        expect(result.stdout.toString().trim()).toBe("/var");
      });

      test("cwd works in TEST_DIR", () => {
        const result = spawnSync([POOF_BIN, "exec", "pwd"], { cwd: TEST_DIR });
        expect(result.stdout.toString().trim()).toBe(TEST_DIR);
      });
    });

    describe("namespace isolation", () => {
      test("PID namespace shows low PID", () => {
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          "cat /proc/self/status | grep -E '^Pid:'"
        ]);
        expect(result.stdout.toString()).toMatch(/Pid:\s+[1-5]/);
      });

      test("/proc shows only isolated processes", () => {
        const hostProcs = spawnSync(["ls", "/proc"]).stdout.toString()
          .split("\n").filter(p => /^\d+$/.test(p)).length;
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          "ls /proc | grep -E '^[0-9]+$' | wc -l"
        ]);
        const poofProcs = parseInt(result.stdout.toString().trim());
        expect(poofProcs).toBeLessThan(hostProcs);
        expect(poofProcs).toBeLessThanOrEqual(5);
      });

      test("/tmp is fresh (isolated from host)", () => {
        const hostMarker = `/tmp/host-marker-${Date.now()}`;
        writeFileSync(hostMarker, "host");
        try {
          const result = spawnSync([
            POOF_BIN, "exec", "sh", "-c",
            `test -f ${hostMarker} && echo "found" || echo "not found"`
          ]);
          expect(result.stdout.toString().trim()).toBe("not found");
        } finally {
          rmSync(hostMarker, { force: true });
        }
      });

      test("/tmp is writable inside poof", () => {
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          "echo test > /tmp/write-test && cat /tmp/write-test"
        ]);
        expect(result.stdout.toString().trim()).toBe("test");
      });
    });

    describe("options", () => {
      test("--timeout kills long-running process", () => {
        const start = Date.now();
        const result = spawnSync([POOF_BIN, "exec", "--timeout=1", "sleep", "60"]);
        const elapsed = Date.now() - start;
        expect(result.exitCode).toBe(124);
        expect(elapsed).toBeLessThan(5000);
      });

      test("--timeout allows fast commands", () => {
        const result = spawnSync([POOF_BIN, "exec", "--timeout=10", "echo", "fast"]);
        expect(result.stdout.toString().trim()).toBe("fast");
        expect(result.exitCode).toBe(0);
      });

      test("-v shows verbose output", () => {
        const result = spawnSync([POOF_BIN, "-v", "exec", "true"]);
        expect(result.stderr.toString()).toContain("uid=");
      });

      test("--verbose shows verbose output", () => {
        const result = spawnSync([POOF_BIN, "--verbose", "exec", "true"]);
        expect(result.stderr.toString()).toContain("uid=");
      });

      test("invalid --timeout shows error", () => {
        const result = spawnSync([POOF_BIN, "exec", "--timeout=abc", "true"]);
        expect(result.stderr.toString()).toContain("invalid timeout");
        expect(result.exitCode).toBe(1);
      });

      test("invalid --memory shows error", () => {
        const result = spawnSync([POOF_BIN, "exec", "--memory=invalid", "true"]);
        expect(result.stderr.toString()).toContain("invalid memory limit");
        expect(result.exitCode).toBe(1);
      });

      test("invalid --pids shows error", () => {
        const result = spawnSync([POOF_BIN, "exec", "--pids=abc", "true"]);
        expect(result.stderr.toString()).toContain("invalid pids limit");
        expect(result.exitCode).toBe(1);
      });
    });
  });

  // ============================================================================
  // Run Mode (Persistent)
  // ============================================================================
  describe("run mode", () => {
    let runTestDir: string;

    beforeEach(() => {
      runTestDir = mkdtempSync(join(TEST_DIR, "run-"));
    });

    afterEach(() => {
      if (runTestDir && existsSync(runTestDir)) {
        rmSync(runTestDir, { recursive: true });
      }
      // Clean up .work and .merged directories
      for (const suffix of [".work", ".merged"]) {
        const path = runTestDir + suffix;
        if (existsSync(path)) {
          rmSync(path, { recursive: true });
        }
      }
    });

    describe("persistence", () => {
      test("saves new file to upper directory", () => {
        const upperDir = join(runTestDir, "upper");
        const testFile = join(runTestDir, "newfile.txt");

        const result = spawnSync([
          POOF_BIN, "run", `--upper=${upperDir}`, "sh", "-c",
          `echo "persisted" > ${testFile}`
        ]);
        expect(result.exitCode).toBe(0);

        // File in upper dir mirrors the path
        const persistedFile = join(upperDir, testFile);
        expect(existsSync(persistedFile)).toBe(true);
        expect(readFileSync(persistedFile, "utf-8").trim()).toBe("persisted");
      });

      test("saves modifications to upper directory", () => {
        const upperDir = join(runTestDir, "upper");
        const testFile = join(runTestDir, "existing.txt");
        writeFileSync(testFile, "original");

        const result = spawnSync([
          POOF_BIN, "run", `--upper=${upperDir}`, "sh", "-c",
          `echo "modified" > ${testFile}`
        ]);
        expect(result.exitCode).toBe(0);

        // Original unchanged
        expect(readFileSync(testFile, "utf-8")).toBe("original");
        // Modification in upper
        const modifiedFile = join(upperDir, testFile);
        expect(readFileSync(modifiedFile, "utf-8").trim()).toBe("modified");
      });

      test("saves directory creation to upper", () => {
        const upperDir = join(runTestDir, "upper");
        const newDir = join(runTestDir, "newdir", "subdir");

        const result = spawnSync([
          POOF_BIN, "run", `--upper=${upperDir}`, "sh", "-c",
          `mkdir -p ${newDir} && echo "test" > ${newDir}/file.txt`
        ]);
        expect(result.exitCode).toBe(0);

        const persistedDir = join(upperDir, newDir);
        expect(existsSync(persistedDir)).toBe(true);
        expect(readFileSync(join(persistedDir, "file.txt"), "utf-8").trim()).toBe("test");
      });

      test("multiple files are persisted", () => {
        const upperDir = join(runTestDir, "upper");

        const result = spawnSync([
          POOF_BIN, "run", `--upper=${upperDir}`, "sh", "-c",
          `echo "a" > ${runTestDir}/a.txt && echo "b" > ${runTestDir}/b.txt && echo "c" > ${runTestDir}/c.txt`
        ]);
        expect(result.exitCode).toBe(0);

        expect(readFileSync(join(upperDir, runTestDir, "a.txt"), "utf-8").trim()).toBe("a");
        expect(readFileSync(join(upperDir, runTestDir, "b.txt"), "utf-8").trim()).toBe("b");
        expect(readFileSync(join(upperDir, runTestDir, "c.txt"), "utf-8").trim()).toBe("c");
      });
    });

    describe("auto-generated upper (non-interactive)", () => {
      test("uses command name as directory", () => {
        const result = spawnSync([POOF_BIN, "run", "true"], { cwd: runTestDir });
        const output = result.stderr.toString();
        expect(output).toContain("Changes will persist to");
        expect(output).toContain("/true");
        expect(result.exitCode).toBe(0);

        // Cleanup
        rmSync(join(runTestDir, "true"), { recursive: true, force: true });
        rmSync(join(runTestDir, "true.work"), { recursive: true, force: true });
        rmSync(join(runTestDir, "true.merged"), { recursive: true, force: true });
      });

      test("adds timestamp when directory exists", () => {
        // Create directory to force timestamp
        const existingDir = join(runTestDir, "echo");
        mkdirSync(existingDir);

        const result = spawnSync([POOF_BIN, "run", "echo", "hi"], { cwd: runTestDir });
        const output = result.stderr.toString();
        expect(output).toMatch(/echo\.\d{14}/);

        // Cleanup
        rmSync(existingDir, { recursive: true, force: true });
        // Find and clean the timestamped dir
        const dirs = spawnSync(["sh", "-c", `ls -d ${runTestDir}/echo.* 2>/dev/null || true`])
          .stdout.toString().trim().split("\n").filter(Boolean);
        for (const dir of dirs) {
          rmSync(dir, { recursive: true, force: true });
          rmSync(dir + ".work", { recursive: true, force: true });
          rmSync(dir + ".merged", { recursive: true, force: true });
        }
      });
    });

    describe("relative paths", () => {
      test("--upper with relative path works", () => {
        const result = spawnSync([
          POOF_BIN, "run", "--upper=my-changes", "sh", "-c",
          `echo "test" > ${runTestDir}/reltest.txt`
        ], { cwd: runTestDir });
        expect(result.exitCode).toBe(0);

        const upperDir = join(runTestDir, "my-changes");
        expect(existsSync(join(upperDir, runTestDir, "reltest.txt"))).toBe(true);

        // Cleanup
        rmSync(upperDir, { recursive: true, force: true });
        rmSync(upperDir + ".work", { recursive: true, force: true });
        rmSync(upperDir + ".merged", { recursive: true, force: true });
      });
    });
  });

  // ============================================================================
  // Enter Mode (Interactive with PTY)
  // ============================================================================
  describe("enter mode", () => {
    let enterTestDir: string;

    // Helper class for terminal interaction
    let activeSession: TerminalSession | null = null;

    class TerminalSession {
      output = "";
      private decoder = new StringDecoder("utf8");
      private proc: ReturnType<typeof spawn>;
      private cursor = 0; // Track position for waitForNew

      constructor(cwd: string, env?: Record<string, string>) {
        this.proc = spawn([POOF_BIN, "enter"], {
          cwd,
          env: { ...process.env, ...env },
          terminal: {
            cols: 80,
            rows: 24,
            data: (_terminal, data) => {
              this.output += this.decoder.write(Buffer.from(data));
            },
          },
        });
        activeSession = this;
      }

      write(text: string) {
        this.proc.terminal!.write(text);
      }

      // Wait for text anywhere in output
      async waitFor(text: string, timeout = 5000) {
        const start = Date.now();
        while (!this.output.includes(text)) {
          if (Date.now() - start > timeout) {
            throw new Error(`Timeout waiting for "${text}". Output so far:\n${this.output}`);
          }
          await Bun.sleep(10);
        }
      }

      // Wait for NEW text after current cursor position, then advance cursor
      async waitForNew(text: string, timeout = 5000) {
        const start = Date.now();
        while (true) {
          const idx = this.output.indexOf(text, this.cursor);
          if (idx !== -1) {
            this.cursor = idx + text.length;
            return;
          }
          if (Date.now() - start > timeout) {
            throw new Error(`Timeout waiting for "${text}". Output after cursor:\n${this.output.slice(this.cursor)}`);
          }
          await Bun.sleep(10);
        }
      }

      kill() {
        this.proc.kill();
      }

      async waitForExit() {
        return this.proc.exited;
      }
    }

    beforeEach(() => {
      enterTestDir = mkdtempSync(join(TEST_DIR, "enter-"));
    });

    afterEach(async () => {
      // Kill any active session
      if (activeSession) {
        activeSession.kill();
        await activeSession.waitForExit();
        activeSession = null;
      }
      if (enterTestDir && existsSync(enterTestDir)) {
        rmSync(enterTestDir, { recursive: true });
      }
    });

    test("enters and exits cleanly", async () => {
      const session = new TerminalSession(enterTestDir);

      // Wait for first shell prompt
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitFor("No changes made");

      await session.waitForExit();

      expect(session.output).toContain("No changes made");
    });

    test("creates file and shows in diff", async () => {
      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "test content" > ${enterTestDir}/newfile.txt\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      session.write("n\n");
      await session.waitForExit();

      expect(session.output).toContain("newfile.txt");
      expect(existsSync(join(enterTestDir, "newfile.txt"))).toBe(false);
    });

    test("applies changes when user confirms with y", async () => {
      const testFile = join(enterTestDir, "applied.txt");
      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "applied content" > ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("]: ");

      session.write("y\n");
      await session.waitFor("Changes applied");

      await session.waitForExit();

      expect(session.output).toContain("applied.txt");
      expect(existsSync(testFile)).toBe(true);
      expect(readFileSync(testFile, "utf-8").trim()).toBe("applied content");
    });

    test("discards changes when user declines", async () => {
      const testFile = join(enterTestDir, "discarded.txt");
      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "should not exist" > ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      session.write("n\n");
      await session.waitFor("Changes saved to");

      await session.waitForExit();

      expect(existsSync(testFile)).toBe(false);
    });

    test("shows diff when user presses d", async () => {
      const testFile = join(enterTestDir, "difftest.txt");
      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "diff line 1" > ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "diff line 2" >> ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      session.write("d\n");
      await session.waitFor("diff line 1");
      await session.waitForNew("[y/N]");

      session.write("n\n");
      await session.waitForExit();

      expect(existsSync(testFile)).toBe(false);
    });

    test("modifying existing file shows in diff", async () => {
      const testFile = join(enterTestDir, "modify-me.txt");
      writeFileSync(testFile, "original line\n");

      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "modified line" > ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      session.write("n\n");
      await session.waitFor("Changes saved to");

      await session.waitForExit();

      expect(session.output).toContain("modify-me.txt");
      expect(readFileSync(testFile, "utf-8")).toBe("original line\n");
    });

    test("no changes shows success message", async () => {
      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitFor("No changes made");

      await session.waitForExit();

      expect(session.output).toContain("No changes made");
    });

    test("deleted file shows in changed files list", async () => {
      const testFile = join(enterTestDir, "to-delete.txt");
      writeFileSync(testFile, "delete me\n");

      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`rm ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      // Should show the deleted file with - prefix (ANSI codes between - and filename)
      expect(session.output).toContain("to-delete.txt");
      expect(session.output).toContain("-\u001b[0m to-delete.txt");

      session.write("n\n");
      await session.waitForExit();

      // File should still exist on host (change was not applied)
      expect(existsSync(testFile)).toBe(true);
    });

    test("new empty directory shows in changed files list", async () => {
      const testDir = join(enterTestDir, "new-empty-dir");

      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`mkdir ${testDir}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      // Should show the new directory with + prefix and trailing / (ANSI codes between + and dirname)
      expect(session.output).toContain("new-empty-dir/");
      expect(session.output).toContain("+\u001b[0m new-empty-dir/");

      session.write("n\n");
      await session.waitForExit();

      // Directory should not exist on host
      expect(existsSync(testDir)).toBe(false);
    });

    test("uses $SHELL environment variable", async () => {
      const session = new TerminalSession(enterTestDir, { SHELL: "/bin/bash" });

      await session.waitForNew(SHELL_PROMPT);

      session.write("echo $0\n");
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitFor("No changes made");

      await session.waitForExit();

      expect(session.output).toContain("bash");
    });
  });
});
