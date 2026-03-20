# `base.sh` —  общий скрипт с базовыми функциями для DevOps задач

---

## 🚀 Установка Docker в одну строку
```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Lobzikfase2/ci-cd-scripts/main/base.sh) && set_user_info && ensure_docker"
```

---

## 🧱 Базовая настройка UFW (SSH + 80/443 TCP ONLY)
```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Lobzikfase2/ci-cd-scripts/main/base.sh) && configure_ufw"
```

---

## ⚙️ Тюнинг ядра (sysctl)
```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Lobzikfase2/ci-cd-scripts/main/base.sh) && configure_sysctl"
```

---

## 📦 Подключение к другому скрипту
```bash
source <(wget -qO- https://raw.githubusercontent.com/Lobzikfase2/ci-cd-scripts/main/base.sh)
set_user_info
...
```
