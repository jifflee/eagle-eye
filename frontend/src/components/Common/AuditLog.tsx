import { useEffect, useState } from "react";
import { apiFetch } from "@/api/client";

interface AuditEntry {
  action: string;
  entity_id: string | null;
  entity_type: string | null;
  details: Record<string, unknown> | null;
  created_at: string;
}

interface Props {
  investigationId: string;
}

export default function AuditLog({ investigationId }: Props) {
  const [entries, setEntries] = useState<AuditEntry[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    apiFetch<AuditEntry[]>(`/api/v1/investigation/${investigationId}/audit`)
      .then(setEntries)
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [investigationId]);

  if (loading) {
    return <p className="p-4 text-xs text-gray-400">Loading audit log...</p>;
  }

  if (entries.length === 0) {
    return <p className="p-4 text-xs text-gray-400">No audit entries yet</p>;
  }

  return (
    <div className="space-y-1 p-3">
      <h3 className="mb-2 text-[10px] font-semibold uppercase tracking-wider text-gray-400">
        Audit Log
      </h3>
      {entries.map((entry, i) => (
        <div key={i} className="flex items-start gap-2 py-1 text-xs">
          <span className="shrink-0 text-gray-400">
            {new Date(entry.created_at).toLocaleTimeString()}
          </span>
          <span className="font-medium">{entry.action}</span>
          {entry.entity_type && (
            <span className="text-gray-400">{entry.entity_type}</span>
          )}
        </div>
      ))}
    </div>
  );
}
