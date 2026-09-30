-- federation-deliver claims due jobs here. Claiming pushes next_attempt_at
-- out pessimistically, so a worker that dies mid-send doesn't leave jobs
-- stuck and two workers never take the same job.

create or replace function claim_federation_jobs(p_limit int default 50)
returns setof federation_job
language plpgsql security definer set search_path = public as $$
begin
  return query
  with due as (
    select id from federation_job
    where done_at is null and next_attempt_at <= now()
    order by id
    limit p_limit
    for update skip locked
  )
  update federation_job j
     set attempts = j.attempts + 1,
         next_attempt_at = now() + interval '10 minutes'
    from due where j.id = due.id
  returning j.*;
end;
$$;

-- Backoff after a failed attempt: 1m, 5m, 30m, 2h, 12h, then give up.
create or replace function finish_federation_job(p_id bigint, p_ok boolean, p_error text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_attempts int;
begin
  select attempts into v_attempts from federation_job where id = p_id;
  if p_ok then
    update federation_job set done_at = now(), last_error = null where id = p_id;
  elsif v_attempts >= 6 then
    update federation_job set done_at = now(), last_error = 'gave up: ' || coalesce(p_error, '') where id = p_id;
  else
    update federation_job
       set last_error = p_error,
           next_attempt_at = now() + (array['1 minute','5 minutes','30 minutes','2 hours','12 hours'])[v_attempts]::interval
     where id = p_id;
  end if;
  delete from federation_job where done_at < now() - interval '14 days';
  delete from federation_inbox_seen where received_at < now() - interval '30 days';
end;
$$;

revoke all on function claim_federation_jobs(int) from public, anon, authenticated;
revoke all on function finish_federation_job(bigint, boolean, text) from public, anon, authenticated;
grant execute on function claim_federation_jobs(int) to service_role;
grant execute on function finish_federation_job(bigint, boolean, text) to service_role;
