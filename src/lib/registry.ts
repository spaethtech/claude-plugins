import path from "node:path";
import fs from "node:fs";
import type { Plugin, PluginCategory, PluginRegistry } from "@/types/plugin";

const PLUGINS_DIR = path.join(process.cwd(), "plugins");

/** Load a single plugin manifest from disk */
function loadPlugin(dir: string): Plugin | null {
  const manifestPath = path.join(dir, "plugin.json");
  if (!fs.existsSync(manifestPath)) return null;
  const raw = fs.readFileSync(manifestPath, "utf-8");
  return JSON.parse(raw) as Plugin;
}

/** Load all plugins from the plugins/ directory */
export function loadAllPlugins(): Plugin[] {
  if (!fs.existsSync(PLUGINS_DIR)) return [];
  const entries = fs.readdirSync(PLUGINS_DIR, { withFileTypes: true });
  const plugins: Plugin[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const plugin = loadPlugin(path.join(PLUGINS_DIR, entry.name));
    if (plugin) plugins.push(plugin);
  }
  return plugins.sort(
    (a, b) =>
      new Date(b.dateUpdated).getTime() - new Date(a.dateUpdated).getTime()
  );
}

/** Get the full registry object */
export function getRegistry(): PluginRegistry {
  const plugins = loadAllPlugins();
  return {
    version: "1.0.0",
    lastUpdated: new Date().toISOString(),
    plugins,
  };
}

/** Get a single plugin by ID */
export function getPluginById(id: string): Plugin | null {
  return loadAllPlugins().find((p) => p.id === id) ?? null;
}

/** Get plugins filtered by category */
export function getPluginsByCategory(category: PluginCategory): Plugin[] {
  return loadAllPlugins().filter((p) => p.category === category);
}

/** Search plugins by query string (matches name, summary, tags) */
export function searchPlugins(query: string): Plugin[] {
  const q = query.toLowerCase();
  return loadAllPlugins().filter(
    (p) =>
      p.name.toLowerCase().includes(q) ||
      p.summary.toLowerCase().includes(q) ||
      p.tags.some((t) => t.toLowerCase().includes(q))
  );
}
