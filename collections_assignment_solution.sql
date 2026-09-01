/* 
   1) clean accounts
*/

create table clean_accounts as

select
    account_id,
    borrower_id,
    loan_type,
    principal_amount,
    outstanding_amount,
    dpd,
    case
        when dpd <= 30 then '0-30'
        when dpd <= 60 then '31-60'
        when dpd <= 90 then '61-90'
        when dpd <= 180 then '91-180'
        else '180+'
    end as dpd_bucket,
    risk_segment,
    status as account_status,
    opened_at,
    timezone,
    schema_version
from accounts;


/* 
   2) clean payments
*/

create table clean_payments as
select distinct
    payment_id,
    account_id,
    borrower_id,
    event_at,
    payment_reference,
    amount,
    payment_status,
    payment_method,
    provider_id
from payments;


/* 
   3) successful payments
*/

create table successful_payments as
select
    payment_id,
    account_id,
    borrower_id,
    event_at,
    payment_reference,
    amount,
    payment_method,
    provider_id
from clean_payments
where payment_status = 'success';


/*
   4) remove exact duplicate call rows
*/


create table calls_dedup as
select distinct *
from calls;


/*
   5) find call ids with conflicting timestamps
*/

create table conflicting_call_ids as
select
    call_id
from calls_dedup
group by call_id
having count(distinct(event_at)) > 1;


/*
   6) clean calls
*/

create table clean_calls as
    
select *
from calls_dedup
where call_id not in
(select call_id
    from conflicting_call_ids);


/* 
   7) account-borrower map
*/


create table account_borrower_map as

select
    account_id,
    borrower_id
from clean_accounts;


/*
   8. targeting by account and month
*/


create table targeting_month as
select
    account_id,
    date_format(target_date, '%Y-%m-01') as month,
    count(distinct(target_id)) as target_count
from daily_targeting
group by account_id, date_format(target_date, '%Y-%m-01');


/* 
   9) payments by account and month
 */

create table payment_month as

select
    account_id,
    date_format(event_at, '%Y-%m-01') as month,
    sum(case
            when payment_status = 'success'
            then amount
            else 0
            end) as recovery_amount,
    sum(case
            when payment_status = 'success'
            then 1
            else 0
            end) as successful_payments
from clean_payments
group by account_id, date_format(event_at, '%Y-%m-01');


/*
   10) calls by account and month
 */


create table call_month as

select
    account_id,
    date_format(event_at, '%Y-%m-01') as month,
    count(distinct call_id) as call_count,

    sum(case
            when call_status = 'answered'
            then 1
            else 0
            end ) as answered_calls,
    sum(duration_sec) / 60.0 as call_minutes
from clean_calls
group by account_id, date_format(event_at, '%Y-%m-01');


/*
   11) golden dataset
*/

create table golden_account_month as
    
select
    a.account_id,
    a.borrower_id,
    a.loan_type,
    a.principal_amount,
    a.outstanding_amount,
    a.dpd,
    a.dpd_bucket,
    a.risk_segment,
    a.account_status,
    m.month,
    coalesce(t.target_count, 0) as target_count,
    coalesce(p.recovery_amount, 0) as recovery_amount,
    coalesce(p.successful_payments, 0) as successful_payments,
    coalesce(c.call_count, 0) as call_count,
    coalesce(c.answered_calls, 0) as answered_calls,
    coalesce(c.call_minutes, 0) as call_minutes
from clean_accounts as a
cross join
(select distinct(date_format(target_date, '%Y-%m-01')) as month
from daily_targeting
) as m
left join targeting_month as t
    on a.account_id = t.account_id
    and m.month = t.month
left join payment_month as p
    on a.account_id = p.account_id
    and m.month = p.month
left join call_month as c
    on a.account_id = c.account_id
    and m.month = c.month;


/*
   12) check golden dataset
*/

select
    count(*) as total_rows,
    count(distinct(account_id)) as unique_accounts,
    count(distinct (month)) as unique_months
from golden_account_month;


/*
   13) monthly recovery metrics
*/

select
    month,
    count(distinct account_id) as accounts,
    sum(recovery_amount) as recovery_amount,
    count(
        distinct
        case
            when recovery_amount > 0
            then account_id
        end) as recovered_accounts

from golden_account_month
group by month
order by month;
