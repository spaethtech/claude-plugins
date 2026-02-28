import styles from "./Header.module.css";

export default function Header() {
  return (
    <header className={styles.header}>
      <div className={styles.inner}>
        <a href="/" className={styles.logo}>
          <span className={styles.logoIcon}>{">"}_</span>
          <span>Claude Plugins</span>
        </a>
        <nav className={styles.nav}>
          <a href="/">Browse</a>
          <a href="/submit">Submit a Plugin</a>
          <a
            href="https://docs.anthropic.com/en/docs/claude-code"
            target="_blank"
            rel="noopener noreferrer"
          >
            Docs
          </a>
        </nav>
      </div>
    </header>
  );
}
