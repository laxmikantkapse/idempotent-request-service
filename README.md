# Idempotent Request Processing Service

A production-grade Ruby on Rails backend service that accepts requests via API,
processes them asynchronously using Sidekiq background jobs, and handles all
real-world edge cases including duplicate requests, retries, concurrency, and
cancellations safely.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Ruby on Rails 7.x (API mode) |
| Language | Ruby 3.1+ |
| Database | PostgreSQL |
| Background Jobs | Sidekiq + ActiveJob |
| Queue | Redis |
| Testing | RSpec + FactoryBot + Shoulda Matchers |

---

## Architecture Overview
```
Client → Rails API → Idempotency Check → PostgreSQL
                   ↓
              Sidekiq Queue (Redis)
                   ↓
         ProcessRequestJob (worker)
                   ↓
       ProcessRequestService (business logic)
                   ↓
         Downstream service (simulated)
                   ↓
              PostgreSQL (result stored)
```

---

## Status State Machine
```
pending → processing → completed
                    → failed
       → cancelled
```

---

## Setup Instructions

### Prerequisites

- Ruby 3.1+
- Rails 7.x
- PostgreSQL 14+
- Redis 6+

### Install
```bash
git clone https://github.com/<your-username>/idempotent-request-service.git
cd idempotent-request-service

bundle install

cp config/database.yml.example config/database.yml
# Edit config/database.yml with your PostgreSQL credentials

cp .env.example .env
# Edit .env with your local settings

rails db:create db:migrate
```

### Run (3 terminals required)
```bash
# Terminal 1 - Rails server
rails server

# Terminal 2 - Sidekiq worker
bundle exec sidekiq -C config/sidekiq.yml

# Terminal 3 - Redis (if not running as a service)
redis-server
```

---

## API Reference

### Endpoints

| Method | Path | Description |
|---|---|---|
| POST | /api/v1/requests | Submit a new request |
| GET | /api/v1/requests/:id | Poll request status |
| DELETE | /api/v1/requests/:id | Cancel a request |

### Required Headers
```
Content-Type:    application/json
Idempotency-Key: <client-generated UUID>
```

### Response Codes

| Code | Meaning |
|---|---|
| 202 | Request accepted and enqueued |
| 200 | Status poll or cancellation successful |
| 400 | Missing Idempotency-Key or request_type |
| 404 | Request not found |
| 409 | Duplicate — request with this key already exists |
| 422 | Cannot cancel a terminal request |
| 500 | Unexpected server error |

> **Why 202 instead of 201?** Processing is async. 202 Accepted correctly
> signals the request is queued but not yet complete. Use GET to poll for
> the final status.

### Example Requests

**Submit a request:**
```bash
curl -X POST http://localhost:3000/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"request_type": "payment", "payload": {"amount": 500, "currency": "USD"}}'
```

**Poll status:**
```bash
curl http://localhost:3000/api/v1/requests/<id>
```

**Cancel a request:**
```bash
curl -X DELETE http://localhost:3000/api/v1/requests/<id>
```

---

## Design Decisions

### 1. Idempotency

Every request requires a client-supplied `Idempotency-Key` header. This key
is stored in the database with a unique index. Duplicate detection happens at
two layers:

- **App layer**: `find_by` check before insert returns 409 immediately
- **DB layer**: unique index + `RecordNotUnique` rescue handles race conditions
  where two concurrent requests both pass the app-layer check simultaneously

### 2. Atomic Job Acquisition (Concurrency)

The job uses a single SQL statement to acquire work:
```sql
UPDATE client_requests
SET status = 'processing'
WHERE id = ? AND status = 'pending'
```

This is an atomic operation. Only one Sidekiq worker can advance a request
from `pending` to `processing`, even under high concurrency with multiple
workers running simultaneously. Any worker that gets `rows_updated = 0`
exits immediately without doing any work.

### 3. Retry Classification

Errors are explicitly classified into two categories:

| Error Type | Behaviour | Example |
|---|---|---|
| `DownstreamError` | Reset to pending, re-raise, Sidekiq retries | Timeout, connection refused |
| `NonRetryableError` | Mark failed immediately, do NOT re-raise | Invalid business rule, bad data |

This directly addresses the "When NOT to retry" requirement. Retrying
non-transient errors wastes resources and delays failure visibility.

### 4. Retry Backoff

Sidekiq is configured with exponential backoff:
```
Retry 1: ~16s
Retry 2: ~31s
Retry 3: ~96s
Retry 4: ~271s
Retry 5: ~640s
```

Formula: `(attempt^4) + 15 + rand(30 * attempt)`

After 5 retries, `sidekiq_retries_exhausted` fires and marks the
request as `failed` permanently.

### 5. Cancellation Ordering (TOCTOU Fix)

The cancellation check happens AFTER the atomic lock acquisition,
not before. This prevents the race condition where:

1. Worker checks status → pending (not cancelled yet)
2. User cancels the request
3. Worker processes the request anyway

By checking cancellation after the lock, the worker either:
- Never acquires the lock (cancelled request stays cancelled), or
- Acquires the lock then immediately sees cancelled and exits

### 6. Optimistic Locking

The `lock_version` column enables ActiveRecord optimistic locking.
Any concurrent update with a stale version raises `ActiveRecord::StaleObjectError`,
which Sidekiq retries, preventing silent data overwrites.

### 7. Stale Job Recovery

If a Sidekiq worker crashes mid-job (OOM kill, deploy, server restart),
the request stays stuck in `processing` forever. Sidekiq's built-in retry
only works when a job raises an exception — a crashed worker raises nothing.

The recovery rake task handles this:
```bash
rails requests:recover_stale
# or with custom threshold:
STALE_MINUTES=10 rails requests:recover_stale
```

Schedule this every 15 minutes in production via cron or Sidekiq-Cron.

### 8. DB Constraints

Three layers of data integrity:

- **Unique index** on `idempotency_key` — prevents duplicates at DB level
- **Check constraint** on `status` — rejects invalid status values even if
  Rails validations are bypassed via `update_columns`
- **lock_version** — optimistic locking for concurrent updates

---

## Running Tests
```bash
bundle exec rspec --format documentation
```

Expected output:
```
ClientRequest
  ✓ validates presence of idempotency_key
  ✓ validates presence of request_type
  ✓ validates uniqueness of idempotency_key
  status predicates
    ✓ recognises pending?
    ✓ recognises processing?
    ✓ recognises completed?
    ✓ recognises failed?
    ✓ recognises cancelled?
  #terminal?
    ✓ is true for completed, failed, cancelled
    ✓ is false for pending and processing

Api::V1::Requests
  POST /api/v1/requests
    ✓ returns 202 and enqueues a job
    ✓ returns 400 for missing Idempotency-Key
    ✓ returns 409 for duplicate key
    ✓ returns 400 for missing request_type
  GET /api/v1/requests/:id
    ✓ returns 200 with the request
    ✓ returns 404 for unknown id
  DELETE /api/v1/requests/:id
    ✓ cancels a pending request
    ✓ cannot cancel a completed request

18 examples, 0 failures
```

---

## Postman Collection

Import `postman_collection.json` from the project root into Postman.

Covers 18 scenarios across 7 folders:
- Happy path (submit, poll, completed result)
- Duplicate handling (409 responses)
- Validation errors (400 responses)
- Cancellation (200, 422 responses)
- Not found (404 responses)
- Different request types
- Sidekiq dashboard check

---

## Sidekiq Dashboard
```
http://localhost:3000/sidekiq
```

Shows live queues, active workers, scheduled retries, and dead jobs.

---

## Rake Tasks
```bash
# Recover stale processing jobs
rails requests:recover_stale

# Custom threshold
STALE_MINUTES=10 rails requests:recover_stale
```

---

## Edge Cases Handled

| Edge Case | How it is handled |
|---|---|
| Duplicate requests | App-layer find_by + DB unique index + RecordNotUnique rescue |
| Retry duplication | Atomic SQL lock prevents reprocessing on retry |
| Downstream failure | DownstreamError resets to pending, Sidekiq retries with backoff |
| User cancellation | DELETE endpoint + post-lock cancellation check |
| Concurrent updates | Atomic UPDATE + optimistic locking (lock_version) |
| Slow processing | stale_processing scope + recover_stale rake task |
| Data corruption | DB check constraint on status + payload validation |
| When NOT to retry | NonRetryableError marks failed immediately, no re-raise |

---

## AI Tool Usage

This project was built with AI assistance (Claude by Anthropic). The AI was
used for:

- Scaffolding the initial project structure and migration design
- Identifying non-obvious edge cases (TOCTOU ordering in cancellation,
  status reset strategy for retryable errors, stale job recovery)
- Generating RSpec test structure and factory definitions
- Reviewing code for production readiness

All design decisions were reviewed, understood, and validated before being
included. The idempotency strategy, atomic SQL lock pattern, and retry
classification logic reflect deliberate choices made after understanding
the tradeoffs involved.
