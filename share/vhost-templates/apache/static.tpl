<VirtualHost *:80>
    ServerName {{DOMAIN}}
    DocumentRoot {{ROOT}}
    ErrorLog {{LOGDIR}}/error.log
    CustomLog {{LOGDIR}}/access.log combined
    <Directory {{ROOT}}>
        Require all granted
        Options -Indexes
    </Directory>
    Alias /.well-known/acme-challenge/ {{ROOT}}/.well-known/acme-challenge/
    <FilesMatch "^\.(env|git)">
        Require all denied
    </FilesMatch>
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-Content-Type-Options nosniff
    Header always set Referrer-Policy strict-origin-when-cross-origin
</VirtualHost>
