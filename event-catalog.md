# Event Catalog – MedallionHealth

## Event Design Principles

1. **Envelope-first:** All events share a common envelope schema
2. **Immutable events:** Events are facts — never updated, only appended
3. **Versioned contracts:** Schema evolution via version suffix (`.v1`, `.v2`)
4. **Tenant-partitioned:** `tenant_id` is always the Kafka partition key
5. **Schema Registry enforced:** All events validated against Confluent Schema Registry
6. **At-least-once delivery:** Consumers must be idempotent

---

## Topic Naming Convention

```
{domain}.{entity}.{event_type}.v{version}

Domain values:   identity | clinical | operations | scheduling | finance | workforce | audit
Entity:          snake_case entity name
Event type:      past-tense verb (registered, created, updated, cancelled)
Version:         integer starting at 1
```

---

## Kafka Topic Registry

| Topic Name | Domain | Partitions | Retention | Partition Key | Compaction |
|-----------|--------|-----------|-----------|---------------|-----------|
| `identity.patient.registered.v1` | Identity | 50 | 30 days | tenant_id | No |
| `identity.patient.updated.v1` | Identity | 50 | 30 days | tenant_id | No |
| `identity.patient.merged.v1` | Identity | 50 | 7 days | tenant_id | No |
| `clinical.admission.created.v1` | Clinical | 50 | 90 days | tenant_id | No |
| `clinical.admission.updated.v1` | Clinical | 50 | 90 days | tenant_id | No |
| `clinical.discharge.completed.v1` | Clinical | 50 | 90 days | tenant_id | No |
| `operations.bed.status_changed.v1` | Operations | 50 | 7 days | tenant_id | Yes |
| `operations.bed.assigned.v1` | Operations | 50 | 30 days | tenant_id | No |
| `scheduling.appointment.booked.v1` | Scheduling | 50 | 90 days | tenant_id | No |
| `scheduling.appointment.cancelled.v1` | Scheduling | 50 | 90 days | tenant_id | No |
| `scheduling.appointment.completed.v1` | Scheduling | 50 | 90 days | tenant_id | No |
| `workforce.doctor.availability_updated.v1` | Workforce | 50 | 7 days | tenant_id | Yes |
| `finance.billing.generated.v1` | Finance | 50 | 365 days | tenant_id | No |
| `finance.payment.received.v1` | Finance | 50 | 365 days | tenant_id | No |
| `finance.claim.submitted.v1` | Finance | 50 | 365 days | tenant_id | No |
| `audit.access.logged.v1` | Audit | 100 | 2 years | tenant_id | No |

**Partition count rationale:** 50 partitions = 1 per tenant, enabling per-hospital ordered processing.

---

## Universal Event Envelope Schema (Avro)

> Every event in the platform uses this envelope. The `payload` field contains domain-specific data.

```json
{
  "namespace": "com.medallionhealth.events",
  "name": "EventEnvelope",
  "type": "record",
  "doc": "Universal event envelope for all MedallionHealth domain events",
  "fields": [
    {
      "name": "event_id",
      "type": "string",
      "doc": "UUID v4. Globally unique event identifier. Used for deduplication."
    },
    {
      "name": "event_type",
      "type": "string",
      "doc": "Fully qualified event type. Example: identity.patient.registered.v1"
    },
    {
      "name": "event_version",
      "type": "int",
      "doc": "Schema version integer. Matches topic version suffix."
    },
    {
      "name": "event_timestamp",
      "type": {
        "type": "long",
        "logicalType": "timestamp-millis"
      },
      "doc": "UTC epoch milliseconds when the event occurred in the source system."
    },
    {
      "name": "ingestion_timestamp",
      "type": {
        "type": "long",
        "logicalType": "timestamp-millis"
      },
      "doc": "UTC epoch milliseconds when the event was produced to Kafka."
    },
    {
      "name": "tenant_id",
      "type": "string",
      "doc": "Hospital tenant identifier. Format: hosp-{NNN}. Kafka partition key."
    },
    {
      "name": "region",
      "type": {
        "type": "enum",
        "name": "AWSRegion",
        "symbols": ["us-east-1", "us-west-2", "eu-central-1"]
      },
      "doc": "AWS region where the source service is deployed."
    },
    {
      "name": "source",
      "type": {
        "type": "record",
        "name": "EventSource",
        "fields": [
          {"name": "service", "type": "string", "doc": "Originating microservice name"},
          {"name": "instance_id", "type": "string", "doc": "Pod/instance identifier"},
          {"name": "version", "type": "string", "doc": "Service deployment version"}
        ]
      },
      "doc": "Source service metadata for tracing and debugging."
    },
    {
      "name": "correlation_id",
      "type": ["null", "string"],
      "default": null,
      "doc": "Optional. Links related events in a business transaction (e.g., admission → billing)."
    },
    {
      "name": "causation_id",
      "type": ["null", "string"],
      "default": null,
      "doc": "Optional. event_id of the event that caused this event."
    },
    {
      "name": "payload",
      "type": "bytes",
      "doc": "Avro-serialized domain-specific payload. Schema defined per event_type."
    }
  ]
}
```

---

## Domain Event Schemas

### 1. identity.patient.registered.v1

```json
{
  "namespace": "com.medallionhealth.events.identity",
  "name": "PatientRegisteredPayload",
  "type": "record",
  "doc": "Emitted when a new patient is registered at any hospital in the platform.",
  "fields": [
    {
      "name": "global_patient_id",
      "type": "string",
      "doc": "Platform-wide unique patient ID. Format: gpid-{uuid4}"
    },
    {
      "name": "hospital_mrn",
      "type": "string",
      "doc": "Hospital-specific Medical Record Number. Format: {HOSPITAL_CODE}-{000001}"
    },
    {
      "name": "tenant_id",
      "type": "string",
      "doc": "Registering hospital tenant ID"
    },
    {
      "name": "registration_datetime",
      "type": {"type": "long", "logicalType": "timestamp-millis"}
    },
    {
      "name": "demographics",
      "type": {
        "type": "record",
        "name": "PatientDemographics",
        "fields": [
          {"name": "first_name_token",   "type": "string", "doc": "Tokenized PII"},
          {"name": "last_name_token",    "type": "string", "doc": "Tokenized PII"},
          {"name": "date_of_birth",      "type": {"type": "int", "logicalType": "date"},
           "doc": "Used for age-band analytics. Full DOB retained in source only."},
          {"name": "gender",             "type": {"type": "enum", "name": "Gender",
           "symbols": ["MALE", "FEMALE", "NON_BINARY", "UNKNOWN"]}},
          {"name": "blood_type",         "type": ["null", "string"], "default": null}
        ]
      }
    },
    {
      "name": "insurance",
      "type": {
        "type": "record",
        "name": "InsuranceInfo",
        "fields": [
          {"name": "provider_code",    "type": "string"},
          {"name": "policy_token",     "type": "string", "doc": "Tokenized policy number"},
          {"name": "coverage_type",    "type": {"type": "enum", "name": "CoverageType",
           "symbols": ["PRIVATE", "MEDICARE", "MEDICAID", "UNINSURED", "OTHER"]}}
        ]
      }
    },
    {
      "name": "is_existing_global_patient",
      "type": "boolean",
      "doc": "True if this patient was previously registered at another hospital in the platform.",
      "default": false
    }
  ]
}
```

---

### 2. clinical.admission.created.v1

```json
{
  "namespace": "com.medallionhealth.events.clinical",
  "name": "AdmissionCreatedPayload",
  "type": "record",
  "doc": "Emitted when a patient is admitted to a hospital.",
  "fields": [
    {"name": "admission_id",          "type": "string", "doc": "UUID"},
    {"name": "global_patient_id",     "type": "string"},
    {"name": "hospital_mrn",          "type": "string"},
    {"name": "tenant_id",             "type": "string"},
    {"name": "admission_datetime",    "type": {"type": "long", "logicalType": "timestamp-millis"}},
    {
      "name": "admission_type",
      "type": {
        "type": "enum",
        "name": "AdmissionType",
        "symbols": ["EMERGENCY", "ELECTIVE", "TRANSFER", "OBSERVATION"]
      }
    },
    {"name": "primary_diagnosis_code","type": "string", "doc": "ICD-10-CM code"},
    {"name": "secondary_diagnosis_codes", "type": {"type": "array", "items": "string"}, "default": []},
    {"name": "attending_doctor_id",   "type": "string"},
    {"name": "department_id",         "type": "string"},
    {"name": "bed_id",                "type": "string"},
    {
      "name": "expected_los_days",
      "type": ["null", "int"],
      "default": null,
      "doc": "Expected Length of Stay in days. Used for bed forecasting."
    },
    {"name": "is_icu_admission",      "type": "boolean", "default": false}
  ]
}
```

---

### 3. operations.bed.status_changed.v1

```json
{
  "namespace": "com.medallionhealth.events.operations",
  "name": "BedStatusChangedPayload",
  "type": "record",
  "doc": "Emitted whenever a bed status changes. High-frequency event.",
  "fields": [
    {"name": "bed_id",            "type": "string"},
    {"name": "tenant_id",         "type": "string"},
    {"name": "ward_id",           "type": "string"},
    {"name": "bed_number",        "type": "string"},
    {
      "name": "bed_type",
      "type": {
        "type": "enum",
        "name": "BedType",
        "symbols": ["GENERAL", "ICU", "EMERGENCY", "SURGICAL", "MATERNITY", "PEDIATRIC"]
      }
    },
    {
      "name": "previous_status",
      "type": {
        "type": "enum",
        "name": "BedStatus",
        "symbols": ["AVAILABLE", "OCCUPIED", "MAINTENANCE", "RESERVED", "CLEANING"]
      }
    },
    {"name": "new_status",        "type": "BedStatus"},
    {"name": "change_datetime",   "type": {"type": "long", "logicalType": "timestamp-millis"}},
    {"name": "admission_id",      "type": ["null", "string"], "default": null,
     "doc": "Set when status changes to OCCUPIED"},
    {"name": "reason",            "type": ["null", "string"], "default": null,
     "doc": "Reason for MAINTENANCE or RESERVED status"}
  ]
}
```

---

### 4. scheduling.appointment.booked.v1

```json
{
  "namespace": "com.medallionhealth.events.scheduling",
  "name": "AppointmentBookedPayload",
  "type": "record",
  "doc": "Emitted when a patient books an appointment.",
  "fields": [
    {"name": "appointment_id",        "type": "string", "doc": "UUID"},
    {"name": "global_patient_id",     "type": "string"},
    {"name": "hospital_mrn",          "type": "string"},
    {"name": "tenant_id",             "type": "string"},
    {"name": "doctor_id",             "type": "string"},
    {"name": "department_id",         "type": "string"},
    {"name": "appointment_datetime",  "type": {"type": "long", "logicalType": "timestamp-millis"}},
    {"name": "duration_minutes",      "type": "int", "default": 30},
    {
      "name": "appointment_type",
      "type": {
        "type": "enum",
        "name": "AppointmentType",
        "symbols": ["NEW_PATIENT", "FOLLOW_UP", "SPECIALIST_REFERRAL", "TELEMEDICINE", "PROCEDURE"]
      }
    },
    {
      "name": "booking_channel",
      "type": {
        "type": "enum",
        "name": "BookingChannel",
        "symbols": ["ONLINE", "PHONE", "IN_PERSON", "REFERRAL_SYSTEM"]
      }
    },
    {"name": "booked_at",             "type": {"type": "long", "logicalType": "timestamp-millis"},
     "doc": "When the booking was made (vs. appointment_datetime = when it occurs)"},
    {"name": "is_urgent",             "type": "boolean", "default": false}
  ]
}
```

---

### 5. scheduling.appointment.completed.v1

```json
{
  "namespace": "com.medallionhealth.events.scheduling",
  "name": "AppointmentCompletedPayload",
  "type": "record",
  "fields": [
    {"name": "appointment_id",        "type": "string"},
    {"name": "global_patient_id",     "type": "string"},
    {"name": "tenant_id",             "type": "string"},
    {"name": "doctor_id",             "type": "string"},
    {"name": "department_id",         "type": "string"},
    {"name": "scheduled_datetime",    "type": {"type": "long", "logicalType": "timestamp-millis"}},
    {"name": "actual_start_datetime", "type": {"type": "long", "logicalType": "timestamp-millis"}},
    {"name": "actual_end_datetime",   "type": {"type": "long", "logicalType": "timestamp-millis"}},
    {"name": "outcome",
      "type": {
        "type": "enum",
        "name": "AppointmentOutcome",
        "symbols": ["COMPLETED", "NO_SHOW", "CANCELLED_PATIENT", "CANCELLED_DOCTOR", "RESCHEDULED"]
      }
    },
    {"name": "led_to_admission",      "type": "boolean", "default": false},
    {"name": "admission_id",          "type": ["null", "string"], "default": null}
  ]
}
```

---

### 6. finance.billing.generated.v1

```json
{
  "namespace": "com.medallionhealth.events.finance",
  "name": "BillingGeneratedPayload",
  "type": "record",
  "doc": "Emitted when a billing record is generated for a clinical episode.",
  "fields": [
    {"name": "invoice_id",            "type": "string", "doc": "UUID"},
    {"name": "tenant_id",             "type": "string"},
    {"name": "global_patient_id",     "type": "string"},
    {"name": "admission_id",          "type": ["null", "string"], "default": null},
    {"name": "appointment_id",        "type": ["null", "string"], "default": null},
    {"name": "billing_datetime",      "type": {"type": "long", "logicalType": "timestamp-millis"}},
    {"name": "service_date",          "type": {"type": "int", "logicalType": "date"}},
    {
      "name": "line_items",
      "type": {
        "type": "array",
        "items": {
          "type": "record",
          "name": "BillingLineItem",
          "fields": [
            {"name": "cpt_code",       "type": "string", "doc": "Current Procedural Terminology code"},
            {"name": "description",    "type": "string"},
            {"name": "quantity",       "type": "int"},
            {"name": "unit_cost_cents","type": "long", "doc": "Cost in cents to avoid float precision issues"},
            {"name": "total_cents",    "type": "long"}
          ]
        }
      }
    },
    {"name": "subtotal_cents",        "type": "long"},
    {"name": "insurance_covered_cents","type": "long", "default": 0},
    {"name": "patient_responsibility_cents", "type": "long"},
    {"name": "department_id",         "type": "string"},
    {"name": "doctor_id",             "type": "string"},
    {
      "name": "payer_type",
      "type": {
        "type": "enum",
        "name": "PayerType",
        "symbols": ["PRIVATE_INSURANCE", "MEDICARE", "MEDICAID", "SELF_PAY", "WORKERS_COMP"]
      }
    }
  ]
}
```

---

### 7. workforce.doctor.availability_updated.v1

```json
{
  "namespace": "com.medallionhealth.events.workforce",
  "name": "DoctorAvailabilityUpdatedPayload",
  "type": "record",
  "doc": "Emitted when a doctor's schedule or availability changes.",
  "fields": [
    {"name": "doctor_id",         "type": "string"},
    {"name": "tenant_id",         "type": "string"},
    {"name": "department_id",     "type": "string"},
    {"name": "effective_date",    "type": {"type": "int", "logicalType": "date"}},
    {
      "name": "availability_slots",
      "type": {
        "type": "array",
        "items": {
          "type": "record",
          "name": "AvailabilitySlot",
          "fields": [
            {"name": "slot_id",         "type": "string"},
            {"name": "start_time",      "type": {"type": "long", "logicalType": "timestamp-millis"}},
            {"name": "end_time",        "type": {"type": "long", "logicalType": "timestamp-millis"}},
            {"name": "slot_type",       "type": {"type": "enum", "name": "SlotType",
             "symbols": ["APPOINTMENT", "SURGERY", "BREAK", "ADMIN", "ON_CALL"]}},
            {"name": "is_bookable",     "type": "boolean"}
          ]
        }
      }
    },
    {
      "name": "change_reason",
      "type": {
        "type": "enum",
        "name": "AvailabilityChangeReason",
        "symbols": ["REGULAR_SCHEDULE", "LEAVE", "EMERGENCY", "CONFERENCE", "SYSTEM_UPDATE"]
      }
    }
  ]
}
```

---

## Schema Evolution Rules

### Backwards-Compatible Changes (allowed without version bump)
- Adding optional fields with defaults
- Adding new enum symbols at the end

### Breaking Changes (require new version topic)
- Removing fields
- Changing field types
- Renaming fields
- Adding required fields without defaults

### Version Migration Pattern
```
Old topic: scheduling.appointment.booked.v1  (maintained, read-only)
New topic: scheduling.appointment.booked.v2  (new consumers)
Migration: Dual-write period of 30 days, then deprecate v1
```

---

## Event Validation Rules (per event type)

| Rule | Description |
|------|-------------|
| `event_id` uniqueness | Consumers track last N event_ids per topic-partition for dedup |
| `tenant_id` format | Must match `^hosp-[0-9]{3}$` |
| `global_patient_id` format | Must match `^gpid-[0-9a-f-]{36}$` |
| Timestamp ordering | `event_timestamp` <= `ingestion_timestamp` |
| Monetary values | All amounts in cents (long). Never use float for money. |
| ICD codes | Validated against ICD-10-CM reference table |
| CPT codes | Validated against CPT reference table |
