import type { Plugin } from "@opencode-ai/plugin";

// Deliberately empty: tsc rejects an empty `include` outright, so the toolchain
// needs a real input before there is a plugin to write.
export const agentcomplete: Plugin = async () => ({});
