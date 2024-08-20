create or replace function net.http_request(
    -- method for the request
    method text,
    -- url for the request
    url text,
    -- body of the POST request
    body bytea default null,
    -- key/value pairs to be url encoded and appended to the `url`
    params jsonb default '{}'::jsonb,
    -- key/values to be included in request headers
    headers jsonb default '{"User-Agent": "-"}'::jsonb,
    -- the maximum number of milliseconds the request may take before being cancelled
    timeout_milliseconds int DEFAULT 1000,

    curl_opts jsonb default '{}'::jsonb
)
    -- request_id reference
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

    -- Add to the request queue
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
