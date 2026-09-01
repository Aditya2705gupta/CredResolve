-- Synthetic Collections Analytics
-- Beginner-friendly SQL repository
-- The exact syntax may need small changes depending on the SQL engine.

-- ============================================================
-- 01. Clean accounts
-- ============================================================

CREATE TABLE clean_accounts AS
SELECT
    account_id,
    borrower_id,
    loan_type,
    principal_amount,
    outstanding_amount,
    dpd,
    CASE
        WHEN dpd <= 30 THEN '0-30'
        WHEN dpd <= 60 THEN '31-60'
        WHEN dpd <= 90 THEN '61-90'
        WHEN dpd <= 180 THEN '91-180'
        ELSE '180+'
    END AS dpd_bucket,
    risk_segment,
    status AS account_status,
    opened_at,
    timezone,
    schema_version
FROM accounts;


-- ============================================================
-- 02. Clean payments
-- ============================================================

-- Exact duplicates are safe to remove because every field is identical.
CREATE TABLE clean_payments AS
SELECT DISTINCT
    payment_id,
    account_id,
    borrower_id,
    event_at,
    payment_reference,
    amount,
    payment_status,
    payment_method,
    provider_id
FROM payments;

-- Do not use payment_reference as a primary key.
-- The same reference can occur for different payment IDs/accounts.

CREATE TABLE successful_payments AS
SELECT
    payment_id,
    account_id,
    event_at,
    amount
FROM clean_payments
WHERE payment_status = 'SUCCESS';


-- ============================================================
-- 03. Clean calls
-- ============================================================

-- First remove exact duplicate rows.
CREATE TABLE calls_dedup AS
SELECT DISTINCT *
FROM calls;

-- Find call IDs with conflicting timestamps.
CREATE TABLE conflicting_call_ids AS
SELECT call_id
FROM calls_dedup
GROUP BY call_id
HAVING COUNT(DISTINCT event_at) > 1;

-- Exclude ambiguous timestamp records from performance metrics.
CREATE TABLE clean_calls AS
SELECT *
FROM calls_dedup
WHERE call_id NOT IN (
    SELECT call_id
    FROM conflicting_call_ids
);

-- If a duplicated call has one missing agent ID and one known agent ID,
-- retain the known-agent record. In a production implementation this
-- can be done with ROW_NUMBER() ordered by agent_id IS NULL.


-- ============================================================
-- 04. Canonical borrower mapping
-- ============================================================

-- The account table is the source of truth for borrower_id.
-- Event-level borrower_id values are not trusted.

CREATE TABLE account_borrower_map AS
SELECT
    account_id,
    borrower_id
FROM clean_accounts;


-- ============================================================
-- 05. Monthly targeting
-- ============================================================

CREATE TABLE targeting_month AS
SELECT
    account_id,
    DATE_TRUNC('month', target_date) AS month,
    COUNT(DISTINCT target_id) AS target_count
FROM daily_targeting
GROUP BY account_id, DATE_TRUNC('month', target_date);


-- ============================================================
-- 06. Monthly payments
-- ============================================================

CREATE TABLE payment_month AS
SELECT
    account_id,
    DATE_TRUNC('month', event_at) AS month,
    SUM(CASE WHEN payment_status = 'SUCCESS' THEN amount ELSE 0 END)
        AS recovery_amount,
    SUM(CASE WHEN payment_status = 'SUCCESS' THEN 1 ELSE 0 END)
        AS successful_payments
FROM clean_payments
GROUP BY account_id, DATE_TRUNC('month', event_at);


-- ============================================================
-- 07. Monthly calls
-- ============================================================

CREATE TABLE call_month AS
SELECT
    account_id,
    DATE_TRUNC('month', event_at) AS month,
    COUNT(DISTINCT call_id) AS call_count,
    SUM(CASE WHEN call_status = 'ANSWERED' THEN 1 ELSE 0 END)
        AS answered_calls,
    SUM(duration_sec) / 60.0 AS call_minutes
FROM clean_calls
GROUP BY account_id, DATE_TRUNC('month', event_at);


-- ============================================================
-- 08. Final account-month analytical layer
-- ============================================================

-- Important: each event table must be aggregated to account-month
-- before joining. This prevents many-to-many multiplication.

CREATE TABLE golden_account_month AS
SELECT
    a.account_id,
    a.borrower_id,
    a.loan_type,
    a.principal_amount,
    a.outstanding_amount,
    a.dpd,
    a.dpd_bucket,
    a.risk_segment,
    a.account_status,
    t.month,
    COALESCE(t.target_count, 0) AS target_count,
    COALESCE(p.recovery_amount, 0) AS recovery_amount,
    COALESCE(p.successful_payments, 0) AS successful_payments,
    COALESCE(c.call_count, 0) AS call_count,
    COALESCE(c.answered_calls, 0) AS answered_calls,
    COALESCE(c.call_minutes, 0) AS call_minutes
FROM clean_accounts a
CROSS JOIN (
    SELECT DISTINCT DATE_TRUNC('month', target_date) AS month
    FROM daily_targeting
) t
LEFT JOIN targeting_month tg
    ON a.account_id = tg.account_id
   AND t.month = tg.month
LEFT JOIN payment_month p
    ON a.account_id = p.account_id
   AND t.month = p.month
LEFT JOIN call_month c
    ON a.account_id = c.account_id
   AND t.month = c.month;


-- ============================================================
-- 09. Monthly recovery metrics
-- ============================================================

SELECT
    month,
    COUNT(DISTINCT account_id) AS accounts,
    SUM(recovery_amount) AS recovery_amount,
    COUNT(DISTINCT CASE WHEN recovery_amount > 0 THEN account_id END)
        AS recovered_accounts
FROM golden_account_month
GROUP BY month
ORDER BY month;
