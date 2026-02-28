"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { PLUGIN_CATEGORIES } from "@/types/plugin";
import styles from "./CategoryFilter.module.css";

export default function CategoryFilter() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const active = searchParams.get("category") ?? "";

  function handleClick(category: string) {
    const params = new URLSearchParams(searchParams.toString());
    if (category === active) {
      params.delete("category");
    } else {
      params.set("category", category);
    }
    router.push(`/?${params.toString()}`);
  }

  return (
    <div className={styles.filters}>
      <button
        className={`${styles.chip} ${active === "" ? styles.active : ""}`}
        onClick={() => handleClick("")}
      >
        All
      </button>
      {PLUGIN_CATEGORIES.map((cat) => (
        <button
          key={cat.value}
          className={`${styles.chip} ${active === cat.value ? styles.active : ""}`}
          onClick={() => handleClick(cat.value)}
        >
          {cat.label}
        </button>
      ))}
    </div>
  );
}
