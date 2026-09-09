// OpenCode hands its external editor a pid but no session id, and persists no
// pid→session mapping of its own — hence this pointer file.

import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { Plugin } from "@opencode-ai/plugin";

const stateHome = process.env.XDG_STATE_HOME || join(homedir(), ".local", "state");
const pointer = join(stateHome, "opencode", "agentcomplete", `${process.pid}.json`);

// Which process the plugin runs in — TUI, instance-server child, shared daemon —
// varies, so record every pid the reader could plausibly hold.
const pids = [process.pid, process.ppid, Number(process.env.OPENCODE_PID)].filter(Number.isFinite);

export const agentcomplete: Plugin = async ({ worktree }) => ({
  event: async ({ event }) => {
    if (event.type !== "session.created" && event.type !== "session.updated") return;
    const info = event.properties.info;
    if (info.parentID) return;

    try {
      await mkdir(dirname(pointer), { recursive: true });
      // Written then renamed: `session.updated` fires throughout a conversation, so a reader
      // landing inside a plain truncate-and-write would see half a record often enough to matter.
      const staging = `${pointer}.tmp`;
      await writeFile(
        staging,
        // `info.directory`, not the plugin's own: one server can hold sessions in several
        // directories, and the reader matches on this to know the record is for its project.
        JSON.stringify({
          pids,
          sessionID: info.id,
          directory: info.directory,
          worktree,
          ts: Date.now(),
        }),
      );
      await rename(staging, pointer);
    } catch {
      // A pointer that cannot be written must not take the session down with it.
    }
  },

  dispose: async () => {
    try {
      await rm(pointer, { force: true });
    } catch {
      // As above: a stale pointer is recoverable, a throwing teardown is not.
    }
  },
});
