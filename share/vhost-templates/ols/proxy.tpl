docRoot                   {{ROOT}}
vhDomain                  {{DOMAIN}}
{{VH_ALIASES}}
index  {
  useServer               0
  indexFiles              index.html
}

tuning {
  maxReqBodySize          16777216
  maxDynRespSize          16777216
}

errorlog {{LOGDIR}}/error.log {
  useServer               0
  logLevel                WARN
  rollingSize             10M
}

accesslog {{LOGDIR}}/access.log {
  useServer               0
  logFormat               "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\""
  logHeaders              5
  rollingSize             10M
  keepDays                10
  compressArchive         1
}

context /.well-known/acme-challenge/ {
  location                {{ROOT}}/.well-known/acme-challenge/
  allowBrowse             1
  rewrite  {
    enable                0
  }
  defaultCharset          off
}

context exp:^/\.(env|git) {
  allowBrowse             0
}

extprocessor {{PROXY_NAME}} {
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
  handler                 {{PROXY_NAME}}
  addDefaultCharset       off
  extraHeaders            <<<END_extraHeaders
RequestHeader unset X-Forwarded-Proto
RequestHeader set X-Forwarded-Proto "{{FORWARDED_PROTO}}"
RequestHeader set X-Forwarded-For "%{REMOTE_ADDR}e"
RequestHeader set X-Real-IP "%{REMOTE_ADDR}e"
unset X-Powered-By
END_extraHeaders
}

module cache {
  storagePath /usr/local/lsws/cachedata/{{DOMAIN}}
}

rewrite  {
  enable                  1
  autoLoadHtaccess        1
}
