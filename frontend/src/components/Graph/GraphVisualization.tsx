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

const NODE_STYLES: Record<string, { color: string; shape: string }> = {
  PERSON:                  { color: "#3B82F6", shape: "circle" },
  ADDRESS:                 { color: "#EF4444", shape: "square" },
  BUSINESS:                { color: "#10B981", shape: "diamond" },
  PROPERTY:                { color: "#F59E0B", shape: "square" },
  CASE:                    { color: "#8B5CF6", shape: "triangle" },
  VEHICLE:                 { color: "#EC4899", shape: "dot" },
  CRIME_RECORD:            { color: "#DC2626", shape: "triangleDown" },
  SOCIAL_PROFILE:          { color: "#14B8A6", shape: "dot" },
  PHONE_NUMBER:            { color: "#6B7280", shape: "dot" },
  EMAIL_ADDRESS:           { color: "#6B7280", shape: "dot" },
  ENVIRONMENTAL_FACILITY:  { color: "#0D9488", shape: "hexagon" },
  CENSUS_TRACT:            { color: "#94A3B8", shape: "hexagon" },
};

const EDGE_COLORS: Record<string, string> = {
  LIVES_AT: "#3B82F6",
  OWNS_PROPERTY: "#F59E0B",
  IS_RELATIVE_OF: "#EC4899",
  OWNS_BUSINESS: "#10B981",
  NAMED_IN_CASE: "#8B5CF6",
  LOCATED_AT: "#EF4444",
  HAS_CRIME_NEAR: "#DC2626",
  IN_CENSUS_TRACT: "#94A3B8",
  HAS_ENV_FACILITY: "#0D9488",
  AFFILIATED_WITH: "#6366F1",
};

const NETWORK_OPTIONS: Options = {
  physics: {
    solver: "forceAtlas2Based",
    forceAtlas2Based: {
      gravitationalConstant: -40,
      centralGravity: 0.005,
      springLength: 150,
      springConstant: 0.08,
      damping: 0.4,
    },
    stabilization: { iterations: 100, fit: true },
  },
  interaction: {
    hover: true,
    tooltipDelay: 200,
    multiselect: false,
    navigationButtons: true,
    keyboard: { enabled: true },
  },
  edges: {
    arrows: { to: { enabled: true, scaleFactor: 0.5 } },
    font: { size: 10, color: "#9CA3AF", strokeWidth: 0 },
    smooth: { type: "continuous", roundness: 0.3 },
    width: 1.5,
  },
  nodes: {
    font: { size: 12, face: "Inter, system-ui, sans-serif" },
    borderWidth: 2,
    shadow: { enabled: true, size: 4, x: 1, y: 1 },
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
    visibleEntities.forEach((entity) => {
      const style = NODE_STYLES[entity.type] || { color: "#6B7280", shape: "dot" };
      const isSelected = entity.id === selectedNodeId;
      const nodeData = {
        id: entity.id,
        label: truncateLabel(entity.label),
        title: buildTooltip(entity),
        shape: style.shape,
        color: {
          background: style.color,
          border: isSelected ? "#FFFFFF" : style.color,
          highlight: { background: style.color, border: "#FFFFFF" },
          hover: { background: style.color, border: "#E5E7EB" },
        },
        font: {
          color: isDarkMode() ? "#F3F4F6" : "#1F2937",
        },
        size: entity.type === "ADDRESS" ? 25 : entity.type === "PERSON" ? 20 : 15,
        borderWidth: isSelected ? 4 : 2,
      };

      if (existingNodeIds.has(entity.id)) {
        nodeUpdates.push(nodeData);
      } else {
        nodeUpdates.push(nodeData);
      }
    });
    nodes.update(nodeUpdates);

    // Sync edges
    const existingEdgeIds = new Set(edges.getIds() as string[]);
    const newEdges: any[] = [];

    relationships.forEach((rel, i) => {
      if (!visibleIds.has(rel.source_id) || !visibleIds.has(rel.target_id)) return;
      const edgeId = `${rel.source_id}-${rel.type}-${rel.target_id}`;
      if (existingEdgeIds.has(edgeId)) return;

      newEdges.push({
        id: edgeId,
        from: rel.source_id,
        to: rel.target_id,
        label: rel.type.replace(/_/g, " "),
        color: { color: EDGE_COLORS[rel.type] || "#9CA3AF", opacity: 0.7 },
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
