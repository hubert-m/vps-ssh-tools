<VirtualHost *:80>
    ServerName {{DOMAIN}}
    DocumentRoot {{ROOT}}
    ErrorLog {{LOGDIR}}/error.log
    CustomLog {{LOGDIR}}/access.log combined
    ProxyPreserveHost On
    ProxyPass /.well-known/acme-challenge/ !
    ProxyPass / http://{{UPSTREAM}}/
    ProxyPassReverse / http://{{UPSTREAM}}/
    RequestHeader set X-Forwarded-Proto "http"
    <FilesMatch "^\.(env|git)">
        Require all denied
    </FilesMatch>
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-Content-Type-Options nosniff
    Header always set Referrer-Policy strict-origin-when-cross-origin
</VirtualHost>
