import { useState, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { apiFetch } from "@/api/client";

const ENTITY_COLORS: Record<string, string> = {
  PERSON: "bg-blue-500", ADDRESS: "bg-red-500", BUSINESS: "bg-emerald-500",
  PROPERTY: "bg-amber-500", CASE: "bg-purple-500", VEHICLE: "bg-pink-500",
  CRIME_RECORD: "bg-red-700", SOCIAL_PROFILE: "bg-teal-500",
};

interface SearchResult {
  entity_id: string;
  entity_type: string;
  label: string;
  snippet: string | null;
  relevance_score: number;
}

interface SearchResponse {
  results: SearchResult[];
  total: number;
}

export default function SearchPage() {
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [searched, setSearched] = useState(false);

  const handleSearch = useCallback(async () => {
    if (!query.trim()) return;
    setLoading(true);
    setSearched(true);
    try {
      const data = await apiFetch<SearchResponse>("/api/v1/search", {
        method: "POST",
        body: JSON.stringify({ query: query.trim(), limit: 50 }),
      });
      setResults(data.results);
    } catch {
      setResults([]);
    }
    setLoading(false);
  }, [query]);

  // Also list saved investigations
  const [savedInvestigations, setSaved] = useState<any[]>([]);
  const [loadedSaved, setLoadedSaved] = useState(false);

  if (!loadedSaved) {
    setLoadedSaved(true);
    apiFetch<any[]>("/api/v1/saved-investigations")
      .then(setSaved)
      .catch(() => {});
  }

  return (
    <div className="mx-auto max-w-4xl px-4 py-8">
      <h2 className="mb-6 text-2xl font-bold">Search</h2>

      {/* Search bar */}
      <form
        onSubmit={(e) => { e.preventDefault(); handleSearch(); }}
        className="flex gap-2"
      >
        <input
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search people, businesses, cases, addresses..."
          className="flex-1 rounded-lg border border-gray-300 px-4 py-3 text-lg focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200 dark:border-gray-600 dark:bg-gray-800"
        />
        <button
          type="submit"
          disabled={loading}
          className="rounded-lg bg-blue-600 px-6 py-3 font-semibold text-white hover:bg-blue-700 disabled:opacity-50 dark:bg-blue-500"
        >
          {loading ? "..." : "Search"}
        </button>
      </form>

      {/* Results */}
      {searched && (
        <div className="mt-6">
          <p className="mb-3 text-sm text-gray-500 dark:text-gray-400">
            {results.length} result{results.length !== 1 ? "s" : ""} for "{query}"
          </p>
          {results.length === 0 ? (
            <p className="text-gray-400">No matching entities found</p>
          ) : (
            <div className="space-y-2">
              {results.map((r) => (
                <button
                  key={r.entity_id}
                  onClick={() => navigate(`/entity/${r.entity_id}`)}
                  className="flex w-full items-center gap-3 rounded-lg border border-gray-200 bg-white p-4 text-left transition-shadow hover:shadow-md dark:border-gray-700 dark:bg-gray-800"
                >
                  <span className={`inline-block h-3 w-3 rounded-full ${ENTITY_COLORS[r.entity_type] || "bg-gray-400"}`} />
                  <div className="min-w-0 flex-1">
                    <p className="font-medium">{r.label}</p>
                    <p className="text-xs text-gray-400">
                      {r.entity_type.replace(/_/g, " ")}
                      {r.relevance_score > 0 && ` \u00b7 Score: ${r.relevance_score.toFixed(1)}`}
                    </p>
                  </div>
                </button>
              ))}
            </div>
          )}
        </div>
      )}

      {/* Saved Investigations */}
      {savedInvestigations.length > 0 && (
        <div className="mt-10">
          <h3 className="mb-3 text-lg font-semibold">Saved Investigations</h3>
          <div className="space-y-2">
            {savedInvestigations.map((inv: any) => (
              <button
                key={inv.id}
                onClick={() => navigate(`/investigation/${inv.id}`)}
                className="flex w-full items-center justify-between rounded-lg border border-gray-200 bg-white p-4 text-left hover:shadow-md dark:border-gray-700 dark:bg-gray-800"
              >
                <div>
                  <p className="font-medium">{inv.name || inv.address}</p>
                  <p className="text-xs text-gray-400">
                    {inv.entity_count} entities &middot; {inv.status}
                  </p>
                </div>
                <span className="text-xs text-gray-400">
                  {new Date(inv.created_at).toLocaleDateString()}
                </span>
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
