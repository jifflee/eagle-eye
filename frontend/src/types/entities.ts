export type EntityType =
  | "PERSON"
  | "ADDRESS"
  | "PROPERTY"
  | "BUSINESS"
  | "CASE"
  | "VEHICLE"
  | "CRIME_RECORD"
  | "SOCIAL_PROFILE"
  | "PHONE_NUMBER"
  | "EMAIL_ADDRESS"
  | "ENVIRONMENTAL_FACILITY"
  | "CENSUS_TRACT";

export interface Entity {
  id: string;
  type: EntityType;
  label: string;
  attributes: Record<string, unknown>;
  sources: SourceRecord[];
}

export interface Relationship {
  id: string;
  sourceId: string;
  targetId: string;
  type: string;
  properties: Record<string, unknown>;
}

export interface SourceRecord {
  connectorName: string;
  confidence: number;
  retrievedAt: string;
}

export interface Investigation {
  id: string;
  address: string;
  status: "initializing" | "enriching" | "complete" | "paused" | "failed";
  entities: Entity[];
  relationships: Relationship[];
  createdAt: string;
}
