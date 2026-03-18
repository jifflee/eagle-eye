import { useEffect, useState, useCallback, useMemo } from "react";
import { useParams, Link } from "react-router-dom";
import { apiFetch } from "@/api/client";
import GraphVisualization, { type GraphNode, type GraphEdge } from "@/components/Graph/GraphVisualization";
import GraphFilters from "@/components/Graph/GraphFilters";
import EntityDetailPanel from "@/components/Entity/EntityDetailPanel";

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

interface InvestigationData {
  id: string;
  address: string;
  status: string;
  graph: { entities: GraphNode[]; relationships: GraphEdge[] };
}

const STATUS_DOT: Record<string, string> = {
  complete: "bg-green-500",
  running: "bg-blue-500 animate-pulse",
  pending: "bg-gray-300 dark:bg-gray-600",
  failed: "bg-red-500",
  rate_limited: "bg-yellow-500",
};

export default function GraphPage() {
  const { id } = useParams();
  const [investigation, setInvestigation] = useState<InvestigationData | null>(null);
  const [enrichment, setEnrichment] = useState<EnrichmentStatus | null>(null);
  const [polling, setPolling] = useState(true);
  const [selectedEntity, setSelectedEntity] = useState<GraphNode | null>(null);
  const [activeTypes, setActiveTypes] = useState<Set<string>>(new Set());
  const [allTypesInit, setAllTypesInit] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");

  // Fetch data
  const fetchData = useCallback(async () => {
    if (!id) return;
    try {
      const [inv, enr] = await Promise.all([
        apiFetch<InvestigationData>(`/api/v1/investigation/${id}`),
        apiFetch<EnrichmentStatus>(`/api/v1/enrichment/status/${id}`),
      ]);
      setInvestigation(inv);
      setEnrichment(enr);

      // Initialize active types filter with all found types
      if (!allTypesInit && inv.graph.entities.length > 0) {
        const types = new Set(inv.graph.entities.map((e) => e.type));
        setActiveTypes(types);
        setAllTypesInit(true);
      }

      if (enr.status === "complete" || enr.status === "failed") {
        setPolling(false);
      }

      // Cache locally
      try {
        localStorage.setItem(`eagle-eye-inv:${id}`, JSON.stringify({ data: inv, timestamp: Date.now() }));
      } catch { /* full */ }
    } catch {
      // Try local cache first
      const cached = localStorage.getItem(`eagle-eye-inv:${id}`);
      if (cached) {
        setInvestigation(JSON.parse(cached).data);
      } else if (id === "demo") {
        // Offline demo data for testing graph visualization
        setInvestigation(DEMO_INVESTIGATION);
        setPolling(false);
      }
    }
  }, [id, allTypesInit]);

  useEffect(() => { fetchData(); }, [fetchData]);

  useEffect(() => {
    if (!polling) return;
    const interval = setInterval(fetchData, 3000);
    return () => clearInterval(interval);
  }, [polling, fetchData]);

  // Computed
  const entities = investigation?.graph?.entities || [];
  const relationships = investigation?.graph?.relationships || [];
  const totalConnectors = enrichment?.connectors?.length || 0;
  const completedConnectors = enrichment?.completed_sources?.length || 0;
  const progressPct = totalConnectors > 0 ? Math.round((completedConnectors / totalConnectors) * 100) : 0;
  const isEnriching = enrichment?.status === "enriching" || enrichment?.status === "initializing";

  const entityCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    entities.forEach((e) => { counts[e.type] = (counts[e.type] || 0) + 1; });
    return counts;
  }, [entities]);

  // Search filter
  const filteredEntities = useMemo(() => {
    if (!searchQuery.trim()) return entities;
    const q = searchQuery.toLowerCase();
    return entities.filter((e) =>
      e.label.toLowerCase().includes(q) ||
      e.type.toLowerCase().includes(q) ||
      Object.values(e.attributes || {}).some((v) => String(v).toLowerCase().includes(q))
    );
  }, [entities, searchQuery]);

  const handleToggleType = (type: string) => {
    setActiveTypes((prev) => {
      const next = new Set(prev);
      if (next.has(type)) next.delete(type); else next.add(type);
      return next;
    });
  };

  const handleExpand = async (entityId: string) => {
    try {
      const result = await apiFetch<{ entities: GraphNode[]; relationships: GraphEdge[] }>(
        `/api/v1/entity/${entityId}/expand`, { method: "POST" }
      );
      if (result.entities.length > 0) fetchData();
    } catch { /* ignore */ }
  };

  const handleNodeClick = (node: GraphNode) => {
    setSelectedEntity(node);
  };

  return (
    <div className="flex h-full flex-col">
      {/* Top Bar */}
      <div className="shrink-0 border-b border-gray-200 bg-white px-4 py-2 dark:border-gray-800 dark:bg-gray-900">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <Link to="/" className="text-gray-400 hover:text-gray-600 dark:hover:text-gray-300">
              <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <polyline points="15 18 9 12 15 6" />
              </svg>
            </Link>
            <div>
              <h2 className="text-sm font-semibold">{investigation?.address || "Loading..."}</h2>
              <p className="text-xs text-gray-400">
                {entities.length} entities &middot; {relationships.length} relationships
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            {/* Search */}
            <div className="relative">
              <input
                type="text"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search entities..."
                className="w-48 rounded-md border border-gray-200 bg-gray-50 px-3 py-1 text-xs focus:border-blue-400 focus:outline-none dark:border-gray-700 dark:bg-gray-800"
              />
              {searchQuery && (
                <span className="absolute right-2 top-1 text-[10px] text-gray-400">
                  {filteredEntities.length} found
                </span>
              )}
            </div>
            <span className={`rounded-full px-2 py-0.5 text-[10px] font-medium ${
              isEnriching ? "bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300"
                : enrichment?.status === "complete" ? "bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300"
                : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
            }`}>
              {isEnriching ? "Enriching..." : enrichment?.status || "Loading"}
            </span>
          </div>
        </div>

        {/* Progress Bar */}
        {totalConnectors > 0 && isEnriching && (
          <div className="mt-1.5">
            <div className="h-1 overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700">
              <div className="h-full rounded-full bg-blue-500 transition-all duration-500" style={{ width: `${progressPct}%` }} />
            </div>
          </div>
        )}
      </div>

      {/* Main area */}
      <div className="flex flex-1 overflow-hidden">
        {/* Graph */}
        <div className="relative flex-1">
          <GraphVisualization
            entities={searchQuery ? filteredEntities : entities}
            relationships={relationships}
            onNodeClick={handleNodeClick}
            onNodeDoubleClick={handleExpand}
            selectedNodeId={selectedEntity?.id}
            filterTypes={activeTypes.size > 0 ? activeTypes : undefined}
          />
          <GraphFilters
            entityCounts={entityCounts}
            activeTypes={activeTypes}
            onToggle={handleToggleType}
            onShowAll={() => setActiveTypes(new Set(Object.keys(entityCounts)))}
            onHideAll={() => setActiveTypes(new Set())}
          />
        </div>

        {/* Entity Detail Panel */}
        {selectedEntity && (
          <EntityDetailPanel
            entity={selectedEntity}
            relationships={relationships}
            allEntities={entities}
            onClose={() => setSelectedEntity(null)}
            onNavigate={(id) => {
              const target = entities.find((e) => e.id === id);
              if (target) setSelectedEntity(target);
            }}
            onExpand={handleExpand}
          />
        )}

        {/* Connector Sidebar (collapsed when entity panel is open) */}
        {!selectedEntity && (
          <div className="w-56 shrink-0 overflow-auto border-l border-gray-200 bg-white p-3 dark:border-gray-800 dark:bg-gray-900">
            <h3 className="mb-2 text-[10px] font-semibold uppercase tracking-wider text-gray-400">
              Data Sources
            </h3>
            <div className="space-y-0.5">
              {(enrichment?.connectors || []).map((c) => (
                <div key={c.connector_name} className="flex items-center justify-between py-1 text-xs">
                  <div className="flex items-center gap-1.5">
                    <span className={`inline-block h-1.5 w-1.5 rounded-full ${STATUS_DOT[c.status] || "bg-gray-300"}`} />
                    <span className="truncate">{c.connector_name.replace(/_/g, " ")}</span>
                  </div>
                  {c.entities_found > 0 && (
                    <span className="text-[10px] text-gray-400">{c.entities_found}</span>
                  )}
                  {c.status === "failed" && (
                    <button
                      onClick={async () => {
                        await apiFetch(`/api/v1/investigation/${id}/source/${c.connector_name}/retry`, { method: "POST" });
                        fetchData();
                      }}
                      className="text-[10px] text-blue-500 hover:text-blue-700"
                    >
                      retry
                    </button>
                  )}
                </div>
              ))}
              {(enrichment?.connectors?.length || 0) === 0 && (
                <p className="text-[10px] text-gray-400">Waiting for enrichment...</p>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// Demo data for offline testing of graph visualization
const DEMO_INVESTIGATION: InvestigationData = {
  id: "demo",
  address: "123 Peachtree Lane, Lawrenceville, GA 30043",
  status: "complete",
  graph: {
    entities: [
      { id: "addr-1", type: "ADDRESS", label: "123 Peachtree Ln, Lawrenceville GA", attributes: { street: "123 Peachtree Lane", city: "Lawrenceville", state: "GA", zip: "30043" } },
      { id: "person-1", type: "PERSON", label: "John Smith", attributes: { full_name: "John Smith", gender: "male" } },
      { id: "person-2", type: "PERSON", label: "Jane Smith", attributes: { full_name: "Jane Smith", gender: "female" } },
      { id: "person-3", type: "PERSON", label: "Robert Johnson", attributes: { full_name: "Robert Johnson" } },
      { id: "biz-1", type: "BUSINESS", label: "Smith Consulting LLC", attributes: { name: "Smith Consulting LLC", entity_type_business: "LLC", status: "active" } },
      { id: "prop-1", type: "PROPERTY", label: "Parcel R5001-123", attributes: { apn: "R5001-123", assessed_value: 350000, year_built: 2005, square_footage: 2400 } },
      { id: "case-1", type: "CASE", label: "2023-CV-12345", attributes: { case_number: "2023-CV-12345", court_name: "Gwinnett County Superior Court", case_type: "civil", disposition: "dismissed" } },
      { id: "tract-1", type: "CENSUS_TRACT", label: "Tract 0507.03", attributes: { tract_number: "0507.03", population: 5420, median_income: 78500 } },
      { id: "env-1", type: "ENVIRONMENTAL_FACILITY", label: "Water Treatment Plant", attributes: { facility_name: "Gwinnett County Water Treatment", compliance_status: "In Compliance" } },
      { id: "vehicle-1", type: "VEHICLE", label: "2023 Honda Accord", attributes: { make: "Honda", model: "Accord", year: 2023, color: "Silver" } },
    ],
    relationships: [
      { source_id: "person-1", target_id: "addr-1", type: "LIVES_AT" },
      { source_id: "person-2", target_id: "addr-1", type: "LIVES_AT" },
      { source_id: "person-1", target_id: "person-2", type: "IS_RELATIVE_OF" },
      { source_id: "person-1", target_id: "biz-1", type: "OWNS_BUSINESS" },
      { source_id: "person-1", target_id: "prop-1", type: "OWNS_PROPERTY" },
      { source_id: "person-2", target_id: "prop-1", type: "OWNS_PROPERTY" },
      { source_id: "biz-1", target_id: "addr-1", type: "LOCATED_AT" },
      { source_id: "person-3", target_id: "case-1", type: "NAMED_IN_CASE" },
      { source_id: "biz-1", target_id: "case-1", type: "NAMED_IN_CASE" },
      { source_id: "person-1", target_id: "vehicle-1", type: "REGISTERED_VEHICLE" },
      { source_id: "addr-1", target_id: "tract-1", type: "IN_CENSUS_TRACT" },
      { source_id: "addr-1", target_id: "env-1", type: "HAS_ENV_FACILITY" },
      { source_id: "person-3", target_id: "addr-1", type: "LIVES_AT" },
    ],
  },
};
