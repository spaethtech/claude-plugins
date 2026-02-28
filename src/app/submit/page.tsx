import Header from "@/components/Header";
import styles from "./page.module.css";

export default function SubmitPage() {
  return (
    <>
      <Header />
      <main className={styles.main}>
        <h1 className={styles.title}>Submit a Plugin</h1>
        <p className={styles.intro}>
          Share your Claude Code plugin with the community. Submissions are
          reviewed via pull request.
        </p>

        <section className={styles.section}>
          <h2>How to Submit</h2>
          <ol className={styles.steps}>
            <li>
              Fork the{" "}
              <a
                href="https://github.com/spaethtech/claude-plugins"
                target="_blank"
                rel="noopener noreferrer"
              >
                claude-plugins
              </a>{" "}
              repository
            </li>
            <li>
              Create a new directory under <code>plugins/</code> with your
              plugin&apos;s ID (kebab-case)
            </li>
            <li>
              Add a <code>plugin.json</code> file following the schema below
            </li>
            <li>Open a pull request with your submission</li>
          </ol>
        </section>

        <section className={styles.section}>
          <h2>Plugin Manifest Schema</h2>
          <p className={styles.schemaNote}>
            Each plugin must include a <code>plugin.json</code> that conforms to
            the schema. Here is a minimal example:
          </p>
          <pre className={styles.codeBlock}>
            {JSON.stringify(
              {
                id: "my-plugin",
                name: "My Plugin",
                summary: "A brief description of what this plugin does",
                description: "A longer description with details...",
                category: "mcp-server",
                author: { name: "Your Name", github: "your-github" },
                version: "1.0.0",
                license: "MIT",
                repository: "https://github.com/you/my-plugin",
                tags: ["example", "starter"],
                installation: "npm install -g my-plugin",
                dateAdded: "2026-02-28",
                dateUpdated: "2026-02-28",
                stars: 0,
                featured: false,
              },
              null,
              2
            )}
          </pre>
        </section>

        <section className={styles.section}>
          <h2>Plugin Categories</h2>
          <ul className={styles.categories}>
            <li>
              <strong>mcp-server</strong> — MCP (Model Context Protocol) servers
              that extend Claude&apos;s tool capabilities
            </li>
            <li>
              <strong>slash-command</strong> — Custom slash commands for Claude
              Code
            </li>
            <li>
              <strong>hook</strong> — Lifecycle hooks that run on Claude Code
              events
            </li>
            <li>
              <strong>custom-instructions</strong> — Reusable CLAUDE.md
              instruction sets
            </li>
            <li>
              <strong>toolkit</strong> — Bundles of multiple plugin types
            </li>
          </ul>
        </section>

        <section className={styles.section}>
          <h2>Guidelines</h2>
          <ul className={styles.guidelines}>
            <li>Plugins must be open source with a recognized license</li>
            <li>Include clear installation and configuration instructions</li>
            <li>
              Plugin IDs must be unique and use kebab-case (e.g.,{" "}
              <code>my-awesome-plugin</code>)
            </li>
            <li>
              Provide a valid repository URL where users can report issues
            </li>
            <li>Keep descriptions accurate and up to date</li>
          </ul>
        </section>
      </main>
    </>
  );
}
