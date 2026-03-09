# MedallionHealth — Architecture Document

**Version:** 0.1.0  
**Status:** In Development  
**Last Updated:** March 2026

---

## 1. Platform Goals

MedallionHealth is designed around four non-negotiable requirements:

1. **Tenant isolation** — A hospital analyst at Hospital A must never see Hospital B's data, at any layer, by any query path.
2. **Historical accuracy** — Analytical queries must reflect the *state of the world at the time of the event*, not today's state. A doctor's specialty change must not retroactively alter historical admission records.
3. **Scale-readiness** — The platform must handle hundreds of millions of fact rows across dozens of tenants without cross-tenant performance interference.
4. **PHI compliance** — No personally identifiable information may appear in plain text in the analytics warehouse.

---

## 2. Medallion Lakehouse Layers

### 2.1 Bronze Layer (Raw / Immutable)

**Technology:** Apache Iceberg on AWS S3  
**Purpose:** Exact copy of source data, append-only, never modified after write.

- All records land here first, regardless of quality
- Schema-on-read via Iceberg metadata
- Iceberg time travel enables full audit history and point-in-time recovery
- PHI present at this layer — column-level encryption applied
- Partitioned by `tenant_id` / `event_date` for query pruning

**Ingestion paths:**
- **Real-time:** Kafka consumer writes micro-batches to Iceberg (Flink or Spark Structured Streaming)
- **Batch:** Airflow DAGs run nightly for billing, ERP, and workforce source systems

### 2.2 Silver Layer (Cleaned / Conformed)

**Technology:** dbt models on Apache Iceberg / Spark  
**Purpose:** Cleaned, deduplicated, validated, and standardized records.

Key transformations at this layer:
- Deduplication by business key + event timestamp
- PII tokenization (patient names, doctor names replaced with stable tokens)
- `global_patient_id` assignment for cross-tenant patient matching
- Schema enforcement and type casting
- Data quality tests (row counts, null checks, referential integrity)
- Multi-tenant partitioning by `tenant_id` enforced here

Silver tables serve as the source of truth for dbt Gold models and any data science exploration.

### 2.3 Gold Layer (Analytics / Serving)

**Technology:** Amazon Redshift (ra3.xlplus nodes)  
**Purpose:** Kimball star schema optimized for BI tools, executive dashboards, and ML feature extraction.

See Section 3 for full dimensional model documentation.

---

## 3. Dimensional Model (Gold Layer)

### 3.1 Modeling Methodology

The Gold layer follows **Kimball's dimensional modeling methodology**:

- **Star schema** topology — fact tables surrounded by denormalized dimension tables
- **Conformed dimensions** — `dim_hospital`, `dim_date`, and `dim_region` are shared across all fact tables
- **Surrogate keys** — `BIGINT IDENTITY` on all dimension tables; fact tables reference surrogate keys, not business keys
- **Natural/business keys preserved** — `hospital_code`, `doctor_id`, `department_id` retained as separate columns for joins back to operational systems

### 3.2 Slowly Changing Dimensions

**SCD Type 1** (overwrite, no history):
- `dim_hospital` — hospital attributes rarely change; when they do, history is not analytically meaningful
- `dim_patient` — demographic analytics use age bands, not exact values; PHI history stays in Silver/Bronze

**SCD Type 2** (versioned rows, full history):
- `dim_doctor` — tracks specialty changes, department transfers, employment status changes, and title promotions
- `dim_department` — tracks name changes, head-of-department changes, restructuring events

**SCD Type 2 implementation pattern:**

Each versioned dimension table includes:

| Column | Purpose |
|---|---|
| `doctor_key` | Surrogate key — unique per version |
| `doctor_id` | Business key — stable across all versions |
| `effective_date` | Date this version became active |
| `expiry_date` | Date this version was superseded (NULL = current) |
| `is_current` | Boolean — fast filter for current-record queries |
| `dw_version` | Version counter (1, 2, 3…) for this business key |
| `dw_row_hash` | MD5 of versioned attributes — change detection without full column comparison |

**Critical:** Fact table foreign keys (`doctor_key`, `department_key`) point to the **SCD2 version that was active at the time of the event**, not the current version. This is enforced during the dbt Gold load by joining on `effective_date <= event_date < expiry_date`.

### 3.3 Fact Table Design

#### fact_admissions
The central fact table. One row per hospital admission. Mixed load pattern: Kafka streaming for real-time admissions, daily batch for discharge completion and coding updates.

Notable design decisions:
- `is_readmission_30d` is an ML-derived flag, computed by a scheduled prediction pipeline and back-populated
- `length_of_stay_days` is NULL while the patient is still admitted; `discharge_date_key` is also NULL — downstream BI must handle open admissions
- `dw_source` column (`KAFKA_STREAM` | `BATCH_EHR`) enables pipeline lineage debugging

#### fact_bed_occupancy
Hourly snapshot fact. The grain is `hospital × department × hour`. This is a **periodic snapshot** fact (not a transaction fact) — every row represents the state of beds at a point in time, regardless of whether anything changed.

Why hourly granularity: Bed management decisions are made in real time by charge nurses. Hourly snapshots are the minimum resolution needed to identify surge patterns, anticipate ICU capacity issues, and meet Joint Commission reporting requirements.

#### fact_doctor_utilization
One row per doctor per day. Captures scheduling efficiency metrics in minutes: scheduled vs. available vs. actual worked. The `utilization_rate` and `efficiency_rate` are computed in dbt as derived measures.

#### fact_revenue and fact_cost
Financial facts. **All monetary values are stored as cents in BIGINT columns** — this eliminates floating-point precision errors that compound significantly in financial aggregations across millions of rows. Division by 100 happens only at the BI/reporting layer.

---

## 4. Multi-Tenancy Design

### 4.1 Tenant Identifier

Every table in the analytics schema carries a `tenant_id` column formatted as `hosp-NNN` (e.g., `hosp-001`, `hosp-042`). This is the foundation of all tenant isolation.

`tenant_id` is:
- **Never nullable** on any tenant-scoped table
- **Always the first sort key component** on fact tables
- **The distribution key** on large fact and dimension tables — ensures a hospital's data is co-located on the same Redshift compute node

### 4.2 Row-Level Security

Tenant isolation is enforced at the Redshift engine level, not the application layer:

```sql
CREATE RLS POLICY tenant_isolation_policy
    USING (tenant_id = current_setting('app.current_tenant_id', true));
```

The `app.current_tenant_id` session variable is set at connection time by the application layer before any query executes. Even if a developer or analyst writes a query with no `WHERE` clause, the RLS policy silently filters all rows.

**Tables exempt from RLS:** `dim_date` and `dim_region` contain no tenant data and are shared globally.

**Superuser bypass:** The `data_engineer_role` and `ml_engineer_role` bypass RLS for cross-tenant operations. The `ml_engineer_role` bypass is audit-logged — every cross-tenant query is recorded with the caller's identity and timestamp.

### 4.3 Regional Data Residency

The `dim_region` table encodes a `data_residency_zone` attribute (`US` | `EU`). EU-region hospitals' data is stored in Redshift clusters deployed in AWS `eu-central-1` to comply with GDPR data residency requirements. The platform architecture accommodates multi-region Redshift deployments sharing the same schema.

---

## 5. Ingestion Architecture

### 5.1 Real-Time Path (Kafka)

```
EHR System → Kafka Producer → Kafka Topic (per tenant)
                                    ↓
                          Kafka Consumer (Python/Spark)
                                    ↓
                          Pydantic validation
                                    ↓
                          Bronze Iceberg (S3)
                                    ↓
                          dbt incremental models → Silver → Gold
```

Kafka topics are namespaced by tenant: `hosp-001.admissions`, `hosp-001.bed-events`, etc. This provides natural tenant isolation at the message bus layer before data even lands in storage.

### 5.2 Batch Path (Airflow)

Nightly Airflow DAGs handle:
- Billing/ERP data export → Bronze → Silver → `fact_revenue`, `fact_cost`
- Workforce system export → Bronze → Silver → `dim_doctor` SCD2 updates
- Bed configuration exports → `dim_department` SCD2 updates

Airflow DAGs are parameterized by `tenant_id` — the same DAG definition handles all tenants with per-run configuration.

---

## 6. Redshift Performance Design

### 6.1 Distribution Strategy

| Table | DISTKEY | Rationale |
|---|---|---|
| `fact_admissions` | `tenant_id` | Co-locate all of a hospital's admissions on one node |
| `fact_revenue` | `tenant_id` | Financial queries always filter by tenant |
| `dim_doctor` | `tenant_id` | Join with fact_admissions on same node |
| `dim_hospital` | `DISTSTYLE ALL` | Small table; broadcast to all nodes eliminates network shuffle |
| `dim_date` | `DISTSTYLE ALL` | Shared dimension; broadcast prevents join redistribution |

### 6.2 Sort Key Strategy

All fact tables use a **compound sort key** starting with `(tenant_id, date_key)`. Since RLS always filters by `tenant_id` first, and most analytical queries have a date range predicate, this sort order maximizes zone map effectiveness and minimizes blocks scanned.

---

## 7. Architecture Decision Records

See [`docs/adr/`](./adr/) for full decision rationale. Key decisions summarized:

| ADR | Decision | Rationale |
|---|---|---|
| ADR-001 | Amazon Redshift over Snowflake | RLS enforcement at engine level; tighter IAM integration; Redshift skills more differentiated on resume |
| ADR-002 | Apache Iceberg for Bronze/Silver | Time travel for full audit history; schema evolution without rewrites; open format avoids vendor lock-in |
| ADR-003 | SCD Type 2 on Doctor + Department only | Patient history tracked at Silver via Iceberg time travel; hospital attributes change infrequently enough to not need versioning |

---

## 8. Future Phases

### Phase 2 — ML Pipelines
- 30-day readmission risk prediction model (XGBoost)
- Feature store built from `fact_admissions` Gold layer
- Batch scoring pipeline with results written back to `fact_admissions.is_readmission_30d`

### Phase 3 — LLM Assistant
- Role-scoped natural language query interface
- Uses `llm_assistant_role` (RLS enforced, table-restricted)
- Prompt injection mitigations and query sandboxing

### Phase 4 — Real-Time Alerting
- Kafka Streams / Flink for threshold-based alerts (ICU capacity > 90%)
- PagerDuty integration for on-call charge nurse notifications
