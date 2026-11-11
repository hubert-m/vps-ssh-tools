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

context /.well-known/acme-challenge/ {
  location                {{ROOT}}/.well-known/acme-challenge/
  allowBrowse             1
}

context exp:^/\\.(env|git) {
  allowBrowse             0
}

extprocessor node {
  type                    proxy
  address                 {{UPSTREAM}}
  maxConns                500
  pcKeepAliveTimeout      3600
  initTimeout             60
  retryTimeout            0
  respBuffer              0
}

context / {
  type                    proxy
  handler                 node
  addDefaultCharset       off
  extraHeaders            <<<END_extraHeaders
RequestHeader unset X-Forwarded-Proto
RequestHeader set X-Forwarded-Proto "https"
RequestHeader set X-Forwarded-For "%{REMOTE_ADDR}e"
RequestHeader set X-Real-IP "%{REMOTE_ADDR}e"
unset X-Powered-By
END_extraHeaders
}
