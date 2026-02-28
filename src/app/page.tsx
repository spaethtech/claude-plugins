import { Suspense } from "react";
import Header from "@/components/Header";
import SearchBar from "@/components/SearchBar";
import CategoryFilter from "@/components/CategoryFilter";
import PluginCard from "@/components/PluginCard";
import { loadAllPlugins, searchPlugins, getPluginsByCategory } from "@/lib/registry";
import type { PluginCategory } from "@/types/plugin";
import styles from "./page.module.css";

interface PageProps {
  searchParams: Promise<{ q?: string; category?: string }>;
}

export default async function HomePage({ searchParams }: PageProps) {
  const params = await searchParams;
  const query = params.q ?? "";
  const category = params.category ?? "";

  let plugins = query
    ? searchPlugins(query)
    : category
      ? getPluginsByCategory(category as PluginCategory)
      : loadAllPlugins();

  const featuredPlugins = plugins.filter((p) => p.featured);
  const regularPlugins = plugins.filter((p) => !p.featured);

  return (
    <>
      <Header />
      <main className={styles.main}>
        <section className={styles.hero}>
          <h1 className={styles.title}>Claude Code Plugins</h1>
          <p className={styles.subtitle}>
            Discover and install plugins to supercharge your Claude Code
            workflow — MCP servers, slash commands, hooks, and more.
          </p>
          <Suspense>
            <SearchBar />
          </Suspense>
        </section>

        <section className={styles.content}>
          <Suspense>
            <CategoryFilter />
          </Suspense>

          {featuredPlugins.length > 0 && (
            <div className={styles.section}>
              <h2 className={styles.sectionTitle}>Featured</h2>
              <div className={styles.grid}>
                {featuredPlugins.map((plugin) => (
                  <PluginCard key={plugin.id} plugin={plugin} />
                ))}
              </div>
            </div>
          )}

          <div className={styles.section}>
            <h2 className={styles.sectionTitle}>
              {query
                ? `Results for "${query}"`
                : category
                  ? `${category} plugins`
                  : "All Plugins"}
            </h2>
            {regularPlugins.length === 0 && featuredPlugins.length === 0 ? (
              <p className={styles.empty}>
                No plugins found. {query && "Try a different search term."}
              </p>
            ) : (
              <div className={styles.grid}>
                {regularPlugins.map((plugin) => (
                  <PluginCard key={plugin.id} plugin={plugin} />
                ))}
              </div>
            )}
          </div>
        </section>
      </main>
    </>
  );
}
