# lua-resty-cloudscale
I hate microservices.

This system spawns background worker processes (e.g. Minio processes) in response to frontend HTTP(s) requests.
It manages these processes using `lua-resty-exec` and shuts them down after a configurable timeout period.

```
http {
  lua_shared_dict minio 10m;
  resolver 8.8.8.8 8.8.4.4;
  init_worker_by_lua_block
  {
    ...
  }

  server {
      listen 80 default_server;
      listen 443 ssl default_server;

      server_name minio.domain.com;

      location / {
          client_body_buffer_size 1024m;
          client_max_body_size 1024m;
          client_body_in_single_buffer on;

          access_by_lua_block { ...:authenticate() }
          proxy_buffering off;
          proxy_set_header Host $http_host;
          proxy_pass http://<minio host>/;
      }
  }
}

```
