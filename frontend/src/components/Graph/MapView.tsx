import { useEffect, useRef } from "react";

interface MapEntity {
  id: string;
  type: string;
  label: string;
  latitude?: number;
  longitude?: number;
}

interface Props {
  center: { lat: number; lng: number };
  entities: MapEntity[];
  onEntityClick?: (entityId: string) => void;
}

const MARKER_COLORS: Record<string, string> = {
  ADDRESS: "#EF4444",
  PERSON: "#3B82F6",
  BUSINESS: "#10B981",
  ENVIRONMENTAL_FACILITY: "#0D9488",
  CRIME_RECORD: "#DC2626",
};

/**
 * Map view using Leaflet + OpenStreetMap.
 *
 * Leaflet is loaded from CDN to avoid bundling the entire library.
 * In production, install leaflet as a dependency.
 */
export default function MapView({ center, entities, onEntityClick }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<any>(null);

  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;

    // Check if Leaflet is available (loaded from CDN in index.html)
    const L = (window as any).L;
    if (!L) {
      // Fallback: show a simple placeholder
      if (containerRef.current) {
        containerRef.current.innerHTML = `
          <div style="display:flex;align-items:center;justify-content:center;height:100%;color:#9CA3AF;flex-direction:column;gap:8px">
            <p>Map requires Leaflet</p>
            <p style="font-size:12px">Add Leaflet CDN to index.html or install: npm i leaflet @types/leaflet</p>
          </div>
        `;
      }
      return;
    }

    const map = L.map(containerRef.current).setView([center.lat, center.lng], 14);
    mapRef.current = map;

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      maxZoom: 19,
    }).addTo(map);

    // Add markers
    entities.forEach((entity) => {
      if (!entity.latitude || !entity.longitude) return;
      const color = MARKER_COLORS[entity.type] || "#6B7280";

      const icon = L.divIcon({
        html: `<div style="width:12px;height:12px;border-radius:50%;background:${color};border:2px solid white;box-shadow:0 1px 3px rgba(0,0,0,0.3)"></div>`,
        iconSize: [12, 12],
        className: "",
      });

      const marker = L.marker([entity.latitude, entity.longitude], { icon })
        .addTo(map)
        .bindPopup(`<b>${entity.label}</b><br/>${entity.type.replace(/_/g, " ")}`);

      if (onEntityClick) {
        marker.on("click", () => onEntityClick(entity.id));
      }
    });

    // Add center marker (larger)
    const centerIcon = L.divIcon({
      html: `<div style="width:20px;height:20px;border-radius:50%;background:#EF4444;border:3px solid white;box-shadow:0 2px 6px rgba(0,0,0,0.4)"></div>`,
      iconSize: [20, 20],
      className: "",
    });
    L.marker([center.lat, center.lng], { icon: centerIcon })
      .addTo(map)
      .bindPopup("<b>Investigation Address</b>");

    return () => {
      map.remove();
      mapRef.current = null;
    };
  }, [center.lat, center.lng]);

  return <div ref={containerRef} className="h-full w-full" />;
}
