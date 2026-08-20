# Remnawave All-in-One Manager

> **⚠️ Предупреждение:**
> Автор не несёт ответственности за использование данного скрипта и его последствия.
> Скрипт создан в учебных целях — автор изучает технологии и делится результатами.
> Используйте на свой страх и риск.

Единый скрипт управления **Remnawave**: панель, нода, сертификаты, BBR, IPv6, WARP, UFW, SSH-ключи и Fail2ban.

Работает на свежих **Ubuntu** и **Debian**.

## Установка

```bash
bash <(curl -sSL https://raw.githubusercontent.com/user-levap/rw-script/main/install_remnawave.sh)
```

## Возможности

- **Remnawave** (панель и страница подписки): установка, запуск/остановка, обновление, переустановка, логи, доступ через порт 8443, удаление
- **Remnanode**: установка (локальная/удалённая панель), запуск/остановка, обновление, переустановка, логи, удаление
- **Сертификаты** Let's Encrypt: HTTP-01 и DNS-01 (Cloudflare)
- **BBR** (как в 3x-ui), **IPv6**, **WARP Native**
- **Дополнительно**: UFW, SSH-ключи, Fail2ban
- Автообновление самого скрипта

## Лицензия

MIT. Основывается на:
- [eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy) (MIT)
- [Rrezzak09VPN/remnanode-VLESS-Reality-Hysteria2](https://github.com/Rrezzak09VPN/remnanode-VLESS-Reality-Hysteria2) (реализовано заново)