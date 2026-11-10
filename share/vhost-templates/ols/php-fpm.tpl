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
  indexFiles              index.php, index.html
}

scripthandler  {
  add                     lsapi:{{USER}} php
}

context /.well-known/acme-challenge/ {
  location                {{ROOT}}/.well-known/acme-challenge/
  allowBrowse             1
}

context exp:^/\\.(env|git) {
  allowBrowse             0
}

extprocessor {{USER}} {
  type                    lsapi
  address                 {{SOCK}}
  maxConns                10
  env                     PHP_LSAPI_CHILDREN=10
  autoStart               1
  path                    {{ROOT}}/../lsphp/bin/lsphp
}
