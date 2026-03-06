# Architecture Decision Records (ADRs)

> ADRs document the key architectural decisions made during the design of MedallionHealth.
> Each ADR captures context, the decision, consequences, and alternatives considered.
> This is a living document — new ADRs are added as decisions are made.

---

## ADR-001: Global Patient Identity Strategy

**Date:** Phase 1  
**Status:** Accepted  
**Deciders:** Chief Data Engineer, Platform Architect

### Context
Patients may receive care at multiple hospitals within the MedallionHealth platform.
Each hospital assigns its own Medical Record Number (MRN). We need a strategy to:
1. Uniquely identify patients across the entire platform
2. Respect hospital-specific patient numbering
3. Enable cross-hospital analytics without exposing hospital-internal IDs

### Decision
Implement a **two-tier identity model**:
- `global_patient_id` — UUID4 issued by the Identity Service at first registration anywhere in the platform. Format: `gpid-{uuid4}`
- `hospital_mrn` — Hospital-specific sequential ID. Format: `{HOSPITAL_CODE}-{000001}`

The Identity Service maintains a mapping table: `(global_patient_id, tenant_id, hospital_mrn)`.

### Consequences
✅ Cross-hospital patient analytics are possible using `global_patient_id`  
✅ Hospitals retain their existing MRN formats  
✅ PII is isolated — global ID reveals no patient information  
⚠️ Patient merge (duplicate resolution) requires a dedicated process  
⚠️ All services must use `global_patient_id` for cross-context references  

### Alternatives Considered
- **Single UUID everywhere:** Rejected — hospitals have regulatory requirements for their own MRN formats
- **Social Security Number as global key:** Rejected — PII, not always available, HIPAA risk

---

## ADR-002: Kafka Partition Strategy

**Date:** Phase 1  
**Status:** Accepted

### Context
Kafka partitioning determines parallelism and ordering guarantees.
We need ordered processing per hospital to ensure, e.g., admission before discharge.

### Decision
Use **`tenant_id` as the Kafka partition key** with **50 partitions per topic** (one per hospital).

### Consequences
✅ All events for a given hospital are processed in order  
✅ Easy to scale — add partitions if hospital count grows  
✅ Consumer lag is measurable per hospital  
⚠️ Uneven load if some hospitals generate far more events (hotspot mitigation: use sub-topic sharding for high-volume hospitals if needed)

---

## ADR-003: Medallion Lakehouse Storage Format

**Date:** Phase 1  
**Status:** Accepted

### Context
Choose storage format for the data lakehouse on S3.

### Decision
Use **Apache Iceberg** on S3 with AWS Glue as the catalog.

Key Iceberg features leveraged:
- **ACID transactions** — safe concurrent writes from Spark and Glue
- **Time travel** — query data as of any past timestamp (HIPAA audit support)
- **Schema evolution** — add columns without rewriting tables
- **Partition evolution** — change partitioning without migration
- **Hidden partitioning** — no partition filter required in queries

### S3 Path Structure
```
s3://medallionhealth-{layer}-{env}/
  {domain}/
    {entity}/
      tenant_id={hosp-NNN}/
        year={YYYY}/
          month={MM}/
            day={DD}/
              part-{uuid}.parquet
```

### Consequences
✅ ACID on S3 — no more corrupt partial writes  
✅ Time travel supports compliance and debugging  
✅ Native Spark, Athena, and Redshift Spectrum support  
⚠️ Iceberg metadata overhead for small tables (mitigated by compaction jobs)  

---

## ADR-004: Monetary Values Representation

**Date:** Phase 1  
**Status:** Accepted

### Decision
All monetary values stored as **integers representing cents (1/100 of a dollar)** using `BIGINT/long`.

### Example
- $1,250.75 is stored as `125075`
- Maximum value: `9,223,372,036,854,775,807` cents ≈ $92 trillion (sufficient for enterprise)

### Consequences
✅ No floating-point precision errors in billing calculations  
✅ Safe for SUM aggregations across millions of records  
⚠️ Application layer must divide by 100 for display  

---

## ADR-005: SCD Type 2 for Doctor and Department Dimensions

**Date:** Phase 1  
**Status:** Accepted

### Context
Doctors change departments, specialties, and employment status over time.
Historical analytics (e.g., "what department was Dr. Smith in during Q3 2023?") require tracking changes.

### Decision
Apply **Slowly Changing Dimension Type 2 (SCD Type 2)** to `dim_doctor` and `dim_department`.

SCD Type 2 adds the following columns to dimension tables:
```sql
effective_date    DATE         -- When this version became active
expiry_date       DATE         -- When this version was superseded (NULL = current)
is_current        BOOLEAN      -- TRUE for the active version only
dw_version_key    BIGINT       -- Surrogate key for this version
```

### Consequences
✅ Full history preserved for any dimension attribute change  
✅ Fact tables can join at any historical point in time  
✅ Audit-compliant — changes are never deleted  
⚠️ Queries require `WHERE is_current = TRUE` to get current state  
⚠️ More storage than SCD Type 1, but negligible for dimension tables  

---

## ADR-006: Multi-Tenant Row-Level Security in Redshift

**Date:** Phase 1  
**Status:** Accepted

### Decision
Implement **Row-Level Security (RLS)** in Amazon Redshift using RLS policies tied to IAM roles.

```sql
-- Each hospital analyst role can only see their tenant's data
CREATE RLS POLICY tenant_isolation
  USING (tenant_id = current_setting('app.current_tenant_id'));

ATTACH RLS POLICY tenant_isolation ON fact_admissions TO ROLE hospital_analyst;
```

Platform-level roles (data engineers, ML team) bypass RLS via a superuser role.

### Consequences
✅ Tenant isolation enforced at database level — not application level  
✅ Works with any SQL client (Tableau, QuickSight, custom tools)  
⚠️ Session variable `app.current_tenant_id` must be set at connection time  

---

## ADR-007: PII Handling Strategy

**Date:** Phase 1  
**Status:** Accepted

### PII Fields Identified
| Field | Classification | Strategy |
|-------|---------------|---------|
| first_name | PII | Tokenization (AES-256) |
| last_name | PII | Tokenization (AES-256) |
| date_of_birth | PII | Retain in source only; use age_band in analytics |
| email | PII | Tokenization |
| phone | PII | Tokenization |
| address | PII | Masking (city/state only in analytics) |
| policy_number | Sensitive | Tokenization |
| SSN | PHI | Never stored in platform; hash only |

### Strategy Details
- **Tokenization:** Reversible, authorized users can de-tokenize. Stored in AWS Secrets Manager.
- **Masking:** Irreversible at analytics layer. Column shows `XXX-MASKED` or partial value.
- **Age bands:** DOB replaced with `age_band` (0-17, 18-34, 35-50, 51-65, 65+) in Gold layer.

### Event Layer Rule
Events carry **tokens**, never raw PII. The token → PII mapping is maintained by the Identity Service only.
