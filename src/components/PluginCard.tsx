import type { Plugin } from "@/types/plugin";
import styles from "./PluginCard.module.css";

interface PluginCardProps {
  plugin: Plugin;
}

const categoryLabels: Record<string, string> = {
  "mcp-server": "MCP Server",
  "slash-command": "Slash Command",
  hook: "Hook",
  "custom-instructions": "Custom Instructions",
  toolkit: "Toolkit",
};

export default function PluginCard({ plugin }: PluginCardProps) {
  return (
    <a href={`/plugins/${plugin.id}`} className={styles.card}>
      <div className={styles.top}>
        <h3 className={styles.name}>{plugin.name}</h3>
        {plugin.featured && <span className={styles.featured}>Featured</span>}
      </div>
      <p className={styles.summary}>{plugin.summary}</p>
      <div className={styles.meta}>
        <span className={styles.category}>
          {categoryLabels[plugin.category] ?? plugin.category}
        </span>
        <span className={styles.author}>by {plugin.author.name}</span>
        <span className={styles.version}>v{plugin.version}</span>
      </div>
      <div className={styles.tags}>
        {plugin.tags.slice(0, 4).map((tag) => (
          <span key={tag} className={styles.tag}>
            {tag}
          </span>
        ))}
      </div>
    </a>
  );
}
