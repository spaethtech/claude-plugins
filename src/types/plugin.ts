/** The category of functionality a plugin provides */
export type PluginCategory =
  | "mcp-server"
  | "slash-command"
  | "hook"
  | "custom-instructions"
  | "toolkit";

/** A plugin listing in the marketplace */
export interface Plugin {
  /** Unique identifier (kebab-case) */
  id: string;
  /** Display name */
  name: string;
  /** Short one-line description */
  summary: string;
  /** Longer description with details (markdown) */
  description: string;
  /** Plugin category */
  category: PluginCategory;
  /** Author information */
  author: {
    name: string;
    github?: string;
    url?: string;
  };
  /** Version (semver) */
  version: string;
  /** License identifier (SPDX) */
  license: string;
  /** Source repository URL */
  repository: string;
  /** Tags for search/filtering */
  tags: string[];
  /** Installation instructions (markdown) */
  installation: string;
  /** Configuration snippet (JSON) for CLAUDE.md or settings */
  configSnippet?: string;
  /** Minimum Claude Code version required */
  minClaudeCodeVersion?: string;
  /** Date the plugin was added (ISO 8601) */
  dateAdded: string;
  /** Date the plugin was last updated (ISO 8601) */
  dateUpdated: string;
  /** Number of installs / stars (community metric) */
  stars: number;
  /** Whether the plugin is verified/featured */
  featured: boolean;
}

/** The full plugin registry */
export interface PluginRegistry {
  version: string;
  lastUpdated: string;
  plugins: Plugin[];
}

/** All possible category values for iteration */
export const PLUGIN_CATEGORIES: { value: PluginCategory; label: string }[] = [
  { value: "mcp-server", label: "MCP Servers" },
  { value: "slash-command", label: "Slash Commands" },
  { value: "hook", label: "Hooks" },
  { value: "custom-instructions", label: "Custom Instructions" },
  { value: "toolkit", label: "Toolkits" },
];
