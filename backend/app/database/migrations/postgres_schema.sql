-- Eagle Eye — PostgreSQL Schema
-- Handles provenance, investigations, and audit logging

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- Investigations
-- ============================================

CREATE TABLE IF NOT EXISTS investigations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255),
    notes TEXT,
    address_street VARCHAR(500) NOT NULL,
    address_city VARCHAR(255) NOT NULL,
    address_state VARCHAR(2) NOT NULL,
    address_zip VARCHAR(10) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'initializing',
    root_entity_id VARCHAR(255),
    entity_count INTEGER DEFAULT 0,
    relationship_count INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_investigations_status ON investigations(status);
CREATE INDEX IF NOT EXISTS idx_investigations_created ON investigations(created_at DESC);

-- ============================================
-- Source Records (Provenance)
-- ============================================

CREATE TABLE IF NOT EXISTS source_records (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    entity_id VARCHAR(255) NOT NULL,
    investigation_id UUID REFERENCES investigations(id) ON DELETE CASCADE,
    connector_name VARCHAR(100) NOT NULL,
    confidence_score FLOAT NOT NULL DEFAULT 0.5,
    data_quality_flags VARCHAR(50)[] DEFAULT '{}',
    retrieval_date TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expiration_date TIMESTAMP WITH TIME ZONE,
    raw_data JSONB,
    attribute_name VARCHAR(255),
    attribute_value TEXT,
    attribute_hash VARCHAR(64)
);

CREATE INDEX IF NOT EXISTS idx_source_entity ON source_records(entity_id);
CREATE INDEX IF NOT EXISTS idx_source_investigation ON source_records(investigation_id);
CREATE INDEX IF NOT EXISTS idx_source_connector ON source_records(connector_name);
CREATE INDEX IF NOT EXISTS idx_source_confidence ON source_records(confidence_score DESC);
CREATE INDEX IF NOT EXISTS idx_source_retrieval ON source_records(retrieval_date DESC);

-- ============================================
-- Connector Status
-- ============================================

CREATE TABLE IF NOT EXISTS connector_status (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    investigation_id UUID REFERENCES investigations(id) ON DELETE CASCADE,
    connector_name VARCHAR(100) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    entities_found INTEGER DEFAULT 0,
    error_message TEXT,
    retry_count INTEGER DEFAULT 0,
    next_retry_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_connector_investigation ON connector_status(investigation_id);
CREATE INDEX IF NOT EXISTS idx_connector_status ON connector_status(status);

-- ============================================
-- Audit Log
-- ============================================

CREATE TABLE IF NOT EXISTS audit_log (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    investigation_id UUID REFERENCES investigations(id) ON DELETE SET NULL,
    action VARCHAR(100) NOT NULL,
    entity_id VARCHAR(255),
    entity_type VARCHAR(50),
    details JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_investigation ON audit_log(investigation_id);
CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_log(action);
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at DESC);

-- ============================================
-- Updated_at trigger
-- ============================================

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER investigations_updated_at
    BEFORE UPDATE ON investigations
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();
