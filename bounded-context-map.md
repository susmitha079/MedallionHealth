# Bounded Context Map – MedallionHealth

## Overview

MedallionHealth is decomposed into **6 bounded contexts** following Domain-Driven Design (DDD)
principles. Each context owns its data, publishes domain events, and communicates with other
contexts exclusively through well-defined event contracts.

> **Design Principle:** No direct database cross-context joins in operational systems.
> All cross-context data sharing happens via events (async) or the analytics warehouse (read-only).

---

## Bounded Context Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        MedallionHealth Domain Map                            │
└─────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────┐
  │  IDENTITY CONTEXT                                                        │
  │  ┌────────────────────────────────────────────────────────────────────┐ │
  │  │  Entities: Patient, GlobalPatientId, HospitalMRN, TenantMapping   │ │
  │  │  Events:   patient.registered, patient.updated, patient.merged     │ │
  │  │  Service:  patient-service (Spring Boot)                           │ │
  │  │  Owner:    Identity Domain Team                                    │ │
  │  └────────────────────────────────────────────────────────────────────┘ │
  │  Key Rule: Issues GLOBAL_PATIENT_ID. All other contexts reference this.  │
  └──────────────────────────────┬──────────────────────────────────────────┘
                                 │ publishes identity.patient.registered.v1
                                 ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  CLINICAL CONTEXT                                                        │
  │  ┌────────────────────────────────────────────────────────────────────┐ │
  │  │  Entities: Admission, Discharge, Diagnosis, Procedure, ICUStay    │ │
  │  │  Events:   admission.created, discharge.completed, icu.assigned   │ │
  │  │  Service:  admission-service (Spring Boot)                        │ │
  │  │  Owner:    Clinical Domain Team                                   │ │
  │  └────────────────────────────────────────────────────────────────────┘ │
  │  Key Rule: Consumes patient identity. Owns clinical episode lifecycle.   │
  └──────────────────────────────┬──────────────────────────────────────────┘
                                 │
          ┌──────────────────────┼──────────────────────┐
          ▼                      ▼                       ▼
  ┌────────────────┐    ┌─────────────────┐   ┌─────────────────────────────┐
  │  OPERATIONS    │    │   SCHEDULING    │   │       FINANCE CONTEXT       │
  │  CONTEXT       │    │   CONTEXT       │   │                             │
  │                │    │                 │   │  Entities: Invoice, Payment │
  │  Entities:     │    │  Entities:      │   │           InsuranceClaim    │
  │  Bed, Ward,    │    │  Appointment,   │   │  Events:                    │
  │  BedAssignment │    │  Slot, Doctor   │   │   billing.generated         │
  │                │    │  Availability   │   │   payment.received          │
  │  Events:       │    │                 │   │   claim.submitted           │
  │  bed.status    │    │  Events:        │   │                             │
  │  bed.assigned  │    │  appt.booked    │   │  Service: billing-service   │
  │                │    │  appt.cancelled │   │                             │
  │  Service:      │    │  appt.completed │   │  Key Rule: Consumes         │
  │  bed-mgmt-svc  │    │                 │   │  admission + appointment    │
  │                │    │  Service:       │   │  events to generate billing │
  └────────────────┘    │  appt-service   │   └─────────────────────────────┘
                        └─────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────┐
  │  WORKFORCE CONTEXT                                                       │
  │  ┌────────────────────────────────────────────────────────────────────┐ │
  │  │  Entities: Doctor, Department, Shift, Availability                │ │
  │  │  Events:   doctor.registered, availability.updated, shift.changed │ │
  │  │  Service:  doctor-service (Spring Boot)                           │ │
  │  │  Owner:    HR/Workforce Domain Team                               │ │
  │  └────────────────────────────────────────────────────────────────────┘ │
  │  Key Rule: Source of truth for doctor schedules and department data.     │
  └─────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────┐
  │  AUDIT CONTEXT  (Cross-Cutting Concern)                                  │
  │  ┌────────────────────────────────────────────────────────────────────┐ │
  │  │  Entities: AuditEntry, DataAccessLog, ComplianceEvent             │ │
  │  │  Consumes: ALL domain events (fan-out subscription)               │ │
  │  │  Service:  audit-service (Spring Boot)                            │ │
  │  │  Key Rule: READ-ONLY consumer. Never mutates other contexts.      │ │
  │  └────────────────────────────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────────────────────┘
```

---

## Context Interaction Map

| Producer Context | Event | Consumer Contexts |
|-----------------|-------|------------------|
| Identity | patient.registered | Clinical, Scheduling, Finance, Audit |
| Identity | patient.updated | Clinical, Audit |
| Clinical | admission.created | Operations, Finance, Audit |
| Clinical | discharge.completed | Operations, Finance, Audit |
| Operations | bed.status_changed | Clinical, Audit |
| Scheduling | appointment.booked | Clinical, Finance, Workforce, Audit |
| Scheduling | appointment.completed | Finance, Audit |
| Workforce | availability.updated | Scheduling, Audit |
| Finance | billing.generated | Audit |
| Finance | payment.received | Audit |

---

## Multi-Tenant Design Rules

```
┌──────────────────────────────────────────────────────────────┐
│  TENANT ISOLATION MODEL                                       │
│                                                              │
│  Global Namespace                                            │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  GLOBAL_PATIENT_ID  (UUID, system-wide unique)         │ │
│  │  Issued by: Identity Context                           │ │
│  │  Format: gpid-{uuid4}                                 │ │
│  │  Example: gpid-550e8400-e29b-41d4-a716-446655440000   │ │
│  └────────────────────────────────────────────────────────┘ │
│                         │                                    │
│          ┌──────────────┼──────────────┐                    │
│          ▼              ▼              ▼                     │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐        │
│  │ Hospital 001 │ │ Hospital 002 │ │ Hospital 050 │        │
│  │ tenant_id:   │ │ tenant_id:   │ │ tenant_id:   │        │
│  │ hosp-001     │ │ hosp-002     │ │ hosp-050     │        │
│  │              │ │              │ │              │        │
│  │ MRN: H001-   │ │ MRN: H002-   │ │ MRN: H050-   │        │
│  │ 000001       │ │ 000001       │ │ 000001       │        │
│  └──────────────┘ └──────────────┘ └──────────────┘        │
└──────────────────────────────────────────────────────────────┘
```

### Tenant ID Format
```
tenant_id: hosp-{zero_padded_3_digit_number}
Examples:  hosp-001, hosp-023, hosp-050
```

### Patient ID Strategy
```
Field             | Scope          | Format                                    | Owner
------------------|----------------|-------------------------------------------|------------------
global_patient_id | Platform-wide  | gpid-{uuid4}                              | Identity Context
hospital_mrn      | Per-tenant     | {HOSPITAL_CODE}-{zero_padded_6_digit_num} | Each Hospital
tenant_id         | All tables     | hosp-{NNN}                                | Platform-wide
```

### Data Isolation Rules
1. `tenant_id` is present in **every** table across all layers (Bronze, Silver, Gold, Redshift)
2. Row-level security in Redshift enforces tenant isolation
3. Kafka partition key is always `tenant_id` — ensures ordered processing per hospital
4. S3 paths always include `tenant_id` as a partition column
5. No cross-tenant queries are permitted in operational systems

---

## Aggregate Definitions per Context

### Identity Context Aggregates

```
Patient (Aggregate Root)
├── global_patient_id        PK
├── tenant_id                FK → Hospital
├── hospital_mrn             unique per tenant
├── demographics
│   ├── first_name           (PII - masked in analytics)
│   ├── last_name            (PII - masked in analytics)
│   ├── date_of_birth        (PII - masked in analytics)
│   ├── gender
│   └── blood_type
├── contact
│   ├── email                (PII - tokenized)
│   ├── phone                (PII - tokenized)
│   └── address              (PII - masked)
├── insurance
│   ├── insurance_provider
│   ├── policy_number        (tokenized)
│   └── group_number
└── audit
    ├── created_at
    ├── updated_at
    └── created_by_tenant_id
```

### Clinical Context Aggregates

```
Admission (Aggregate Root)
├── admission_id             PK
├── global_patient_id        FK → Identity
├── tenant_id
├── hospital_mrn             (denormalized for performance)
├── admission_type           [EMERGENCY, ELECTIVE, TRANSFER]
├── admission_datetime
├── discharge_datetime       (nullable)
├── primary_diagnosis_code   (ICD-10)
├── attending_doctor_id      FK → Workforce
├── department_id            FK → Workforce
├── bed_id                   FK → Operations
└── status                   [ACTIVE, DISCHARGED, TRANSFERRED]
```

### Operations Context Aggregates

```
Bed (Aggregate Root)
├── bed_id                   PK
├── tenant_id
├── ward_id
├── bed_number
├── bed_type                 [GENERAL, ICU, EMERGENCY, SURGICAL]
├── status                   [AVAILABLE, OCCUPIED, MAINTENANCE, RESERVED]
├── current_admission_id     FK → Clinical (nullable)
└── last_status_change       timestamp
```
