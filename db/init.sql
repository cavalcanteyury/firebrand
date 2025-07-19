CREATE TABLE IF NOT EXISTS payments (
    id SERIAL PRIMARY KEY,
    correlation_id VARCHAR(36) UNIQUE NOT NULL,
    amount DECIMAL(10, 2) NOT NULL,
    processed_at TIMESTAMP WITH TIME ZONE NOW(),
    requested_at TIMESTAMP WITH TIME ZONE NOT NULL,
    processor_type VARCHAR(10) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_payments_processed_at ON payments (processed_at);
CREATE INDEX IF NOT EXISTS idx_payments_processed_at ON payments (requested_at);
CREATE INDEX IF NOT EXISTS idx_payments_processor_type ON payments (processor_type);