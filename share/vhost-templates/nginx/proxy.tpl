server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};
    server_tokens off;
    root {{ROOT}};
    access_log {{LOGDIR}}/access.log;
    error_log {{LOGDIR}}/error.log;
    client_max_body_size 64m;
    location ^~ /.well-known/acme-challenge/ { root {{ROOT}}; }
    location ~ /\.(env|git) { return 404; }
    location / {
        proxy_pass http://{{UPSTREAM}};
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 60s;
    }
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
}
