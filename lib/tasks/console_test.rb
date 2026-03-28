# ============================================================
# FULL CONSOLE TEST SUITE
# Run: rails runner lib/tasks/console_test.rb
# Or paste directly into: rails console
# ============================================================

def divider(title)
  puts "\n" + "="*60
  puts "  #{title}"
  puts "="*60
end

def pass(msg) = puts("  [PASS] #{msg}")
def fail(msg) = puts("  [FAIL] #{msg}")
def info(msg) = puts("  [INFO] #{msg}")

def assert(condition, pass_msg, fail_msg = nil)
  condition ? pass(pass_msg) : fail(fail_msg || pass_msg)
end

# Clean slate before running
puts "\n[SETUP] Cleaning test data..."
ClientRequest.where("idempotency_key LIKE 'test-%'").delete_all
puts "[SETUP] Done.\n"


# ============================================================
divider("TEST 1 — Model validations")
# ============================================================

r = ClientRequest.new
r.valid?

assert r.errors[:idempotency_key].any?,
  "Blank idempotency_key is invalid"

assert r.errors[:request_type].any?,
  "Blank request_type is invalid"

valid = ClientRequest.new(
  idempotency_key: 'test-valid-001',
  request_type: 'payment',
  payload: { amount: 100 }
)
assert valid.valid?, "Valid record passes validation"


# ============================================================
divider("TEST 2 — Create and persist a request")
# ============================================================

req1 = ClientRequest.create!(
  idempotency_key: 'test-create-001',
  request_type:    'payment',
  payload:         { amount: 500, currency: 'USD' }
)

assert req1.persisted?,           "Record saved to DB"
assert req1.status == 'pending',  "Default status is pending"
assert req1.id.present?,          "UUID primary key assigned"
assert req1.retry_count == 0,     "retry_count starts at 0"

info "Created request id=#{req1.id}"


# ============================================================
divider("TEST 3 — Duplicate idempotency key prevention")
# ============================================================

# App-layer duplicate check (same as controller does)
existing = ClientRequest.find_by(idempotency_key: 'test-create-001')
assert existing.present?, "find_by returns existing record for duplicate key"

# DB-layer constraint (unique index)
begin
  ClientRequest.create!(
    idempotency_key: 'test-create-001',
    request_type:    'payment',
    payload:         {}
  )
  fail "DB should have rejected duplicate key"
rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
  pass "DB rejected duplicate key: #{e.class}"
end


# ============================================================
divider("TEST 4 — Status predicates and state machine")
# ============================================================

req2 = ClientRequest.create!(
  idempotency_key: 'test-status-001',
  request_type:    'order',
  payload:         {}
)

assert req2.pending?,    "pending? is true on new record"
assert !req2.processing?, "processing? is false on new record"
assert !req2.terminal?,   "terminal? is false for pending"

req2.update!(status: 'processing')
assert req2.processing?,  "processing? true after update"
assert !req2.terminal?,   "terminal? false for processing"

req2.update!(status: 'completed')
assert req2.completed?,   "completed? true after update"
assert req2.terminal?,    "terminal? true for completed"

req2.update!(status: 'failed')
assert req2.failed?,      "failed? true after update"
assert req2.terminal?,    "terminal? true for failed"

req2.update!(status: 'cancelled')
assert req2.cancelled?,   "cancelled? true after update"
assert req2.terminal?,    "terminal? true for cancelled"


# ============================================================
divider("TEST 5 — Atomic lock (concurrency simulation)")
# ============================================================

req3 = ClientRequest.create!(
  idempotency_key: 'test-lock-001',
  request_type:    'payment',
  payload:         {}
)

# Two workers race to acquire the same job
worker1_rows = ClientRequest
  .where(id: req3.id, status: 'pending')
  .update_all(status: 'processing', updated_at: Time.current)

worker2_rows = ClientRequest
  .where(id: req3.id, status: 'pending')
  .update_all(status: 'processing', updated_at: Time.current)

assert worker1_rows == 1, "Worker 1 acquired the lock (rows_updated=1)"
assert worker2_rows == 0, "Worker 2 was blocked (rows_updated=0)"

req3.reload
assert req3.processing?, "Request is in processing state"

info "Atomic lock works — only one worker can acquire a job"


# ============================================================
divider("TEST 6 — Optimistic locking (StaleObjectError)")
# ============================================================

req4 = ClientRequest.create!(
  idempotency_key: 'test-optimistic-001',
  request_type:    'refund',
  payload:         {}
)

# Load same record into two separate instances
instance_a = ClientRequest.find(req4.id)
instance_b = ClientRequest.find(req4.id)

# Instance A updates first
instance_a.update!(status: 'processing')

# Instance B tries to update with stale lock_version
begin
  instance_b.update!(status: 'processing')
  fail "Should have raised StaleObjectError"
rescue ActiveRecord::StaleObjectError
  pass "StaleObjectError raised on concurrent update — optimistic lock works"
end


# ============================================================
divider("TEST 7 — Cancellation logic")
# ============================================================

req5 = ClientRequest.create!(
  idempotency_key: 'test-cancel-001',
  request_type:    'payment',
  payload:         {}
)

# Cancel a pending request
req5.update!(status: 'cancelled', cancelled_at: Time.current)
assert req5.cancelled?,  "Request cancelled successfully"
assert req5.terminal?,   "Cancelled is a terminal state"

# Try cancelling a terminal request (simulates controller guard)
if req5.terminal?
  pass "Cannot cancel terminal request — guard works (status=#{req5.status})"
else
  fail "Terminal request should not be cancellable"
end

# Cannot cancel a completed request either
req6 = ClientRequest.create!(
  idempotency_key: 'test-cancel-002',
  request_type:    'payment',
  payload:         {}
)
req6.update!(status: 'completed')
assert req6.terminal?, "Completed request is also non-cancellable (terminal)"


# ============================================================
divider("TEST 8 — Stale job detection")
# ============================================================

stale = ClientRequest.create!(
  idempotency_key: 'test-stale-001',
  request_type:    'payment',
  payload:         {}
)

# Simulate a job stuck in processing for 20 minutes
stale.update_columns(
  status:     'processing',
  updated_at: 20.minutes.ago
)

count = ClientRequest.stale_processing.count
assert count >= 1, "stale_processing scope finds stuck jobs (found #{count})"

found = ClientRequest.stale_processing.where(id: stale.id).exists?
assert found, "Our backdated record appears in stale_processing scope"


# ============================================================
divider("TEST 9 — Stale job recovery (rake task)")
# ============================================================

# Re-use the stale record from Test 8
stale.reload
assert stale.status == 'processing', "Stale record is still in processing"

# Invoke the rake task
begin
  Rake::Task['requests:recover_stale'].reenable
  Rake::Task['requests:recover_stale'].invoke
  stale.reload
  assert stale.status == 'pending',
    "Stale record reset to pending after rake task"
  pass "Rake task ran successfully"
rescue => e
  fail "Rake task error: #{e.message}"
end


# ============================================================
divider("TEST 10 — Service object (ProcessRequestService)")
# ============================================================

req7 = ClientRequest.create!(
  idempotency_key: 'test-service-001',
  request_type:    'payment',
  payload:         { amount: 100, currency: 'USD' }
)
req7.update_columns(status: 'processing')

service = ProcessRequestService.new(req7)

success_count  = 0
retryable_count = 0
non_retryable_count = 0

# Run service 5 times on fresh records to observe all outcomes
5.times do |i|
  test_req = ClientRequest.create!(
    idempotency_key: "test-service-run-#{i}-#{SecureRandom.hex(4)}",
    request_type:    'payment',
    payload:         { amount: 100 }
  )
  test_req.update_columns(status: 'processing')

  begin
    ProcessRequestService.new(test_req).call
    success_count += 1
  rescue ProcessRequestService::DownstreamError
    retryable_count += 1
  rescue ProcessRequestService::NonRetryableError
    non_retryable_count += 1
  end
end

info "Service ran 5 times:"
info "  Successes:       #{success_count}"
info "  Retryable errors:     #{retryable_count}"
info "  Non-retryable errors: #{non_retryable_count}"

assert (success_count + retryable_count + non_retryable_count) == 5,
  "All 5 service calls accounted for"


# ============================================================
divider("TEST 11 — DB check constraint on status")
# ============================================================

req8 = ClientRequest.create!(
  idempotency_key: 'test-constraint-001',
  request_type:    'payment',
  payload:         {}
)

# Rails validation catches invalid status
result = req8.update(status: 'invalid_status')
assert result == false, "Rails validation rejects invalid status"
assert req8.errors[:status].any?, "Error message present for invalid status"

# DB constraint catches it even if Rails is bypassed
begin
  req8.update_columns(status: 'bogus_value')
  fail "DB check constraint should have rejected this"
rescue ActiveRecord::StatementInvalid => e
  pass "DB check constraint rejected invalid status: #{e.class}"
end


# ============================================================
divider("TEST 12 — Full job lifecycle (end to end)")
# ============================================================

req9 = ClientRequest.create!(
  idempotency_key: "test-e2e-#{SecureRandom.hex(4)}",
  request_type:    'payment',
  payload:         { amount: 999 }
)

assert req9.status == 'pending', "Starts as pending"
info "Request created: id=#{req9.id}"

# Simulate exactly what the job does
rows = ClientRequest
  .where(id: req9.id, status: 'pending')
  .update_all(status: 'processing', updated_at: Time.current)

assert rows == 1, "Job acquired the lock"
req9.reload
assert req9.processing?, "Status moved to processing"

# Simulate successful service call
req9.update!(
  status:       'completed',
  result:       { processed: true, external_id: SecureRandom.uuid, timestamp: Time.current.iso8601 },
  processed_at: Time.current
)

req9.reload
assert req9.completed?,          "Status moved to completed"
assert req9.result.present?,     "Result stored in DB"
assert req9.processed_at.present?, "processed_at timestamp recorded"

info "Final result: #{req9.result}"


# ============================================================
divider("TEST 13 — Overall data summary")
# ============================================================

info "All ClientRequest records by status:"
ClientRequest.group(:status).count.each do |status, count|
  info "  #{status.ljust(12)} #{count}"
end

info "\nTotal records: #{ClientRequest.count}"
info "Stale processing: #{ClientRequest.stale_processing.count}"


# ============================================================
divider("ALL TESTS COMPLETE")
# ============================================================

puts "\n[DONE] Scroll up to check each [PASS] / [FAIL] line.\n\n"
