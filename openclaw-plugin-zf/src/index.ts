import { spawnSync } from "node:child_process";
import type { OpenClawPluginApi } from "openclaw/plugin-sdk/core";

export function register(api: OpenClawPluginApi) {
  api.registerCommand({
    name: "zf",
    description: "Run zf with the given arguments",
    acceptsArgs: true,
    requireAuth: true,
    handler: (ctx) => {
      const rawArgs = ctx.args?.trim() ?? "";
      const result = spawnSync("sh", ["-c", `zf -c "${rawArgs}"`], {
        encoding: "utf-8",
        timeout: 10_000,
      });
      if (result.error) {
        return { text: `❌ 起動エラー: ${result.error.message}` };
      }
      const output = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
      const ok = (result.status ?? -1) === 0;
      const header = ok ? "✅ zf" : `⚠️ zf (exit ${result.status})`;
      return { text: output ? `${header}\n\`\`\`\n${output}\n\`\`\`` : `${header} (no output)` };
    },
  });
}

export default { register };
