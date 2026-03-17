import { useState, useMemo } from "react";

interface TimelineEvent {
  date: string;
  label: string;
  entityId: string;
  type: string;
}

interface Props {
  entities: { id: string; type: string; label: string; attributes: Record<string, unknown> }[];
  onDateFilter: (startDate: string | null, endDate: string | null) => void;
}

export default function TimelineSlider({ entities, onDateFilter }: Props) {
  const [range, setRange] = useState<[number, number]>([0, 100]);

  // Extract all dates from entities
  const events = useMemo(() => {
    const evts: TimelineEvent[] = [];
    entities.forEach((e) => {
      const attrs = e.attributes || {};
      const dateFields = ["filing_date", "formation_date", "incident_date", "booking_date", "recording_date", "sale_date"];
      for (const field of dateFields) {
        const val = attrs[field];
        if (val && typeof val === "string" && /\d{4}/.test(val)) {
          evts.push({ date: val, label: `${e.label} (${field.replace(/_/g, " ")})`, entityId: e.id, type: e.type });
        }
      }
    });
    evts.sort((a, b) => a.date.localeCompare(b.date));
    return evts;
  }, [entities]);

  const years = useMemo(() => {
    const yrs = new Set<number>();
    events.forEach((e) => {
      const match = e.date.match(/(\d{4})/);
      if (match) yrs.add(parseInt(match[1]));
    });
    return [...yrs].sort();
  }, [events]);

  if (events.length === 0 || years.length < 2) return null;

  const minYear = years[0];
  const maxYear = years[years.length - 1];
  const startYear = minYear + Math.round((range[0] / 100) * (maxYear - minYear));
  const endYear = minYear + Math.round((range[1] / 100) * (maxYear - minYear));

  const handleChange = (idx: 0 | 1, value: number) => {
    const next: [number, number] = [...range] as [number, number];
    next[idx] = value;
    if (next[0] > next[1]) return;
    setRange(next);

    const sy = minYear + Math.round((next[0] / 100) * (maxYear - minYear));
    const ey = minYear + Math.round((next[1] / 100) * (maxYear - minYear));
    onDateFilter(`${sy}-01-01`, `${ey}-12-31`);
  };

  return (
    <div className="border-t border-gray-200 bg-white px-4 py-2 dark:border-gray-800 dark:bg-gray-900">
      <div className="flex items-center gap-3">
        <span className="text-xs font-medium text-gray-500 dark:text-gray-400">Timeline</span>
        <span className="text-xs text-gray-400">{startYear}</span>
        <div className="relative flex-1">
          <input
            type="range"
            min={0} max={100}
            value={range[0]}
            onChange={(e) => handleChange(0, parseInt(e.target.value))}
            className="absolute inset-0 w-full appearance-none bg-transparent [&::-webkit-slider-thumb]:h-3 [&::-webkit-slider-thumb]:w-3 [&::-webkit-slider-thumb]:appearance-none [&::-webkit-slider-thumb]:rounded-full [&::-webkit-slider-thumb]:bg-blue-500"
          />
          <input
            type="range"
            min={0} max={100}
            value={range[1]}
            onChange={(e) => handleChange(1, parseInt(e.target.value))}
            className="absolute inset-0 w-full appearance-none bg-transparent [&::-webkit-slider-thumb]:h-3 [&::-webkit-slider-thumb]:w-3 [&::-webkit-slider-thumb]:appearance-none [&::-webkit-slider-thumb]:rounded-full [&::-webkit-slider-thumb]:bg-blue-500"
          />
          <div className="h-1 rounded-full bg-gray-200 dark:bg-gray-700">
            <div
              className="h-full rounded-full bg-blue-500"
              style={{ marginLeft: `${range[0]}%`, width: `${range[1] - range[0]}%` }}
            />
          </div>
        </div>
        <span className="text-xs text-gray-400">{endYear}</span>
        <button
          onClick={() => { setRange([0, 100]); onDateFilter(null, null); }}
          className="text-[10px] text-blue-500 hover:text-blue-700"
        >
          Reset
        </button>
      </div>
      {/* Event markers */}
      <div className="mt-1 flex items-center gap-0.5">
        {events.slice(0, 30).map((evt, i) => {
          const match = evt.date.match(/(\d{4})/);
          const year = match ? parseInt(match[1]) : minYear;
          const pos = ((year - minYear) / (maxYear - minYear)) * 100;
          return (
            <div
              key={i}
              className="absolute h-1.5 w-1.5 rounded-full bg-blue-400 opacity-50"
              style={{ left: `${pos}%` }}
              title={`${evt.label} (${evt.date})`}
            />
          );
        })}
      </div>
    </div>
  );
}
