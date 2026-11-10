server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};
    server_tokens off;
    root {{ROOT}};
    access_log {{LOGDIR}}/access.log;
    error_log {{LOGDIR}}/error.log;
    location ^~ /.well-known/acme-challenge/ { root {{ROOT}}; }
    location ~ /\.(env|git) { return 404; }
    location / { try_files $uri $uri/ =404; }
    location ~* \.(css|js|png|jpg|jpeg|gif|svg|woff2)$ { expires 7d; access_log off; }
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
}
