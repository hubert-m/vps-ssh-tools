<VirtualHost *:80>
    ServerName {{DOMAIN}}
    DocumentRoot {{ROOT}}
    ErrorLog {{LOGDIR}}/error.log
    CustomLog {{LOGDIR}}/access.log combined
    DirectoryIndex index.php index.html
    <Directory {{ROOT}}>
        Require all granted
        FallbackResource /index.php
    </Directory>
    ProxyPassMatch "^/(.*\.php(/.*)?)$" "unix:{{SOCK}}|fcgi://localhost{{ROOT}}"
    <FilesMatch "^\.(env|git)">
        Require all denied
    </FilesMatch>
    Alias /.well-known/acme-challenge/ {{ROOT}}/.well-known/acme-challenge/
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-Content-Type-Options nosniff
    Header always set Referrer-Policy strict-origin-when-cross-origin
</VirtualHost>
