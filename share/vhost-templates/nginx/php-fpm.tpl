server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};
    server_tokens off;
    root {{ROOT}};
    index index.php index.html;
    access_log {{LOGDIR}}/access.log;
    error_log {{LOGDIR}}/error.log;
    client_max_body_size 64m;
    location ^~ /.well-known/acme-challenge/ { root {{ROOT}}; }
    location ~ /\.(env|git) { return 404; }
    location / { try_files $uri $uri/ /index.php?$query_string; }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:{{SOCK}};
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
}
