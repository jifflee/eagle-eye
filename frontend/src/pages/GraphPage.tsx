import { useParams } from "react-router-dom";

export default function GraphPage() {
  const { id } = useParams();

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between border-b border-gray-200 px-6 py-3 dark:border-gray-800">
        <h2 className="text-lg font-semibold">
          Investigation: {id}
        </h2>
        <div className="flex items-center gap-2">
          <span className="rounded bg-green-100 px-2 py-1 text-xs font-medium text-green-700">
            Enriching...
          </span>
        </div>
      </div>
      <div className="flex flex-1">
        {/* Graph visualization will go here (Issue #30 / 5.3) */}
        <div className="flex flex-1 items-center justify-center text-gray-400">
          Graph visualization — see Issue #30
        </div>
        {/* Entity detail panel will go here (Issue #31 / 5.4) */}
      </div>
    </div>
  );
}
