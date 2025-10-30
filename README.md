
# 🎶 CLIFY Player (CLI-Fi)

**CLIFY Player** is a minimalist and functional command-line audio player for Linux, written in Ruby. Its purpose is to search, download, and play tracks from SoundCloud and other sources directly within your terminal (TUI).

**CLIFY Player** — это минималистичный и функциональный консольный аудиоплеер для Linux, написанный на Ruby. Он предназначен для поиска, скачивания и воспроизведения треков с SoundCloud и других источников прямо в вашем терминале (TUI).

## 🚀 Features (Особенности)

* **🎧 Terminal User Interface (TUI):** Interactive playlist, ASCII art cover display, time, and status visualization.
* **🔍 Integrated Search:** Built-in search functionality for SoundCloud using `yt-dlp`.
* **💾 State Persistence:** Automatic saving of playlist, current playback position, and volume level between sessions.
* **🔊 Local Volume Control:** Volume, rewind, and pause are controlled directly within the player (via MPlayer FIFO), without affecting the global system volume.
* **🔒 Proxy Support:** Automatic use of the `ALL_PROXY` environment variable for all network operations (`yt-dlp`, `curl`).

---

## ⚙️ Usage and Arguments (Использование и Аргументы)

**Запуск:** `ruby clify.rb [ARGS] [URL]`

| Argument (Аргумент) | Description (Описание) |
| :------------------ | :-------------------------------------------------------------------------------------- |
| (no args)           | **Interactive Mode** (Интерактивный режим). Запуск с загрузкой последнего плейлиста.      |
| `[URL]`             | Launch with a specific track or playlist URL. (Запуск с конкретным URL трека/плейлиста.) |
| `--no-state`        | Your config will **not** be read or written. (Конфигурация не будет ни читаться, ни записываться.) |

### Launch with Proxy (Запуск через Прокси)

Set the `ALL_PROXY` environment variable before execution:
Установите переменную окружения `ALL_PROXY` перед выполнением:

```bash
ALL_PROXY=socks5://127.0.0.1:2080 ./clify.rb 
````

## 📦 Installation and Dependencies (Установка и Зависимости)

CLIFY requires the following packages to function: **Ruby** (2.5+), **yt-dlp**, **MPlayer**, **curl**, and the Ruby `ncurses` gem.

### 🐧 Installation using Pacman (Arch/Manjaro)

Установка с помощью пакетного менеджера `pacman`:

```bash
# Ruby, MPlayer, curl
sudo pacman -S ruby mplayer curl

# yt-dlp
sudo pacman -S yt-dlp

# Curses library for Ruby
sudo gem install ncurses

# Optional: ASCII art renderer
sudo pacman -S jp2a
```

### 🐧 Installation using Apt (Debian/Ubuntu)

Установка с помощью пакетного менеджера `apt`:

```bash
# Ruby, MPlayer, curl
sudo apt update
sudo apt install ruby mplayer curl

# yt-dlp (Use one of these methods)
sudo apt install yt-dlp
# OR manual download:
sudo wget [https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp](https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp) -O /usr/local/bin/yt-dlp
sudo chmod a+x /usr/local/bin/yt-dlp

# Curses library for Ruby
sudo gem install ncurses

# Optional: ASCII art renderer
sudo apt install jp2a
```

-----

## 🕹️ Hotkeys (Горячие Клавиши)

| Key (Клавиша) | Action (Действие) | Description (Описание) |
| :------------ | :------------------ | :----------------------------------------- |
| **/** | Search (Поиск) | Switch to console for interactive search. |
| **Q** | Exit (Выход) | Exit program (saves state by default). |
| **P / SPACE** | Pause / Resume (Пауза/Продолжение) | Toggle playback state. |
| **F** | Forward (Вперед) | Fast forward by 10 seconds. |
| **R** | Rewind (Назад) | Rewind by 10 seconds. |
| **N** | Next Track (Следующий) | Next track in the playlist. |
| **B** | Previous Track (Предыдущий) | Previous track in the playlist. |
| **+ / -** | Adjust Volume (Громкость) | Adjust player volume (local control). |

## 💾 Config Path (Путь к Конфигурации)

The player saves its state (playlist, position, volume) in this file:
Плеер сохраняет свое состояние (плейлист, позицию, громкость) в этом файле:


~/.clify_state.json
