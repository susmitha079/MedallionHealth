# Data Contract Specification – MedallionHealth
## Version 1.0.0

---

## What is a Data Contract?

A Data Contract is a formal agreement between data **producers** (services that emit events)
and data **consumers** (services and pipelines that process those events).

It defines:
- Schema structure and field types
- Validation rules and constraints
- SLA commitments (freshness, availability)
- Evolution and versioning rules
- Ownership and accountability

> **Principle:** Data contracts are code. They live in this repository and are reviewed via Pull Request.
> Any breaking change to a contract requires a new version and a migration plan.

---

## Contract Template

Every event type has a contract following this structure:

```yaml
contract:
  name:             # Human-readable name
  topic:            # Kafka topic name
  version:          # Semver (major = breaking change)
  status:           # draft | active | deprecated | retired
  owner:
    team:           # Engineering team name
    service:        # Producing microservice
    slack_channel:  # #team-channel for contract questions
    on_call:        # PagerDuty or contact

  schema:
    format:         # avro | json | protobuf
    registry_subject: # Schema Registry subject name
    avro_schema:    # Inline Avro schema

  sla:
    max_latency_seconds:    # Max seconds from event to Kafka
    availability_percent:   # Uptime SLA
    max_redelivery_hours:   # Max time to replay missed events

  data_quality:
    required_fields:        # Fields that must never be null
    format_validations:     # Regex or format rules
    business_rules:         # Domain-specific validation

  consumers:
    - service:              # Consumer service name
      purpose:              # Why they consume this
      criticality:          # high | medium | low

  pii_fields:
    - field:                # Field name
      classification:       # PII | PHI | Sensitive
      strategy:             # tokenized | masked | excluded

  change_log:
    - version:
      date:
      author:
      changes:
```

---

## Active Contracts

---

### CONTRACT-001: Patient Registration

```yaml
contract:
  name: Patient Registered Event
  topic: identity.patient.registered.v1
  version: 1.0.0
  status: active
  owner:
    team: Identity Platform Team
    service: patient-service
    slack_channel: "#team-identity"
    on_call: identity-oncall@medallionhealth.com

  schema:
    format: avro
    registry_subject: identity.patient.registered-value
    evolution_policy: BACKWARD_COMPATIBLE

  sla:
    max_latency_seconds: 5
    availability_percent: 99.9
    max_redelivery_hours: 24
    max_daily_events: 50000      # 50 hospitals x 1000 registrations/day max

  data_quality:
    required_fields:
      - event_id
      - event_timestamp
      - tenant_id
      - payload.global_patient_id
      - payload.hospital_mrn
      - payload.demographics.date_of_birth
    format_validations:
      - field: tenant_id
        rule: "^hosp-[0-9]{3}$"
        error: "tenant_id must be in format hosp-NNN"
      - field: payload.global_patient_id
        rule: "^gpid-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        error: "global_patient_id must be valid UUID v4 with gpid- prefix"
      - field: payload.hospital_mrn
        rule: "^H[0-9]{3}-[0-9]{6}$"
        error: "hospital_mrn must be in format HNNN-000001"
    business_rules:
      - rule: event_timestamp must not be in the future
      - rule: date_of_birth must be before event_timestamp
      - rule: hospital_mrn must be unique within tenant_id

  consumers:
    - service: clinical-admission-service
      purpose: Look up patient when creating admissions
      criticality: high
    - service: scheduling-appointment-service
      purpose: Validate patient exists before booking
      criticality: high
    - service: billing-service
      purpose: Set up patient billing profile
      criticality: medium
    - service: bronze-ingestion-patient
      purpose: Persist to Bronze lakehouse layer
      criticality: high
    - service: audit-consumer
      purpose: HIPAA audit trail
      criticality: high

  pii_fields:
    - field: payload.demographics.first_name_token
      classification: PII
      strategy: tokenized
      note: "Raw name stored only in patient-service DB, never in events"
    - field: payload.demographics.last_name_token
      classification: PII
      strategy: tokenized
    - field: payload.demographics.date_of_birth
      classification: PII
      strategy: "retained in Bronze/Silver; replaced with age_band in Gold"
    - field: payload.insurance.policy_token
      classification: Sensitive
      strategy: tokenized

  change_log:
    - version: 1.0.0
      date: "2024-01-01"
      author: identity-team
      changes: "Initial contract"
```

---

### CONTRACT-002: Hospital Admission Created

```yaml
contract:
  name: Admission Created Event
  topic: clinical.admission.created.v1
  version: 1.0.0
  status: active
  owner:
    team: Clinical Systems Team
    service: admission-service
    slack_channel: "#team-clinical"
    on_call: clinical-oncall@medallionhealth.com

  sla:
    max_latency_seconds: 3        # Admissions are time-critical
    availability_percent: 99.95   # Higher SLA - affects bed management
    max_redelivery_hours: 4

  data_quality:
    required_fields:
      - payload.admission_id
      - payload.global_patient_id
      - payload.tenant_id
      - payload.admission_datetime
      - payload.admission_type
      - payload.primary_diagnosis_code
      - payload.attending_doctor_id
      - payload.department_id
      - payload.bed_id
    format_validations:
      - field: payload.primary_diagnosis_code
        rule: "^[A-Z][0-9]{2}(\\.[0-9A-Z]{1,4})?$"
        error: "Must be valid ICD-10-CM code"
      - field: payload.admission_datetime
        rule: "must not be more than 60 seconds in the future"
    business_rules:
      - rule: referenced global_patient_id must exist in identity context
      - rule: referenced doctor_id must be active and available
      - rule: referenced bed_id must have status AVAILABLE or RESERVED

  consumers:
    - service: operations-bed-service
      purpose: Change bed status to OCCUPIED
      criticality: high
    - service: billing-service
      purpose: Open billing episode
      criticality: high
    - service: bronze-ingestion-admission
      purpose: Persist to lakehouse
      criticality: high
    - service: ml-readmission-feature-builder
      purpose: Build real-time ML features
      criticality: medium

  change_log:
    - version: 1.0.0
      date: "2024-01-01"
      author: clinical-team
      changes: "Initial contract"
```

---

### CONTRACT-003: Billing Generated

```yaml
contract:
  name: Billing Generated Event
  topic: finance.billing.generated.v1
  version: 1.0.0
  status: active
  owner:
    team: Finance Platform Team
    service: billing-service
    slack_channel: "#team-finance"
    on_call: finance-oncall@medallionhealth.com

  sla:
    max_latency_seconds: 30       # Billing is not real-time critical
    availability_percent: 99.9
    max_redelivery_hours: 48

  data_quality:
    required_fields:
      - payload.invoice_id
      - payload.tenant_id
      - payload.global_patient_id
      - payload.billing_datetime
      - payload.service_date
      - payload.line_items
      - payload.payer_type
    business_rules:
      - rule: "subtotal_cents must equal SUM(line_items.total_cents)"
      - rule: "patient_responsibility_cents = subtotal_cents - insurance_covered_cents"
      - rule: "all monetary values must be >= 0"
      - rule: "line_items array must have at least 1 item"
      - rule: "each CPT code must be a valid 5-character CPT code"

  pii_fields:
    - field: payload.global_patient_id
      classification: PHI
      strategy: "reference only; no direct PII. Tokenized name stored in patient-service"

  change_log:
    - version: 1.0.0
      date: "2024-01-01"
      author: finance-team
      changes: "Initial contract"
```

---

## Contract Governance Process

### Publishing a New Contract
1. Create PR with new contract YAML in `docs/data-contracts/`
2. Required approvals: producing team + 1 consuming team + data governance
3. Register schema in Schema Registry (automated via CI/CD)
4. Add consumer groups to topic configuration
5. Announce in `#data-contracts` Slack channel

### Modifying an Existing Contract
```
Non-breaking change (e.g., add optional field):
├── Update contract YAML
├── Bump patch version (1.0.0 → 1.0.1)
├── PR review: producing team only
└── Deploy with same topic name

Breaking change (e.g., remove field, change type):
├── Create new contract with v+1 topic
├── Dual-write period: producer writes to both v1 and v2
├── Consumers migrate to v2 (30-day window)
├── Deprecate v1 (status: deprecated)
└── Retire v1 after all consumers migrated (status: retired)
```

### Contract Violation Response
| Severity | Condition | Response |
|----------|-----------|----------|
| P1 | Required field missing | Alert producing team, dead-letter queue |
| P2 | Format validation failure | Alert + skip record, alert data quality |
| P3 | Business rule violation | Log + alert data quality team |
