create schema if not exists net;
CREATE EXTENSION pg_net;

-- Store pending requests. The background worker reads from here
-- API: Private
create unlogged table net.http_request_queue(
    id bigserial,
    method text not null,
    url text not null,
    headers jsonb,
    body bytea,
    timeout_milliseconds int not null,
    curl_opts jsonb
);

create or replace function net.check_worker_is_up() returns void as $$
begin
  if not exists (select pid from pg_stat_activity where backend_type ilike '%pg_net%') then
    raise exception using
      message = 'the pg_net background worker is not up'
    , detail  = 'the pg_net background worker is down due to an internal error and cannot process requests'
    , hint    = 'make sure that you didn''t modify any of pg_net internal tables';
  end if;
end
$$ language plpgsql;
comment on function net.check_worker_is_up() is 'raises an exception if the pg_net background worker is not up, otherwise it doesn''t return anything';

-- Associates a response with a request
-- API: Private
create unlogged table net._http_response(
    id bigint,
    status_code integer,
    content_type text,
    headers jsonb,
    content text,
    timed_out bool,
    error_msg text,
    created timestamptz not null default now()
);

create index on net._http_response (created);

-- Blocks until an http_request is complete
-- API: Private
create or replace function net._await_response(
    request_id bigint
)
    returns bool
    volatile
    parallel safe
    strict
    language plpgsql
as $$
declare
    rec net._http_response;
begin
    while rec is null loop
        select *
        into rec
        from net._http_response
        where id = request_id;

        if rec is null then
            -- Wait 1200 ms before checking again
            perform pg_sleep(1.2);
        end if;
    end loop;

    return true;
end;
$$;

-- url encode a string
-- API: Private
create or replace function net._urlencode_string(string varchar)
    -- url encoded string
    returns text

    language 'c'
    immutable
    strict
as 'pg_net';

-- API: Private
create or replace function net._encode_url_with_params_array(url text, params_array text[])
    -- url encoded string
    returns text
    strict
    language 'c'
    immutable
as 'pg_net';

create or replace function net.net_curl_version()
    returns text
    strict
    language 'c'
    immutable
as 'pg_net';

create or replace function net.url_params(
    -- url for the request
    url text,
    -- key/value pairs to be url encoded and appended to the `url`
    params jsonb default '{}'::jsonb
)
    returns text
    volatile
    parallel safe
    language plpgsql
    security definer
as $$
declare
    params_array text[];
begin
    select
        coalesce(array_agg(net._urlencode_string(key) || '=' || net._urlencode_string(value)), '{}')
    into
        params_array
    from
        jsonb_each_text(params);

    return net._encode_url_with_params_array(url, params_array);
end
$$;

-- Interface to make an async request and wait for response
-- API: Public
create or replace function net.http_request(
    -- method for the request
    method text,
    -- url for the request
    url text,
    -- body of the POST request
    body bytea default null,
    -- key/values to be included in request headers
    headers jsonb default '{"User-Agent": "-"}'::jsonb,
    -- the maximum number of milliseconds the request may take before being cancelled
    timeout_milliseconds int default 7000,
    -- curl options {"option_int": option_value}
    curl_opts jsonb default null
)
    -- http response composite wrapped in a result type
    returns net.http_response_result
    strict
    volatile
    parallel safe
    language plpgsql
    security definer
as $$
declare
    request_id bigint;
begin
    call net.http_add_queue(request_id, method, url, headers, body, timeout_milliseconds, curl_opts);
    return net._http_collect_response(request_id, true);
end
$$;

-- Interface to make an async request
-- API: Public
create or replace procedure net.http_add_queue(
    -- out value
    request_id inout bigint,
    -- method for the request
    method text,
    -- url for the request
    url text,
    -- body of the POST request
    body bytea default null,
    -- key/values to be included in request headers
    headers jsonb default '{"User-Agent": "-"}'::jsonb,
    -- the maximum number of milliseconds the request may take before being cancelled
    timeout_milliseconds int default 7000,
    -- curl options {"option_int": option_value}
    curl_opts jsonb default null
) language plpgsql security definer as $$
declare
    params_array text[];
    content_type text;
begin
    insert into net.http_request_queue(method, url, headers, body, timeout_milliseconds, curl_opts)
    values (method, url, headers, body, timeout_milliseconds, curl_opts)
    returning id
    into request_id;
    commit;
end
$$;

-- Lifecycle states of a request (all protocols)
-- API: Public
create type net.request_status as enum ('PENDING', 'SUCCESS', 'ERROR');


-- A response from an HTTP server
-- API: Public
create type net.http_response AS (
    status_code integer,
    headers jsonb,
    body text
);

-- State wrapper around responses
-- API: Public
create type net.http_response_result as (
    status net.request_status,
    message text,
    response net.http_response
);


-- Collect respones of an http request
-- API: Private
create or replace function net._http_collect_response(
    -- request_id reference
    request_id bigint,
    -- when `true`, return immediately. when `false` wait for the request to complete before returning
    async bool default true
)
    -- http response composite wrapped in a result type
    returns net.http_response_result
    strict
    volatile
    parallel safe
    language plpgsql
    security definer
as $$
declare
    rec net._http_response;
    req_exists boolean;
begin

    if not async then
        perform net._await_response(request_id);
    end if;

    select *
    into rec
    from net._http_response
    where id = request_id;

    if rec is null or rec.error_msg is not null then
        -- The request is either still processing or the request_id provided does not exist

        -- TODO: request in progress is indistinguishable from request that doesn't exist

        -- No request matching request_id found
        return (
            'ERROR',
            coalesce(rec.error_msg, 'request matching request_id not found'),
            null
        )::net.http_response_result;

    end if;

    -- Return a valid, populated http_response_result
    return (
        'SUCCESS',
        'ok',
        (
            rec.status_code,
            rec.headers,
            rec.content
        )::net.http_response
    )::net.http_response_result;
end;
$$;

create or replace function net.http_collect_response(
    -- request_id reference
    request_id bigint,
    -- when `true`, return immediately. when `false` wait for the request to complete before returning
    async bool default true
)
    -- http response composite wrapped in a result type
    returns net.http_response_result
    strict
    volatile
    parallel safe
    language plpgsql
    security definer
as $$
begin
  raise notice 'The net.http_collect_response function is deprecated.';
  select net._http_collect_response(request_id, async);
end;
$$;

create or replace function net.worker_restart() returns bool as $$
  select pg_reload_conf();
  select pg_terminate_backend(pid)
  from pg_stat_activity
  where backend_type ilike '%pg_net%';
$$
security definer
language sql;

grant all on schema net to postgres;
grant all on all tables in schema net to postgres;
