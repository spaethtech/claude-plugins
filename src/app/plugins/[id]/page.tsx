import { notFound } from "next/navigation";
import Header from "@/components/Header";
import { getPluginById, loadAllPlugins } from "@/lib/registry";
import styles from "./page.module.css";

interface PageProps {
  params: Promise<{ id: string }>;
}

export async function generateStaticParams() {
  const plugins = loadAllPlugins();
  return plugins.map((p) => ({ id: p.id }));
}

const categoryLabels: Record<string, string> = {
  "mcp-server": "MCP Server",
  "slash-command": "Slash Command",
  hook: "Hook",
  "custom-instructions": "Custom Instructions",
  toolkit: "Toolkit",
};

export default async function PluginDetailPage({ params }: PageProps) {
  const { id } = await params;
  const plugin = getPluginById(id);
  if (!plugin) notFound();

  return (
    <>
      <Header />
      <main className={styles.main}>
        <div className={styles.header}>
          <div>
            <div className={styles.titleRow}>
              <h1 className={styles.title}>{plugin.name}</h1>
              {plugin.featured && (
                <span className={styles.featured}>Featured</span>
              )}
            </div>
            <p className={styles.summary}>{plugin.summary}</p>
            <div className={styles.meta}>
              <span className={styles.category}>
                {categoryLabels[plugin.category] ?? plugin.category}
              </span>
              <span>
                by{" "}
                {plugin.author.github ? (
                  <a
                    href={`https://github.com/${plugin.author.github}`}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    {plugin.author.name}
                  </a>
                ) : (
                  plugin.author.name
                )}
              </span>
              <span>v{plugin.version}</span>
              <span>{plugin.license}</span>
            </div>
          </div>
          <div className={styles.actions}>
            <a
              href={plugin.repository}
              target="_blank"
              rel="noopener noreferrer"
              className={styles.repoButton}
            >
              View Repository
            </a>
          </div>
        </div>

        <div className={styles.body}>
          <section className={styles.section}>
            <h2>About</h2>
            <div className={styles.description}>{plugin.description}</div>
          </section>

          <section className={styles.section}>
            <h2>Installation</h2>
            <pre className={styles.codeBlock}>{plugin.installation}</pre>
          </section>

          {plugin.configSnippet && (
            <section className={styles.section}>
              <h2>Configuration</h2>
              <pre className={styles.codeBlock}>{plugin.configSnippet}</pre>
            </section>
          )}

          <section className={styles.section}>
            <h2>Tags</h2>
            <div className={styles.tags}>
              {plugin.tags.map((tag) => (
                <span key={tag} className={styles.tag}>
                  {tag}
                </span>
              ))}
            </div>
          </section>

          <section className={styles.section}>
            <h2>Details</h2>
            <dl className={styles.details}>
              <dt>Version</dt>
              <dd>{plugin.version}</dd>
              <dt>License</dt>
              <dd>{plugin.license}</dd>
              <dt>Added</dt>
              <dd>{plugin.dateAdded}</dd>
              <dt>Updated</dt>
              <dd>{plugin.dateUpdated}</dd>
              {plugin.minClaudeCodeVersion && (
                <>
                  <dt>Min Claude Code</dt>
                  <dd>{plugin.minClaudeCodeVersion}</dd>
                </>
              )}
            </dl>
          </section>
        </div>
      </main>
    </>
  );
}
