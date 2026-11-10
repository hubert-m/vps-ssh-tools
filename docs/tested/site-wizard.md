# site new — checklista E2E

Ręcznie albo w CI na kontenerze ze systemd / VM. Zaznacz `- [x]` po przejściu na czystej maszynie. Mock bez VPS: `scripts/test-site-wizard-*.sh`.

Presety MVP: php-laravel, node-next, python-django, dotnet-aspnet, static-spa. Webserver: nginx i OLS.

## Debian 12

- [ ] `site new` php-laravel + nginx — manifest, `.env` 0600, FPM, vhost, strona odpowiada
- [ ] `site new` php-laravel + OLS — to samo na OLS
- [ ] `site new` node-next + nginx — nvm, proces na 127.0.0.1, proxy
- [ ] `site new` node-next + OLS
- [ ] `site new` python-django + nginx
- [ ] `site new` python-django + OLS
- [ ] `site new` dotnet-aspnet + nginx
- [ ] `site new` dotnet-aspnet + OLS
- [ ] `site new` static-spa + nginx
- [ ] `site new` static-spa + OLS
- [ ] `site new --dry-run --json` nie zmienia dysku
- [ ] `site show --json` bez haseł
- [ ] drugie `site new` na ten sam manifest nic nie dopisuje
- [ ] `--rollback` cofa niedokończony journal

## Ubuntu 24.04

- [ ] `site new` php-laravel + nginx — manifest, `.env` 0600, FPM, vhost, strona odpowiada
- [ ] `site new` php-laravel + OLS — to samo na OLS
- [ ] `site new` node-next + nginx — nvm, proces na 127.0.0.1, proxy
- [ ] `site new` node-next + OLS
- [ ] `site new` python-django + nginx
- [ ] `site new` python-django + OLS
- [ ] `site new` dotnet-aspnet + nginx
- [ ] `site new` dotnet-aspnet + OLS
- [ ] `site new` static-spa + nginx
- [ ] `site new` static-spa + OLS
- [ ] `site new --dry-run --json` nie zmienia dysku
- [ ] `site show --json` bez haseł
- [ ] drugie `site new` na ten sam manifest nic nie dopisuje
- [ ] `--rollback` cofa niedokończony journal

## AlmaLinux 9

- [ ] `site new` php-laravel + nginx — manifest, `.env` 0600, FPM (Remi), vhost, strona odpowiada
- [ ] `site new` php-laravel + OLS — to samo na OLS
- [ ] `site new` node-next + nginx — nvm, proces na 127.0.0.1, proxy
- [ ] `site new` node-next + OLS
- [ ] `site new` python-django + nginx
- [ ] `site new` python-django + OLS
- [ ] `site new` dotnet-aspnet + nginx
- [ ] `site new` dotnet-aspnet + OLS
- [ ] `site new` static-spa + nginx
- [ ] `site new` static-spa + OLS
- [ ] `site new --dry-run --json` nie zmienia dysku
- [ ] `site show --json` bez haseł
- [ ] drugie `site new` na ten sam manifest nic nie dopisuje
- [ ] `--rollback` cofa niedokończony journal
