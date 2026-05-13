# API — Проверка эндпоинтов

Base URL: `http://localhost:5271`

---

## Переменные

```bash
BASE=http://localhost:5271
ADMIN_KEY=dev-admin-key
TOKEN=""  # заполнить после верификации
```

Для `test_scripts/test_api.py` используются env-переменные:

```bash
API_BASE=http://localhost:5271
ADMIN_KEY=dev-admin-key

# По умолчанию включен non-interactive режим через /v1/users/quick-register
USE_QUICK_REGISTER=1

# Интерактивная верификация кода из консоли по умолчанию отключена
ENABLE_INTERACTIVE_VERIFY=0
```

Важно: флоу регистрации в `test_scripts/test_api.py` взаимоисключающие.

- `USE_QUICK_REGISTER=1` (по умолчанию): запускается только quick-register флоу.
- `USE_QUICK_REGISTER=0`: запускается только обычный flow `register/verify/resend/restore`.

Примеры запуска:

```bash
# Неиинтерактивно (по умолчанию): quick-register
API_BASE=https://api.alt-to.online ADMIN_KEY=your-admin-key python test_scripts/test_api.py all

# Обычный flow register/verify/resend/restore
USE_QUICK_REGISTER=0 ENABLE_INTERACTIVE_VERIFY=1 python test_scripts/test_api.py all
```

---

## 1. Health check

```bash
curl $BASE/health
```

**Ожидается:** `200 {"status":"ok"}`

---

## 2. Регистрация пользователя

### 2.1 Успешная регистрация

```bash
curl -s -X POST $BASE/v1/users/register \
  -H "Content-Type: application/json" \
  -d '{
    "username": "testuser",
    "email": "test@example.com",
    "addr": ["testuser@nine.testrun.org"],
    "publicKey": "base64encodedpublickey==",
    "fingerprint": "AABBCCDDEEFF0011",
    "encryptedPrivateKey": "base64encodedprivkey==",
    "displayName": "Test User"
  }'
```

> - `email` — почта аккаунта (для верификации и восстановления)
> - `addr` — Delta Chat адрес для обмена сообщениями, например на `nine.testrun.org` или любом другом Delta Chat сервере

**Ожидается:** `202`

---

### 2.2 Невалидный username (спецсимволы, < 3 или > 30 символов)

```bash
curl -s -X POST $BASE/v1/users/register \
  -H "Content-Type: application/json" \
  -d '{"username":"a!","email":"test2@example.com","addr":["test2@nine.testrun.org"],"publicKey":"k","fingerprint":"f","encryptedPrivateKey":"e"}'
```

**Ожидается:** `422 {"error":"invalid_username"}`

---

### 2.3 Зарезервированный username

> Сначала добавь username в reserved (см. раздел 7.1), затем попробуй зарегистрировать.

**Ожидается:** `422 {"error":"username_reserved"}`

---

### 2.4 Username уже занят

> Повторная регистрация с тем же username.

**Ожидается:** `409 {"error":"username_taken"}`

---

### 2.5 Email уже занят

> Регистрация другого username, но с уже использованным email.

**Ожидается:** `409 {"error":"email_taken"}`

---

### 2.6 Quick-register (без кода подтверждения)

```bash
curl -s -X POST $BASE/v1/users/quick-register \
  -H "Content-Type: application/json" \
  -d '{
    "username": "testuser_quick",
    "email": "test_quick@example.com",
    "addr": ["test_quick@nine.testrun.org"],
    "publicKey": "base64encodedpublickey==",
    "fingerprint": "AABBCCDDEEFF0011",
    "encryptedPrivateKey": "base64encodedprivkey==",
    "displayName": "Test User Quick"
  }'
```

**Ожидается:** `200 {"token":"<jwt>"}`

> Этот endpoint используется в тест-скрипте по умолчанию (`USE_QUICK_REGISTER=1`) чтобы не требовать интерактивный ввод кода.

---

### 2.7 Quick-register c теми же данными (повторный вызов)

Повторный вызов `POST /v1/users/quick-register` с **тем же** payload (тот же `username` + `email` и остальные поля) должен успешно отработать повторно.

**Ожидается:**

- первый вызов: `200 {"token":"<jwt>"}`
- второй вызов с тем же payload: `200 {"token":"<jwt>"}`

---

## 3. Верификация email

Код выводится в консоль (dev-режим): `[DEV] Verification code for test@example.com: XXXXXX`

### 3.1 Успешная верификация

```bash
curl -s -X POST $BASE/v1/users/verify \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","code":"XXXXXX"}'
```

**Ожидается:** `200 {"token":"<jwt>"}`

> Сохрани токен: `TOKEN=<значение из ответа>`

---

### 3.2 Неверный или просроченный код

```bash
curl -s -X POST $BASE/v1/users/verify \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","code":"000000"}'
```

**Ожидается:** `400 {"error":"invalid_or_expired_code"}`

---

### 3.3 Пользователь не найден

```bash
curl -s -X POST $BASE/v1/users/verify \
  -H "Content-Type: application/json" \
  -d '{"email":"nobody@example.com","code":"123456"}'
```

**Ожидается:** `400 {"error":"invalid_or_expired_code"}` или `{"error":"user_not_found"}`

---

## 4. Повторная отправка кода

### 4.1 Успешная отправка

```bash
curl -s -X POST $BASE/v1/users/resend-code \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com"}'
```

**Ожидается:** `200`

---

### 4.2 Пользователь не найден

```bash
curl -s -X POST $BASE/v1/users/resend-code \
  -H "Content-Type: application/json" \
  -d '{"email":"nobody@example.com"}'
```

**Ожидается:** `400 {"error":"user_not_found"}`

---

### 4.3 Аккаунт уже активирован

> Отправить запрос для email уже верифицированного пользователя.

**Ожидается:** `400 {"error":"already_active"}`

---

### 4.4 Rate limit

> Отправить запрос несколько раз подряд быстро.

**Ожидается:** `429`

---

## 5. Восстановление доступа

### 5.1 Успешный запрос на восстановление

```bash
curl -s -X POST $BASE/v1/users/restore \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","email":"test@example.com"}'
```

**Ожидается:** `202`

> Код восстановления появится в консоли. Для входа используй `/v1/users/verify` с этим кодом — работает так же, как верификация.

---

### 5.2 Неверная пара username/email или пользователь неактивен

```bash
curl -s -X POST $BASE/v1/users/restore \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","email":"wrong@example.com"}'
```

**Ожидается:** `404 {"error":"user_not_found"}`

---

## 6. Пользователи (требуют JWT)

### 6.1 Получить свой зашифрованный приватный ключ

```bash
curl -s $BASE/v1/users/me/private-key \
  -H "Authorization: Bearer $TOKEN"
```

**Ожидается:** `200 {"encryptedPrivateKey":"..."}`

---

### 6.2 Запрос без токена

```bash
curl -s $BASE/v1/users/me/private-key
```

**Ожидается:** `401`

---

### 6.3 Поиск пользователей

```bash
curl -s "$BASE/v1/users/search?q=test" \
  -H "Authorization: Bearer $TOKEN"
```

**Ожидается:** `200 [{"addr":["..."],"name":"...","fingerprint":"...","public_key":"..."}]`

---

### 6.4 Поиск с пустым запросом

```bash
curl -s "$BASE/v1/users/search?q=" \
  -H "Authorization: Bearer $TOKEN"
```

**Ожидается:** `200 []`

---

### 6.5 Получить профиль по username

```bash
curl -s $BASE/v1/users/testuser
```

**Ожидается:** `200 {"addr":["..."],"name":"...","fingerprint":"...","public_key":"..."}`

> Эндпоинт публичный — токен не требуется.

---

### 6.6 Профиль несуществующего пользователя

```bash
curl -s $BASE/v1/users/nonexistent
```

**Ожидается:** `404`

---

## 7. Admin — Reserved usernames

Все запросы требуют заголовок `X-Admin-Key: dev-admin-key`.

### 7.1 Добавить зарезервированный username

```bash
curl -s -X POST $BASE/v1/admin/reserved-usernames/ \
  -H "X-Admin-Key: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin"}'
```

**Ожидается:** `201`

---

### 7.2 Добавить уже существующий

**Ожидается:** `409 {"error":"already_reserved"}`

---

### 7.3 Список зарезервированных

```bash
curl -s $BASE/v1/admin/reserved-usernames/ \
  -H "X-Admin-Key: $ADMIN_KEY"
```

**Ожидается:** `200 ["admin", ...]`

---

### 7.4 Удалить зарезервированный username

```bash
curl -s -X DELETE $BASE/v1/admin/reserved-usernames/admin \
  -H "X-Admin-Key: $ADMIN_KEY"
```

**Ожидается:** `204`

---

### 7.5 Удалить несуществующий

**Ожидается:** `404`

---

### 7.6 Запрос без ключа / с неверным ключом

```bash
curl -s $BASE/v1/admin/reserved-usernames/
```

**Ожидается:** `401`

---

## Сценарий "с нуля" (full flow)

```bash
# 1. Регистрация
curl -s -X POST $BASE/v1/users/register \
  -H "Content-Type: application/json" \
  -d '{"username":"alice","email":"alice@example.com","addr":["alice@nine.testrun.org"],"publicKey":"pk==","fingerprint":"FFAA","encryptedPrivateKey":"epk=="}'

# 2. Смотрим код в консоли сервера, подставляем в XXXXXX
curl -s -X POST $BASE/v1/users/verify \
  -H "Content-Type: application/json" \
  -d '{"email":"alice@example.com","code":"XXXXXX"}'
# → {"token":"..."}  сохрани как TOKEN=...

# 3. Получаем приватный ключ
curl -s $BASE/v1/users/me/private-key \
  -H "Authorization: Bearer $TOKEN"

# 4. Ищем себя
curl -s "$BASE/v1/users/search?q=alice" \
  -H "Authorization: Bearer $TOKEN"

# 5. Публичный профиль
curl -s $BASE/v1/users/alice
```
