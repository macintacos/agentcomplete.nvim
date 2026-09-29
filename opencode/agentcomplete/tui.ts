// OpenCode hands its external editor no session id, so this records which session the TUI is
// showing, keyed by its pid — the editor's parent. It runs in the TUI because a plugin's server
// half runs in a daemon every TUI shares.

import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const stateHome = process.env.XDG_STATE_HOME || join(homedir(), ".local", "state");
const pointer = join(stateHome, "opencode", "agentcomplete", `${process.pid}.json`);
const staging = `${pointer}.tmp`;

// Declared locally: a directory symlinked into OpenCode's config has no package to resolve
// `@opencode/plugin` from.
type Route = { type: string; sessionID?: string };
type Context = { ui: { router: { current(): Route } } };

// Chained so two quick route changes cannot interleave their writes to the staging file.
let writes = Promise.resolve();

function record(sessionID: string | undefined) {
  writes = writes.then(async () => {
    try {
      await mkdir(dirname(pointer), { recursive: true });
      // Written then renamed, so the editor never reads half a record. A record without a
      // `sessionID` says the TUI is showing no session, which a missing file cannot.
      await writeFile(staging, JSON.stringify({ sessionID, ts: Date.now() }));
      await rename(staging, pointer);
    } catch {
      // A pointer that cannot be written must not take the TUI down with it.
    }
  });
}

function setup(context: Context) {
  let shown: string | undefined | null = null;
  const sync = () => {
    const route = context.ui.router.current();
    const sessionID = route.type === "session" ? route.sessionID : undefined;
    if (sessionID === shown) return;
    shown = sessionID;
    record(sessionID);
  };
  sync();
  const poll = setInterval(sync, 250);

  return async () => {
    clearInterval(poll);
    await writes;
    // The staging file too: nothing else in this directory ever collects one.
    await Promise.all([rm(pointer, { force: true }), rm(staging, { force: true })]).catch(() => {});
  };
}

export default { id: "agentcomplete", setup };
