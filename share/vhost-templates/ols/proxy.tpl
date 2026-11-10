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
}

context / {
  type                    proxy
  handler                 node
  addDefaultCharset       off
}
