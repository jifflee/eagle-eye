import { Outlet, Link, useLocation } from "react-router-dom";
import { useAppStore } from "@/stores/appStore";

export default function Layout() {
  const { darkMode, toggleDarkMode } = useAppStore();
  const location = useLocation();

  const navLink = (to: string, label: string) => {
    const active = location.pathname === to;
    return (
      <Link
        to={to}
        className={`text-xs font-medium uppercase tracking-[0.15em] transition-colors ${
          active
            ? "text-blue-400"
            : "text-[#5a6578] hover:text-[#94a3b8]"
        }`}
      >
        {label}
      </Link>
    );
  };

  return (
    <div className="flex h-screen flex-col bg-[#f8fafc] text-[#1e293b] dark:bg-[#0a0e1a] dark:text-[#c8d1e0]">
      {/* Header — thin, dark, minimal */}
      <header className="flex h-11 shrink-0 items-center justify-between border-b border-[#e2e8f0] bg-white px-5 dark:border-[#1a2035] dark:bg-[#0d1224]">
        <Link to="/" className="flex items-center gap-2.5">
          <div className="flex h-6 w-6 items-center justify-center rounded-sm bg-blue-500/10">
            <svg className="h-3.5 w-3.5 text-blue-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
              <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" />
              <circle cx="12" cy="12" r="3" />
            </svg>
          </div>
          <span className="text-[11px] font-semibold uppercase tracking-[0.2em] text-[#475569] dark:text-[#64748b]">
            Eagle Eye
          </span>
        </Link>
        <nav className="flex items-center gap-5">
          {navLink("/", "Home")}
          {navLink("/search", "Search")}
          <div className="mx-1 h-4 w-px bg-[#e2e8f0] dark:bg-[#1e293b]" />
          <button
            onClick={toggleDarkMode}
            className="rounded p-1.5 text-[#64748b] transition-colors hover:bg-[#f1f5f9] hover:text-[#334155] dark:hover:bg-[#1a2035] dark:hover:text-[#94a3b8]"
            title={darkMode ? "Light mode" : "Dark mode"}
          >
            {darkMode ? (
              <svg className="h-3.5 w-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="12" cy="12" r="5" />
                <line x1="12" y1="1" x2="12" y2="3" /><line x1="12" y1="21" x2="12" y2="23" />
                <line x1="4.22" y1="4.22" x2="5.64" y2="5.64" /><line x1="18.36" y1="18.36" x2="19.78" y2="19.78" />
                <line x1="1" y1="12" x2="3" y2="12" /><line x1="21" y1="12" x2="23" y2="12" />
                <line x1="4.22" y1="19.78" x2="5.64" y2="18.36" /><line x1="18.36" y1="5.64" x2="19.78" y2="4.22" />
              </svg>
            ) : (
              <svg className="h-3.5 w-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
              </svg>
            )}
          </button>
        </nav>
      </header>
      <main className="flex-1 overflow-auto">
        <Outlet />
      </main>
    </div>
  );
}
