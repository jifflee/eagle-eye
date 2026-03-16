import { useState } from "react";

const ENTITY_TYPES = [
  { key: "PERSON", label: "People", color: "#3B82F6" },
  { key: "ADDRESS", label: "Addresses", color: "#EF4444" },
  { key: "BUSINESS", label: "Businesses", color: "#10B981" },
  { key: "PROPERTY", label: "Properties", color: "#F59E0B" },
  { key: "CASE", label: "Cases", color: "#8B5CF6" },
  { key: "VEHICLE", label: "Vehicles", color: "#EC4899" },
  { key: "CRIME_RECORD", label: "Crime", color: "#DC2626" },
  { key: "SOCIAL_PROFILE", label: "Social", color: "#14B8A6" },
  { key: "PHONE_NUMBER", label: "Phone", color: "#6B7280" },
  { key: "EMAIL_ADDRESS", label: "Email", color: "#6B7280" },
  { key: "ENVIRONMENTAL_FACILITY", label: "Environmental", color: "#0D9488" },
  { key: "CENSUS_TRACT", label: "Census", color: "#94A3B8" },
];

interface Props {
  entityCounts: Record<string, number>;
  activeTypes: Set<string>;
  onToggle: (type: string) => void;
  onShowAll: () => void;
  onHideAll: () => void;
}

export default function GraphFilters({ entityCounts, activeTypes, onToggle, onShowAll, onHideAll }: Props) {
  const [collapsed, setCollapsed] = useState(false);

  const typesWithData = ENTITY_TYPES.filter((t) => (entityCounts[t.key] || 0) > 0);

  if (typesWithData.length === 0) return null;

  return (
    <div className="absolute left-4 top-4 z-10 rounded-lg border border-gray-200 bg-white/95 shadow-md backdrop-blur-sm dark:border-gray-700 dark:bg-gray-900/95">
      <button
        onClick={() => setCollapsed(!collapsed)}
        className="flex w-full items-center justify-between px-3 py-2 text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400"
      >
        <span>Filters</span>
        <svg className={`h-3 w-3 transition-transform ${collapsed ? "-rotate-90" : ""}`} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <polyline points="6 9 12 15 18 9" />
        </svg>
      </button>

      {!collapsed && (
        <div className="border-t border-gray-100 px-3 pb-2 dark:border-gray-800">
          <div className="mb-1 mt-1 flex gap-2">
            <button onClick={onShowAll} className="text-[10px] text-blue-500 hover:text-blue-700">All</button>
            <button onClick={onHideAll} className="text-[10px] text-blue-500 hover:text-blue-700">None</button>
          </div>
          {typesWithData.map((t) => (
            <label key={t.key} className="flex cursor-pointer items-center gap-2 py-0.5 text-xs hover:bg-gray-50 dark:hover:bg-gray-800">
              <input
                type="checkbox"
                checked={activeTypes.has(t.key)}
                onChange={() => onToggle(t.key)}
                className="rounded"
              />
              <span className="inline-block h-2.5 w-2.5 rounded-full" style={{ backgroundColor: t.color }} />
              <span>{t.label}</span>
              <span className="ml-auto text-gray-400">{entityCounts[t.key]}</span>
            </label>
          ))}
        </div>
      )}
    </div>
  );
}
