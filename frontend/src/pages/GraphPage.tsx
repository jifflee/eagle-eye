import { useEffect, useState, useCallback } from "react";
import { useParams, Link } from "react-router-dom";
import { apiFetch } from "@/api/client";

interface ConnectorStatus {
  connector_name: string;
  tier: number;
  status: string;
  entities_found: number;
  error_message: string | null;
}

interface EnrichmentStatus {
  investigation_id: string;
  status: string;
  completed_sources: string[];
  in_progress_sources: string[];
  pending_sources: string[];
  failed_sources: string[];
  discovered_entities: number;
  connectors: ConnectorStatus[];
}

interface EntityNode {
  id: string;
  type: string;
  label: string;
  attributes: Record<string, unknown>;
}

interface RelEdge {
  source_id: string;
  target_id: string;
  type: string;
}

interface InvestigationData {
  id: string;
  address: string;
  status: string;
  graph: {
    entities: EntityNode[];
    relationships: RelEdge[];
  };
}

const STATUS_COLORS: Record<string, string> = {
  complete: "bg-green-500",
  running: "bg-blue-500 animate-pulse",
  pending: "bg-gray-300 dark:bg-gray-600",
  failed: "bg-red-500",
  rate_limited: "bg-yellow-500",
};

const ENTITY_COLORS: Record<string, string> = {
  PERSON: "bg-blue-500",
  ADDRESS: "bg-red-500",
  BUSINESS: "bg-emerald-500",
  PROPERTY: "bg-amber-500",
  CASE: "bg-purple-500",
  VEHICLE: "bg-pink-500",
  CRIME_RECORD: "bg-red-700",
  SOCIAL_PROFILE: "bg-teal-500",
  PHONE_NUMBER: "bg-gray-500",
  EMAIL_ADDRESS: "bg-gray-500",
  ENVIRONMENTAL_FACILITY: "bg-teal-700",
  CENSUS_TRACT: "bg-slate-500",
};

export default function GraphPage() {
  const { id } = useParams();
  const [investigation, setInvestigation] = useState<InvestigationData | null>(null);
  const [enrichment, setEnrichment] = useState<EnrichmentStatus | null>(null);
  const [polling, setPolling] = useState(true);
  const [error, setError] = useState("");

  // Fetch investigation data
  const fetchInvestigation = useCallback(async () => {
    if (!id) return;
    try {
      const data = await apiFetch<InvestigationData>(`/api/v1/investigation/${id}`);
      setInvestigation(data);

      // Cache locally
      try {
        localStorage.setItem(`eagle-eye-inv:${id}`, JSON.stringify({ data, timestamp: Date.now() }));
      } catch { /* full */ }
    } catch {
      // Try local cache
      const cached = localStorage.getItem(`eagle-eye-inv:${id}`);
      if (cached) {
        setInvestigation(JSON.parse(cached).data);
      } else {
        setError("Could not load investigation");
      }
    }
  }, [id]);

  // Poll enrichment status
  const fetchEnrichment = useCallback(async () => {
    if (!id) return;
    try {
      const data = await apiFetch<EnrichmentStatus>(`/api/v1/enrichment/status/${id}`);
      setEnrichment(data);
      if (data.status === "complete" || data.status === "failed") {
        setPolling(false);
      }
    } catch {
      // Enrichment endpoint not available
    }
  }, [id]);

  useEffect(() => {
    fetchInvestigation();
    fetchEnrichment();
  }, [fetchInvestigation, fetchEnrichment]);

  // Polling loop
  useEffect(() => {
    if (!polling) return;
    const interval = setInterval(() => {
      fetchInvestigation();
      fetchEnrichment();
    }, 3000);
    return () => clearInterval(interval);
  }, [polling, fetchInvestigation, fetchEnrichment]);

  // Progress calculation
  const totalConnectors = enrichment?.connectors?.length || 0;
  const completedConnectors = enrichment?.completed_sources?.length || 0;
  const progressPct = totalConnectors > 0 ? Math.round((completedConnectors / totalConnectors) * 100) : 0;
  const isEnriching = enrichment?.status === "enriching" || enrichment?.status === "initializing";

  // Entity counts by type
  const entityCounts: Record<string, number> = {};
  (investigation?.graph?.entities || []).forEach((e) => {
    entityCounts[e.type] = (entityCounts[e.type] || 0) + 1;
  });

  return (
    <div className="flex h-full flex-col">
      {/* === Top Bar === */}
      <div className="shrink-0 border-b border-gray-200 bg-white px-6 py-3 dark:border-gray-800 dark:bg-gray-900">
        <div className="flex items-center justify-between">
          <div>
            <Link to="/" className="text-xs text-gray-400 hover:text-gray-600 dark:hover:text-gray-300">
              &larr; Back
            </Link>
            <h2 className="text-lg font-semibold">
              {investigation?.address || "Loading..."}
            </h2>
          </div>
          <div className="flex items-center gap-3">
            <span className="text-sm text-gray-500 dark:text-gray-400">
              {investigation?.graph?.entities?.length || 0} entities
            </span>
            <span className={`rounded-full px-3 py-1 text-xs font-medium ${
              isEnriching
                ? "bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300"
                : enrichment?.status === "complete"
                  ? "bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300"
                  : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
            }`}>
              {isEnriching ? "Enriching..." : enrichment?.status || investigation?.status || "Loading"}
            </span>
          </div>
        </div>

        {/* === Progress Bar === */}
        {totalConnectors > 0 && (
          <div className="mt-2">
            <div className="flex items-center justify-between text-xs text-gray-500 dark:text-gray-400">
              <span>{completedConnectors} / {totalConnectors} sources</span>
              <span>{progressPct}%</span>
            </div>
            <div className="mt-1 h-2 overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700">
              <div
                className="h-full rounded-full bg-blue-500 transition-all duration-500"
                style={{ width: `${progressPct}%` }}
              />
            </div>
          </div>
        )}
      </div>

      {/* === Main Content === */}
      <div className="flex flex-1 overflow-hidden">
        {/* Graph Area */}
        <div className="flex-1 overflow-auto p-6">
          {error && (
            <div className="mb-4 rounded-lg border border-red-200 bg-red-50 p-4 text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-400">
              {error}
            </div>
          )}

          {/* Entity grid — live updating as data arrives */}
          {(investigation?.graph?.entities?.length || 0) > 0 ? (
            <div>
              {/* Entity type summary chips */}
              <div className="mb-4 flex flex-wrap gap-2">
                {Object.entries(entityCounts).map(([type, count]) => (
                  <span
                    key={type}
                    className="inline-flex items-center gap-1.5 rounded-full bg-gray-100 px-3 py-1 text-xs font-medium dark:bg-gray-800"
                  >
                    <span className={`inline-block h-2 w-2 rounded-full ${ENTITY_COLORS[type] || "bg-gray-400"}`} />
                    {type.replace("_", " ")} ({count})
                  </span>
                ))}
              </div>

              {/* Entity cards */}
              <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
                {investigation!.graph.entities.map((entity) => (
                  <div
                    key={entity.id}
                    className="rounded-lg border border-gray-200 bg-white p-4 shadow-sm transition-shadow hover:shadow-md dark:border-gray-700 dark:bg-gray-800"
                  >
                    <div className="mb-2 flex items-center gap-2">
                      <span className={`inline-block h-3 w-3 rounded-full ${ENTITY_COLORS[entity.type] || "bg-gray-400"}`} />
                      <span className="text-xs font-medium uppercase tracking-wider text-gray-400">
                        {entity.type.replace("_", " ")}
                      </span>
                    </div>
                    <p className="font-semibold">{entity.label}</p>
                    {/* Show key attributes */}
                    <div className="mt-2 space-y-0.5">
                      {Object.entries(entity.attributes)
                        .filter(([k]) => !["id", "type", "created_at", "updated_at", "entity_type"].includes(k))
                        .slice(0, 4)
                        .map(([key, value]) => (
                          <p key={key} className="text-xs text-gray-500 dark:text-gray-400">
                            <span className="font-medium">{key}:</span>{" "}
                            {String(value)}
                          </p>
                        ))}
                    </div>
                  </div>
                ))}
              </div>

              {/* Relationships */}
              {(investigation!.graph.relationships?.length || 0) > 0 && (
                <div className="mt-6">
                  <h3 className="mb-2 text-sm font-medium text-gray-500 dark:text-gray-400">
                    Relationships ({investigation!.graph.relationships.length})
                  </h3>
                  <div className="space-y-1">
                    {investigation!.graph.relationships.slice(0, 20).map((rel, i) => (
                      <div key={i} className="flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                        <span className="font-mono">{String(rel.source_id).slice(0, 8)}</span>
                        <span className="rounded bg-gray-100 px-2 py-0.5 font-medium dark:bg-gray-700">
                          {rel.type}
                        </span>
                        <span className="font-mono">{String(rel.target_id).slice(0, 8)}</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          ) : (
            <div className="flex h-full items-center justify-center">
              {isEnriching ? (
                <div className="text-center">
                  <svg className="mx-auto h-12 w-12 animate-spin text-blue-500" viewBox="0 0 24 24" fill="none">
                    <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" className="opacity-25" />
                    <path fill="currentColor" d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z" className="opacity-75" />
                  </svg>
                  <p className="mt-4 text-gray-500 dark:text-gray-400">
                    Querying data sources...
                  </p>
                </div>
              ) : (
                <p className="text-gray-400">No data yet</p>
              )}
            </div>
          )}
        </div>

        {/* === Right Sidebar: Connector Status === */}
        <div className="w-72 shrink-0 overflow-auto border-l border-gray-200 bg-white p-4 dark:border-gray-800 dark:bg-gray-900">
          <h3 className="mb-3 text-sm font-semibold uppercase tracking-wider text-gray-400">
            Data Sources
          </h3>
          <div className="space-y-1.5">
            {(enrichment?.connectors || []).map((c) => (
              <div
                key={c.connector_name}
                className="flex items-center justify-between rounded-md px-2 py-1.5 text-sm hover:bg-gray-50 dark:hover:bg-gray-800"
              >
                <div className="flex items-center gap-2">
                  <span className={`inline-block h-2 w-2 rounded-full ${STATUS_COLORS[c.status] || "bg-gray-300"}`} />
                  <span className="truncate text-xs">{c.connector_name}</span>
                </div>
                <div className="flex items-center gap-1">
                  {c.entities_found > 0 && (
                    <span className="text-xs text-gray-400">{c.entities_found}</span>
                  )}
                  {c.status === "failed" && (
                    <button
                      onClick={async () => {
                        await apiFetch(`/api/v1/investigation/${id}/source/${c.connector_name}/retry`, { method: "POST" });
                        fetchEnrichment();
                      }}
                      className="text-xs text-blue-500 hover:text-blue-700"
                      title={c.error_message || "Retry"}
                    >
                      retry
                    </button>
                  )}
                </div>
              </div>
            ))}

            {(enrichment?.connectors?.length || 0) === 0 && (
              <p className="text-xs text-gray-400">Waiting for enrichment to start...</p>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
