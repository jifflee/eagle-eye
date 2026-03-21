import { useEffect, useRef, useCallback, useState } from "react";
import { Network, type Options, type Data } from "vis-network";
import { DataSet } from "vis-data";

export interface GraphNode {
  id: string;
  type: string;
  label: string;
  attributes: Record<string, unknown>;
}

export interface GraphEdge {
  source_id: string;
  target_id: string;
  type: string;
  properties?: Record<string, unknown>;
}

interface Props {
  entities: GraphNode[];
  relationships: GraphEdge[];
  onNodeClick?: (node: GraphNode) => void;
  onNodeDoubleClick?: (nodeId: string) => void;
  selectedNodeId?: string | null;
  filterTypes?: Set<string>;
}

// Modern soft palette — lighter fills with darker borders for contrast
const NODE_STYLES: Record<string, { bg: string; border: string; shape: string }> = {
  PERSON:                  { bg: "#60A5FA", border: "#2563EB", shape: "dot" },
  ADDRESS:                 { bg: "#F87171", border: "#DC2626", shape: "dot" },
  BUSINESS:                { bg: "#34D399", border: "#059669", shape: "diamond" },
  PROPERTY:                { bg: "#FBBF24", border: "#D97706", shape: "square" },
  CASE:                    { bg: "#A78BFA", border: "#7C3AED", shape: "triangle" },
  VEHICLE:                 { bg: "#F472B6", border: "#DB2777", shape: "dot" },
  CRIME_RECORD:            { bg: "#FB7185", border: "#E11D48", shape: "triangleDown" },
  SOCIAL_PROFILE:          { bg: "#2DD4BF", border: "#0D9488", shape: "dot" },
  PHONE_NUMBER:            { bg: "#9CA3AF", border: "#6B7280", shape: "dot" },
  EMAIL_ADDRESS:           { bg: "#9CA3AF", border: "#6B7280", shape: "dot" },
  ENVIRONMENTAL_FACILITY:  { bg: "#5EEAD4", border: "#14B8A6", shape: "hexagon" },
  CENSUS_TRACT:            { bg: "#CBD5E1", border: "#64748B", shape: "hexagon" },
};

const EDGE_COLORS: Record<string, string> = {
  LIVES_AT: "#93C5FD",
  OWNS_PROPERTY: "#FCD34D",
  IS_RELATIVE_OF: "#F9A8D4",
  OWNS_BUSINESS: "#6EE7B7",
  NAMED_IN_CASE: "#C4B5FD",
  LOCATED_AT: "#FCA5A5",
  HAS_CRIME_NEAR: "#FDA4AF",
  IN_CENSUS_TRACT: "#CBD5E1",
  HAS_ENV_FACILITY: "#99F6E4",
  AFFILIATED_WITH: "#A5B4FC",
  REGISTERED_VEHICLE: "#FBCFE8",
  HAS_SOCIAL_PROFILE: "#99F6E4",
  HAS_PHONE: "#D1D5DB",
  HAS_EMAIL: "#D1D5DB",
  IS_RELATIVE_OF: "#F9A8D4",
  WORKS_FOR: "#6EE7B7",
};

const NETWORK_OPTIONS: Options = {
  physics: {
    solver: "forceAtlas2Based",
    forceAtlas2Based: {
      gravitationalConstant: -60,
      centralGravity: 0.008,
      springLength: 180,
      springConstant: 0.06,
      damping: 0.5,
    },
    stabilization: { iterations: 150, fit: true },
  },
  interaction: {
    hover: true,
    tooltipDelay: 150,
    multiselect: false,
    navigationButtons: false,
    keyboard: { enabled: true },
    zoomView: true,
  },
  edges: {
    arrows: { to: { enabled: true, scaleFactor: 0.35, type: "arrow" } },
    font: {
      size: 8,
      color: "#475569",
      strokeWidth: 3,
      strokeColor: "rgba(10,14,26,0.85)",
      face: "JetBrains Mono, SF Mono, monospace",
    },
    smooth: { type: "curvedCW", roundness: 0.12 },
    width: 1.5,
    hoverWidth: 0.8,
    selectionWidth: 1.5,
  },
  nodes: {
    font: {
      size: 11,
      face: "Inter, system-ui, sans-serif",
      bold: { color: "#E2E8F0", size: 11, face: "Inter, system-ui, sans-serif", mod: "bold" },
    },
    borderWidth: 2.5,
    borderWidthSelected: 4,
    shadow: {
      enabled: true,
      color: "rgba(0,0,0,0.15)",
      size: 8,
      x: 2,
      y: 2,
    },
  },
};

export default function GraphVisualization({
  entities,
  relationships,
  onNodeClick,
  onNodeDoubleClick,
  selectedNodeId,
  filterTypes,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const networkRef = useRef<Network | null>(null);
  const nodesRef = useRef<DataSet<any>>(new DataSet());
  const edgesRef = useRef<DataSet<any>>(new DataSet());
  const entityMapRef = useRef<Map<string, GraphNode>>(new Map());
  const [initialized, setInitialized] = useState(false);
  const [containerReady, setContainerReady] = useState(false);

  // Callback ref to detect when container mounts
  const setContainerRef = useCallback((node: HTMLDivElement | null) => {
    containerRef.current = node;
    setContainerReady(!!node);
  }, []);

  // Initialize the network when container is ready
  useEffect(() => {
    if (!containerRef.current || initialized) return;

    const data: Data = { nodes: nodesRef.current, edges: edgesRef.current };
    const network = new Network(containerRef.current, data, NETWORK_OPTIONS);
    networkRef.current = network;
    setInitialized(true);

    network.on("click", (params) => {
      if (params.nodes.length > 0 && onNodeClick) {
        const nodeId = params.nodes[0] as string;
        const entity = entityMapRef.current.get(nodeId);
        if (entity) onNodeClick(entity);
      }
    });

    network.on("doubleClick", (params) => {
      if (params.nodes.length > 0 && onNodeDoubleClick) {
        onNodeDoubleClick(params.nodes[0] as string);
      }
    });

    return () => {
      network.destroy();
      networkRef.current = null;
      setInitialized(false);
    };
  }, [containerReady]);

  // Update data when entities/relationships change
  useEffect(() => {
    if (!initialized) return;

    const nodes = nodesRef.current;
    const edges = edgesRef.current;
    const entityMap = entityMapRef.current;

    // Update entity map
    entities.forEach((e) => entityMap.set(e.id, e));

    // Determine which entities to show
    const visibleEntities = filterTypes
      ? entities.filter((e) => filterTypes.has(e.type))
      : entities;

    const visibleIds = new Set(visibleEntities.map((e) => e.id));

    // Sync nodes
    const existingNodeIds = new Set(nodes.getIds() as string[]);
    const newNodeIds = new Set(visibleEntities.map((e) => e.id));

    // Remove nodes no longer visible
    const toRemove = [...existingNodeIds].filter((id) => !newNodeIds.has(id));
    if (toRemove.length) nodes.remove(toRemove);

    // Add/update visible nodes
    const nodeUpdates: any[] = [];
    const dark = isDarkMode();
    visibleEntities.forEach((entity) => {
      const style = NODE_STYLES[entity.type] || { bg: "#9CA3AF", border: "#6B7280", shape: "dot" };
      const isSelected = entity.id === selectedNodeId;
      const size = entity.type === "ADDRESS" ? 28 : entity.type === "PERSON" ? 22 : entity.type === "BUSINESS" ? 20 : 16;

      nodeUpdates.push({
        id: entity.id,
        label: truncateLabel(entity.label),
        title: buildTooltip(entity),
        shape: style.shape,
        size,
        color: {
          background: dark ? style.border : style.bg,
          border: isSelected ? "#F8FAFC" : dark ? style.bg : style.border,
          highlight: {
            background: style.bg,
            border: "#F8FAFC",
          },
          hover: {
            background: style.bg,
            border: dark ? "#E2E8F0" : style.border,
          },
        },
        font: {
          color: dark ? "#E2E8F0" : "#1E293B",
          strokeWidth: dark ? 3 : 2,
          strokeColor: dark ? "rgba(15,23,42,0.8)" : "rgba(255,255,255,0.85)",
        },
        borderWidth: isSelected ? 4 : 2.5,
        shadow: {
          enabled: true,
          color: dark ? "rgba(0,0,0,0.4)" : "rgba(0,0,0,0.12)",
          size: isSelected ? 12 : 8,
          x: 2,
          y: 2,
        },
      });
    });
    nodes.update(nodeUpdates);

    // Sync edges
    const existingEdgeIds = new Set(edges.getIds() as string[]);
    const newEdges: any[] = [];

    relationships.forEach((rel, i) => {
      if (!visibleIds.has(rel.source_id) || !visibleIds.has(rel.target_id)) return;
      const edgeId = `${rel.source_id}-${rel.type}-${rel.target_id}`;
      if (existingEdgeIds.has(edgeId)) return;

      const dark = isDarkMode();
      const edgeColor = EDGE_COLORS[rel.type] || (dark ? "#475569" : "#CBD5E1");
      newEdges.push({
        id: edgeId,
        from: rel.source_id,
        to: rel.target_id,
        label: rel.type.replace(/_/g, " ").toLowerCase(),
        color: {
          color: edgeColor,
          opacity: dark ? 0.6 : 0.5,
          highlight: edgeColor,
          hover: edgeColor,
        },
        font: {
          color: dark ? "#94A3B8" : "#64748B",
          strokeWidth: dark ? 3 : 2,
          strokeColor: dark ? "rgba(15,23,42,0.9)" : "rgba(255,255,255,0.9)",
          size: 9,
        },
        width: 1.8,
        hoverWidth: 0.5,
      });
    });
    if (newEdges.length) edges.add(newEdges);

    // Fit on first data load
    if (visibleEntities.length > 0 && toRemove.length === 0 && newEdges.length > 0) {
      setTimeout(() => networkRef.current?.fit({ animation: true }), 500);
    }
  }, [entities, relationships, filterTypes, selectedNodeId, initialized]);

  // Controls
  const handleFit = useCallback(() => {
    networkRef.current?.fit({ animation: { duration: 500, easingFunction: "easeInOutQuad" } });
  }, []);

  const handleZoomIn = useCallback(() => {
    const scale = networkRef.current?.getScale() || 1;
    networkRef.current?.moveTo({ scale: scale * 1.3, animation: true });
  }, []);

  const handleZoomOut = useCallback(() => {
    const scale = networkRef.current?.getScale() || 1;
    networkRef.current?.moveTo({ scale: scale / 1.3, animation: true });
  }, []);

  return (
    <div className="relative h-full w-full">
      <div ref={setContainerRef} className="h-full w-full" style={{ minHeight: "400px" }} />

      {/* Controls overlay */}
      <div className="absolute bottom-4 right-4 flex flex-col gap-1">
        <button onClick={handleZoomIn} className="rounded-md bg-white/90 p-2 shadow hover:bg-white dark:bg-gray-800/90 dark:hover:bg-gray-800" title="Zoom in">
          <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
        </button>
        <button onClick={handleZoomOut} className="rounded-md bg-white/90 p-2 shadow hover:bg-white dark:bg-gray-800/90 dark:hover:bg-gray-800" title="Zoom out">
          <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="5" y1="12" x2="19" y2="12"/></svg>
        </button>
        <button onClick={handleFit} className="rounded-md bg-white/90 p-2 shadow hover:bg-white dark:bg-gray-800/90 dark:hover:bg-gray-800" title="Fit to screen">
          <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="15 3 21 3 21 9"/><polyline points="9 21 3 21 3 15"/><line x1="21" y1="3" x2="14" y2="10"/><line x1="3" y1="21" x2="10" y2="14"/></svg>
        </button>
      </div>

      {/* Empty state */}
      {entities.length === 0 && (
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="text-center text-gray-400 dark:text-gray-500">
            <svg className="mx-auto mb-3 h-12 w-12 animate-pulse" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
              <circle cx="12" cy="12" r="10" /><circle cx="12" cy="12" r="3" />
              <line x1="12" y1="2" x2="12" y2="6" /><line x1="12" y1="18" x2="12" y2="22" />
              <line x1="2" y1="12" x2="6" y2="12" /><line x1="18" y1="12" x2="22" y2="12" />
            </svg>
            <p>Waiting for data...</p>
          </div>
        </div>
      )}
    </div>
  );
}

function truncateLabel(label: string, max: number = 25): string {
  return label.length > max ? label.slice(0, max - 1) + "\u2026" : label;
}

function buildTooltip(entity: GraphNode): string {
  const lines = [`<b>${entity.label}</b>`, `Type: ${entity.type.replace(/_/g, " ")}`];
  const attrs = entity.attributes || {};
  const skip = new Set(["id", "type", "created_at", "updated_at", "entity_type"]);
  Object.entries(attrs)
    .filter(([k]) => !skip.has(k))
    .slice(0, 5)
    .forEach(([k, v]) => {
      if (v != null && String(v).length < 60) {
        lines.push(`${k}: ${v}`);
      }
    });
  return lines.join("<br/>");
}

function isDarkMode(): boolean {
  return document.documentElement.classList.contains("dark");
}
