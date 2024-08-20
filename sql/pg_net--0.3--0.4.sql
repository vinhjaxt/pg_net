alter function net.http_request(method text, url text, body bytea, params jsonb, headers jsonb, timeout_milliseconds integer, curl_opts jsonb) security definer;
alter function net.http_collect_response(request_id bigint, async boolean) security definer;
