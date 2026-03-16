import { Outlet, Link } from "react-router-dom";

export default function Layout() {
  return (
    <div className="flex h-screen flex-col">
      <header className="flex h-14 items-center justify-between border-b border-gray-200 bg-white px-6 dark:border-gray-800 dark:bg-gray-900">
        <Link to="/" className="flex items-center gap-2 text-lg font-semibold">
          <span className="text-2xl">🦅</span>
          <span>Eagle Eye</span>
        </Link>
        <nav className="flex items-center gap-4">
          <Link
            to="/"
            className="text-sm text-gray-600 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"
          >
            Home
          </Link>
          <Link
            to="/search"
            className="text-sm text-gray-600 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"
          >
            Search
          </Link>
        </nav>
      </header>
      <main className="flex-1 overflow-auto">
        <Outlet />
      </main>
    </div>
  );
}
