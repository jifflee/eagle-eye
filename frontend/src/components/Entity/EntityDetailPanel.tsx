import { useState } from "react";
import type { GraphNode } from "@/components/Graph/GraphVisualization";

const ENTITY_COLORS: Record<string, string> = {
  PERSON: "bg-blue-500", ADDRESS: "bg-red-500", BUSINESS: "bg-emerald-500",
  PROPERTY: "bg-amber-500", CASE: "bg-purple-500", VEHICLE: "bg-pink-500",
  CRIME_RECORD: "bg-red-700", SOCIAL_PROFILE: "bg-teal-500",
  PHONE_NUMBER: "bg-gray-500", EMAIL_ADDRESS: "bg-gray-500",
  ENVIRONMENTAL_FACILITY: "bg-teal-700", CENSUS_TRACT: "bg-slate-500",
};

const SKIP_ATTRS = new Set(["id", "type", "entity_type", "created_at", "updated_at", "_labels"]);

interface Props {
  entity: GraphNode;
  relationships: { source_id: string; target_id: string; type: string }[];
  allEntities: GraphNode[];
  onClose: () => void;
  onNavigate: (entityId: string) => void;
  onExpand: (entityId: string) => void;
}

type Tab = "overview" | "relationships" | "sources";

export default function EntityDetailPanel({
  entity, relationships, allEntities, onClose, onNavigate, onExpand,
}: Props) {
  const [tab, setTab] = useState<Tab>("overview");

  const entityMap = new Map(allEntities.map((e) => [e.id, e]));

  // Find relationships involving this entity
  const related = relationships.filter(
    (r) => r.source_id === entity.id || r.target_id === entity.id
  );

  const attrs = Object.entries(entity.attributes || {}).filter(
    ([k]) => !SKIP_ATTRS.has(k) && entity.attributes[k] != null
  );

  const tabClass = (t: Tab) =>
    `px-3 py-1.5 text-xs font-medium rounded-md transition-colors ${
      tab === t
        ? "bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300"
        : "text-gray-500 hover:text-gray-700 hover:bg-gray-100 dark:text-gray-400 dark:hover:bg-gray-800"
    }`;

  return (
    <div className="flex h-full w-80 flex-col border-l border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-900">
      {/* Header */}
      <div className="flex items-start justify-between border-b border-gray-200 p-4 dark:border-gray-800">
        <div className="min-w-0 flex-1">
          <div className="mb-1 flex items-center gap-2">
            <span className={`inline-block h-3 w-3 rounded-full ${ENTITY_COLORS[entity.type] || "bg-gray-400"}`} />
            <span className="text-[10px] font-semibold uppercase tracking-wider text-gray-400">
              {entity.type.replace(/_/g, " ")}
            </span>
          </div>
          <h3 className="truncate text-base font-semibold">{entity.label}</h3>
        </div>
        <button
          onClick={onClose}
          className="ml-2 rounded-md p-1 text-gray-400 hover:bg-gray-100 hover:text-gray-600 dark:hover:bg-gray-800"
        >
          <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
          </svg>
        </button>
      </div>

      {/* Tabs */}
      <div className="flex gap-1 border-b border-gray-200 px-4 py-2 dark:border-gray-800">
        <button className={tabClass("overview")} onClick={() => setTab("overview")}>Overview</button>
        <button className={tabClass("relationships")} onClick={() => setTab("relationships")}>
          Links ({related.length})
        </button>
        <button className={tabClass("sources")} onClick={() => setTab("sources")}>Sources</button>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-auto p-4">
        {tab === "overview" && (
          <div className="space-y-2">
            {attrs.length === 0 ? (
              <p className="text-sm text-gray-400">No attributes available</p>
            ) : (
              attrs.map(([key, value]) => (
                <div key={key}>
                  <dt className="text-[10px] font-medium uppercase tracking-wider text-gray-400">
                    {key.replace(/_/g, " ")}
                  </dt>
                  <dd className="text-sm">{formatValue(value)}</dd>
                </div>
              ))
            )}
          </div>
        )}

        {tab === "relationships" && (
          <div className="space-y-1.5">
            {related.length === 0 ? (
              <p className="text-sm text-gray-400">No relationships found</p>
            ) : (
              related.map((rel, i) => {
                const otherId = rel.source_id === entity.id ? rel.target_id : rel.source_id;
                const other = entityMap.get(otherId);
                const direction = rel.source_id === entity.id ? "\u2192" : "\u2190";
                return (
                  <button
                    key={i}
                    onClick={() => onNavigate(otherId)}
                    className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-800"
                  >
                    <span className="text-gray-400">{direction}</span>
                    <span className="rounded bg-gray-100 px-1.5 py-0.5 text-[10px] font-medium dark:bg-gray-700">
                      {rel.type.replace(/_/g, " ")}
                    </span>
                    <span className="min-w-0 flex-1 truncate">
                      {other?.label || otherId.slice(0, 8)}
                    </span>
                  </button>
                );
              })
            )}
          </div>
        )}

        {tab === "sources" && (
          <div className="space-y-2">
            {(entity.attributes?.sources as string[] || []).length > 0 ? (
              (entity.attributes.sources as string[]).map((source: string, i: number) => (
                <div key={i} className="rounded-md border border-gray-200 p-2 text-xs dark:border-gray-700">
                  <span className="font-medium">{source}</span>
                </div>
              ))
            ) : (
              <p className="text-sm text-gray-400">Source provenance will appear here</p>
            )}
            <p className="mt-2 text-[10px] text-gray-400">
              ID: {entity.id}
            </p>
          </div>
        )}
      </div>

      {/* Actions */}
      <div className="border-t border-gray-200 p-3 dark:border-gray-800">
        <button
          onClick={() => onExpand(entity.id)}
          className="w-full rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 dark:bg-blue-500 dark:hover:bg-blue-600"
        >
          Expand Connections
        </button>
      </div>
    </div>
  );
}

function formatValue(value: unknown): string {
  if (value === null || value === undefined) return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (Array.isArray(value)) return value.join(", ");
  if (typeof value === "object") return JSON.stringify(value);
  const str = String(value);
  return str.length > 200 ? str.slice(0, 200) + "\u2026" : str;
}
