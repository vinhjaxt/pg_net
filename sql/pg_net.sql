
create extension if not exists pg_net;
alter system set pg_net.database_name to 'app_db';
select net.worker_restart();
