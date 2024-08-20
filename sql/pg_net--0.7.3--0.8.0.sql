create or replace function net.worker_restart() returns bool as $$
  select pg_reload_conf();
  select pg_terminate_backend(pid)
  from pg_stat_activity
  where backend_type ilike '%pg_net%';
$$
security definer
language sql;

create or replace function net.http_request(
    method text,
    url text,
    body bytea default null,
    params jsonb default '{}'::jsonb,
    headers jsonb default '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds int DEFAULT 5000,
    curl_opts jsonb default '{}'::jsonb
)
    returns bigint
    volatile
    parallel safe
    language plpgsql
as $$
declare
    request_id bigint;
    params_array text[];
    content_type text;
begin
    select
        coalesce(array_agg(net._urlencode_string(key) || '=' || net._urlencode_string(value)), '{}')
    into
        params_array
    from
        jsonb_each_text(params);

    insert into net.http_request_queue(method, url, headers, body, timeout_milliseconds, curl_opts)
    values (
        method,
        net._encode_url_with_params_array(url, params_array),
        headers,
        body,
        timeout_milliseconds,
        curl_opts
    )
    returning id
    into request_id;

    return request_id;
end
$$;
