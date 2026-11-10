docRoot                   {{ROOT}}
vhDomain                  {{DOMAIN}}
vhAliases                 www.{{DOMAIN}}

errorlog {{LOGDIR}}/error.log {
  useServer               0
  logLevel                WARN
  rollingSize             10M
}

accesslog {{LOGDIR}}/access.log {
  useServer               0
  rollingSize             10M
}

index  {
  useServer               0
  indexFiles              index.html
}

context /.well-known/acme-challenge/ {
  location                {{ROOT}}/.well-known/acme-challenge/
  allowBrowse             1
}

context exp:^/\\.(env|git) {
  allowBrowse             0
}

rewrite  {
  enable                  1
  rules                   <<<END_rules
RewriteCond %{REQUEST_FILENAME} !-f
RewriteRule ^(.*)$ /index.html [L]
END_rules
}
